defmodule Troupe.Gateway.InvitesTest do
  @moduledoc """
  Inviting a person into a private session from the machine that seals it, and reading one
  you were invited into (#765), the daemon's half.

  The store is the real MinIO and the keys are in the real OpenBao, as in the sealing tests:
  each generation of the session's key goes into the invitee's own slot there, and what is
  sealed after an invitation is taken back is under a key the person removed was not given,
  which only opening the segments shows. The plane is the stand-in, keeping invitations as
  the plane keeps them; the plane's own half, and what its credential and each person's may
  read, is the plane's `invites_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{FakePlane, Invites, Plane, Private}
  alias Troupe.KMS
  alias Troupe.KMS.OpenBao
  alias Troupe.ObjectStore
  alias Troupe.Protocol.Event
  alias Troupe.Sessions.{Sealer, Storage}

  @moduletag :object_store

  @ada "ada@example.test"
  @bea "bea@example.test"
  @cy "cy@example.test"

  setup_all do
    store = ObjectStore.from_env()

    cond do
      not match?({:ok, _}, ObjectStore.list(store, "reachability-probe/")) ->
        IO.puts(:stderr, "\nSKIPPED: no object storage; bring it up with `scripts/dev-up`.\n")
        {:ok, skip: "no object storage"}

      not bao_reachable?() ->
        IO.puts(
          :stderr,
          "\nSKIPPED: no OpenBao (#{bao_address()}); bring it up with `scripts/dev-up`.\n"
        )

        {:ok, skip: "no OpenBao"}

      true ->
        :ok
    end
  end

  setup context do
    if context[:skip], do: flunk("skipped: #{context[:skip]}")

    plane = FakePlane.serve()
    name = :"plane-#{System.unique_integer([:positive])}"
    start_supervised!({Plane, name: name})

    :ok =
      Plane.link(
        %{"subject" => @ada, "plane_url" => plane.url, "plane_token" => "plane-token"},
        name
      )

    start_supervised!(Private.Sealers)
    on_exit(fn -> Process.exit(plane.server, :normal) end)

    {:ok, log} = Agent.start_link(fn -> [] end)
    %{plane: plane, name: name, log: log}
  end

  test "an invitation puts every key of the session in the invitee's own slot, tells the plane where, and the log says so",
       ctx do
    {id, _sealer, context} = private(ctx)

    assert {:ok, invited} = Invites.invite(session(id), @bea, "observe", opts(ctx))
    assert invited["invite"]["subject"] == @bea

    assert %{"keys" => [%{"key_version" => 1, "slot" => slot}], "role" => "observe"} =
             FakePlane.invitations(ctx.plane.state, id)[@bea]

    assert String.starts_with?(slot, "troupe/people/#{@bea}/invited/#{id}/k1-")
    assert {:ok, key} = OpenBao.fetch_at(slot, token: root(), address: bao_address())
    assert key == context.data_key

    assert [%Event{type: "session_invited", data: data}] = Agent.get(ctx.log, & &1)
    assert data == %{"subject" => @bea, "display_name" => @bea, "role" => "observe", "by" => @ada}

    # Nothing of the kind for a session that is not private, or one somebody else owns.
    assert {:error, :not_private} =
             Invites.invite(%{session(id) | kind: "local"}, @bea, "observe", opts(ctx))

    assert {:error, :not_owner} =
             Invites.invite(%{session(id) | owner: @cy}, @bea, "observe", opts(ctx))
  end

  test "taking an invitation back seals what follows under a new key, given to everybody still invited and not to them",
       ctx do
    {id, sealer, context} = private(ctx)
    {:ok, _} = Invites.invite(session(id), @bea, "observe", opts(ctx))
    {:ok, _} = Invites.invite(session(id), @cy, "observe", opts(ctx))
    assert {:error, :followed_only} = Invites.invite(session(id), @cy, "control", opts(ctx))
    send_event(id, sealer, 1)
    assert {:ok, _} = Sealer.seal_now(sealer)

    assert {:ok, answer} = Invites.uninvite(session(id), @bea, opts(ctx))
    assert answer["rekey_due"] == false
    assert answer["key_version"] == 2

    # The plane's row is at the second key, which is Ada's second generation, put in Cy's slot.
    assert %{"key_version" => 2, "rekey_due" => false} = FakePlane.row(ctx.plane.state, id)
    refute Map.has_key?(FakePlane.invitations(ctx.plane.state, id), @bea)

    assert %{"keys" => [_k1, %{"key_version" => 2, "slot" => cy_slot}]} =
             FakePlane.invitations(ctx.plane.state, id)[@cy]

    path = KMS.generation(id, 2)
    assert {:ok, k2} = OpenBao.fetch({:person, @ada}, path, token: root(), address: bao_address())
    refute k2 == context.data_key
    assert {:ok, ^k2} = OpenBao.fetch_at(cy_slot, token: root(), address: bao_address())

    # What comes after is sealed under it, and what came before stays as it was.
    send_event(id, sealer, 2)
    assert {:ok, %{sealed_through: 2}} = Sealer.seal_now(sealer)
    assert {:ok, [first, second]} = Storage.list_segments(context.store, id)

    assert {:ok, [%{"seq" => 1}]} =
             Storage.read_segment(context.store, id, context.data_key, first.key)

    assert {:error, :invalid} =
             Storage.read_segment(context.store, id, context.data_key, second.key)

    assert {:ok, [%{"seq" => 2}]} = Storage.read_segment(context.store, id, k2, second.key)

    assert {:ok, [%{"seq" => 2}]} =
             Storage.read_segment(context.store, id, [context.data_key, k2], second.key)

    # The log says she was removed, and the next invitation into it is given both keys.
    assert ["session_invited", "session_invited", "session_uninvited"] =
             ctx.log |> Agent.get(& &1) |> Enum.map(& &1.type)

    {:ok, _} = Invites.invite(session(id), @bea, "observe", opts(ctx))

    assert [1, 2] =
             for(
               k <- FakePlane.invitations(ctx.plane.state, id)[@bea]["keys"],
               do: k["key_version"]
             )
  end

  test "an invitee's daemon reads the whole sealed log with the keys in its own slot", ctx do
    {id, sealer, _context} = private(ctx)
    {:ok, _} = Invites.invite(session(id), @cy, "observe", opts(ctx))
    {:ok, _} = Invites.invite(session(id), @bea, "observe", opts(ctx))
    send_event(id, sealer, 1)
    assert {:ok, _} = Sealer.seal_now(sealer)
    {:ok, _} = Invites.uninvite(session(id), @bea, opts(ctx))
    send_event(id, sealer, 2)
    send_event(id, sealer, 3)
    assert {:ok, _} = Sealer.seal_now(sealer)

    # Cy, on her own machine: the plane says where her keys are, and she reads them from her
    # slot with her own sign-in, here the root token in its place.
    FakePlane.keys_for(ctx.plane.state, @cy)

    reading = [
      plane: ctx.name,
      spend: fn _grant -> {:ok, [token: root(), address: bao_address()]} end
    ]

    assert {:ok, read} = Invites.read(id, reading)
    assert Enum.map(read["events"], & &1["seq"]) == [1, 2, 3]
    assert {:ok, later} = Invites.read(id, Keyword.put(reading, :after_seq, 1))
    assert Enum.map(later["events"], & &1["seq"]) == [2, 3]

    # Bea, removed, is told the session holds nothing of hers.
    FakePlane.keys_for(ctx.plane.state, @bea)
    assert {:error, {:rpc, %{"message" => "not_found"}}} = Invites.read(id, reading)
  end

  test "a new key goes only to people this session's own log invited, whatever the plane lists",
       ctx do
    {id, _sealer, _context} = private(ctx)
    {:ok, _} = Invites.invite(session(id), @bea, "observe", opts(ctx))

    # An invitation this machine never made: a plane that says so is given no key for it.
    {:ok, _} =
      Plane.call(
        "session.invite",
        %{
          "session_id" => id,
          "subject" => "mallory@example.test",
          "role" => "observe",
          "keys" => [
            %{
              "key_version" => 1,
              "slot" => "troupe/people/mallory@example.test/invited/#{id}/k1-x"
            }
          ]
        },
        ctx.name
      )

    # The plane refuses a new key nobody was given for its listed invitee, and the session
    # stays due for one: no key is the safe way round.
    assert {:ok, %{"rekey_due" => true}} = Invites.uninvite(session(id), @bea, opts(ctx))
    row = FakePlane.row(ctx.plane.state, id)
    assert row["rekey_due"] == true
    assert (row["key_version"] || 1) == 1

    refute Enum.any?(
             FakePlane.calls(ctx.plane.state),
             &match?({"session.invite_slot", %{"subject" => "mallory@example.test"}}, &1)
           )
  end

  test "a link carrying a session on re-keys it first where an invitation was taken back elsewhere",
       ctx do
    {id, sealer, context} = private(ctx)
    send_event(id, sealer, 1)
    assert {:ok, _} = Sealer.seal_now(sealer)
    :ok = Private.stop(id)

    # Taken back at the plane, from another client, while this machine was away.
    FakePlane.put(
      ctx.plane.state,
      id,
      Map.merge(FakePlane.row(ctx.plane.state, id), %{"rekey_due" => true})
    )

    log = [event(1), event(2)]

    assert {:ok, [^id]} =
             Private.resume(
               Keyword.merge(opts(ctx),
                 device: "test-laptop",
                 subscribe: fn _id -> :ok end,
                 sessions: [%{id: id, workspace: nil}],
                 backfill: fn _id, after_seq -> Enum.filter(log, &(&1.seq > after_seq)) end
               )
             )

    assert %{"key_version" => 2, "rekey_due" => false} = FakePlane.row(ctx.plane.state, id)
    sealer = Registry.whereis_name({Private.Registry, id})
    assert {:ok, %{sealed_through: 2}} = Sealer.seal_now(sealer)

    {:ok, k2} =
      OpenBao.fetch({:person, @ada}, KMS.generation(id, 2), token: root(), address: bao_address())

    assert {:ok, [_first, second]} = Storage.list_segments(context.store, id)

    assert {:error, :invalid} =
             Storage.read_segment(context.store, id, context.data_key, second.key)

    assert {:ok, [%{"seq" => 2}]} = Storage.read_segment(context.store, id, k2, second.key)
  end

  # -- helpers ----------------------------------------------------------------

  # Ada's private session, registered and sealing here, its first key made.
  defp private(ctx) do
    id = "p-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"

    {:ok, sealer, context} =
      Private.start(id,
        plane: ctx.name,
        device: "test-laptop",
        subscribe: fn _id -> :ok end,
        key_manager: &fake_key_manager/2
      )

    on_exit(fn -> if Process.alive?(sealer), do: Process.exit(sealer, :normal) end)
    {id, sealer, context}
  end

  defp session(id), do: %{id: id, kind: "private", owner: @ada}

  # What the daemon passes: its plane, its sign-in at the key manager (the root token in
  # place of the exchange this plane cannot sign), and the session's log, kept here.
  defp opts(ctx) do
    [
      plane: ctx.name,
      key_manager: &fake_key_manager/2,
      record: fn _id, type, data ->
        event = %Event{type: Atom.to_string(type), agent: ["root"], data: data}
        Agent.update(ctx.log, &(&1 ++ [event]))
      end,
      replay: fn _id, _from -> Agent.get(ctx.log, & &1) end
    ]
  end

  defp fake_key_manager(_plane, _session_id), do: {:ok, [token: root()]}

  defp root do
    System.get_env("TROUPE_BAO_TOKEN") || Application.get_env(:troupe_worker, :kms, [])[:token]
  end

  defp bao_address,
    do: Application.get_env(:troupe_worker, :kms, [])[:address] || "http://localhost:28200"

  defp bao_reachable? do
    match?(
      {:ok, %{status: 200}},
      Req.request(method: :get, url: bao_address() <> "/v1/sys/health", retry: false)
    )
  rescue
    _ -> false
  end

  defp send_event(id, sealer, seq), do: send(sealer, {:troupe_event, id, event(seq)})

  defp event(seq), do: %Event{seq: seq, type: "message", agent: ["root"], data: %{"n" => seq}}
end
