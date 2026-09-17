defmodule Troupe.Gateway.PrivateTest do
  @moduledoc """
  A person's own session, sealed from their own machine.

  The claim is that a laptop holding no object-storage credential and no key manager
  credential can nonetheless write a session into the cluster's bucket, that nobody else
  can read it, and that a second device taking it over stops this one.

  So the store here is the real MinIO and the signatures are real SigV4, made by the
  fake plane against the same bucket the daemon then writes to. What is faked is the row
  and the assertion: a row is a database and an assertion is a signature, and the daemon
  is allowed to know about neither.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, FakePlane, Plane, Private}
  alias Troupe.ObjectStore
  alias Troupe.Protocol.{Client, Endpoint, Event}
  alias Troupe.Session.Log
  alias Troupe.Sessions.{Cipher, Sealer, Storage}

  @moduletag :object_store

  setup do
    plane = FakePlane.serve()
    name = :"plane-#{System.unique_integer([:positive])}"
    start_supervised!({Plane, name: name})

    :ok =
      Plane.link(
        %{
          "subject" => "ada@example.test",
          "plane_url" => plane.url,
          "plane_token" => "plane-token"
        },
        name
      )

    on_exit(fn -> Process.exit(plane.server, :normal) end)

    %{plane: plane, name: name}
  end

  describe "linking" do
    test "the token is held in memory and never written to disk", %{name: name} do
      assert Plane.linked?(name)
      assert Plane.subject(name) == "ada@example.test"

      # A restart is a daemon with no token — deliberately, because a token on disk is a
      # token a backup copies. The label survives; the credential does not.
      stop_supervised!(Plane)
      restarted = :"plane-#{System.unique_integer([:positive])}"
      start_supervised!({Plane, name: restarted})
      refute Plane.linked?(restarted)

      assert {:error, :unlinked} = Plane.call("session.register", %{}, restarted)
    end

    test "unlinking forgets it", %{name: name} do
      :ok = Plane.unlink(name)
      refute Plane.linked?(name)
    end
  end

  describe "sealing" do
    # The daemon starts these; here there is no daemon, only the parts under test.
    setup do
      start_supervised!(Private.Sealers)
      :ok
    end

    test "writes a session nobody else can read, through signatures it was handed", ctx do
      session_id = unique("p")

      {:ok, sealer, context} = start_private(session_id, ctx)

      events = [
        %{"seq" => 1, "type" => "session_created", "data" => %{"kind" => "private"}},
        %{"seq" => 2, "type" => "message", "data" => %{"text" => "a private thought"}}
      ]

      {:ok, segment} =
        Storage.seal_segment(context.store, session_id, context.data_key, %{
          events: events,
          epoch: context.epoch,
          head_hash: "sha256:head"
        })

      # The daemon never held a bucket credential; these bytes went up a presigned URL.
      keyed = ObjectStore.from_env()
      assert {:ok, ciphertext} = ObjectStore.get(keyed, segment.key)
      refute ciphertext =~ "a private thought"
      assert {:error, _} = Cipher.open(:crypto.strong_rand_bytes(32), session_id, ciphertext)

      # And it can read its own back, which is the half that needs the key.
      assert {:ok, ^events} =
               Storage.read_segment(context.store, session_id, context.data_key, segment.key)

      # Listing is the plane's, because a listing cannot be signed per-key.
      assert {:ok, [listed]} = Storage.list_segments(context.store, session_id)
      assert listed.key == segment.key

      assert Process.alive?(sealer)
    end

    test "every seal tells the plane how far the session has got", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)

      send_event(context, sealer, 1)
      send_event(context, sealer, 2)

      assert {:ok, report} = Sealer.seal_now(sealer)
      assert report.sealed_through == 2

      # Upload first, then report: the plane hears about a segment that is already in
      # storage, never the other way round.
      row = FakePlane.row(ctx.plane.state, session_id)
      assert row["kind"] == "private"
      assert row["device"] == "test-laptop"
      assert row["last_seq"] == 2
      assert row["head_hash"] == report.head_hash

      # And the manifest names a person rather than a team, which is what a rebuild reads.
      assert {:ok, manifest} = Storage.get_manifest(context.store, session_id)
      assert manifest["kind"] == "private"
      assert manifest["team"] == nil
      assert manifest["owner_subject"] == "ada@example.test"
      assert manifest["key_path"] == "troupe/people/ada@example.test/sessions/#{session_id}"
    end

    test "a device that lost the session stops sealing", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)

      # Another device takes it. This one is not told: it is holding epoch 1 and the row
      # has moved to 2, and it finds out the next time it tries to say anything.
      taken = FakePlane.steal(ctx.plane.state, session_id)
      assert taken["epoch"] == context.epoch + 1

      send_event(context, sealer, 1)
      assert {:ok, _} = Sealer.seal_now(sealer)

      assert {"session.register", %{"epoch" => 1}} =
               ctx.plane.state |> FakePlane.calls() |> List.last()

      # The row is unchanged: the loser's report was refused, not merged.
      assert FakePlane.row(ctx.plane.state, session_id)["device"] == "the other one"
    end

    test "claiming bumps the epoch, and a second claim on the old one is refused", ctx do
      session_id = unique("p")
      {:ok, _sealer, _context} = start_private(session_id, ctx)

      assert {:ok, won} = Private.claim(session_id, 1, plane: ctx.name, device: "desktop")
      assert won["epoch"] == 2

      assert {:error, {:rpc, %{"message" => "stale_version"}}} =
               Private.claim(session_id, 1, plane: ctx.name, device: "laptop")
    end
  end

  describe "without a plane" do
    test "a session that cannot be registered is refused, and nothing is lost", ctx do
      :ok = Plane.unlink(ctx.name)

      assert {:error, :unlinked} =
               Private.start(unique("p"), plane: ctx.name, key_manager: &fake_key_manager/2)
    end
  end

  describe "through the daemon" do
    setup do
      base = Path.join(System.tmp_dir!(), "troupe-priv-#{System.unique_integer([:positive])}")
      workspace = Path.join(base, "workspace")
      state_dir = Path.join(base, "state")
      File.mkdir_p!(workspace)
      File.mkdir_p!(state_dir)

      previous = System.get_env("TROUPE_STATE_HOME")
      System.put_env("TROUPE_STATE_HOME", state_dir)

      endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
      start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

      on_exit(fn ->
        if previous,
          do: System.put_env("TROUPE_STATE_HOME", previous),
          else: System.delete_env("TROUPE_STATE_HOME")

        File.rm_rf!(base)
      end)

      %{workspace: workspace, state_dir: state_dir, endpoint: endpoint}
    end

    test "a daemon nobody has linked creates the session and says it is not syncing", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, created} =
               Client.call(client, "session.create", %{
                 "command_id" => Client.command_id(),
                 "workspace" => ctx.workspace,
                 "private" => true,
                 "config" => %{"auto_approve" => true}
               })

      on_exit(fn -> Troupe.stop_session(created["session_id"]) end)

      # The session exists and runs. `syncing` is what it is *actually* doing, not what
      # was asked for: refusing to work without a network is the coupling a private
      # session exists to avoid, so an unlinked daemon makes a local one and says so.
      assert created["syncing"] == false
      refute Private.sealing?(created["session_id"])

      # And the log says what kind it is, which is what a rebuild and a second device read.
      events = Log.read_session(created["session_id"], ctx.state_dir)
      created_event = Enum.find(events, &(&1.type == "session_created"))
      assert created_event.data["kind"] == "private"
    end

    test "a local session has no sealer, and stopping one is a no-op", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, created} =
               Client.call(client, "session.create", %{
                 "command_id" => Client.command_id(),
                 "workspace" => ctx.workspace,
                 "config" => %{"auto_approve" => true}
               })

      assert created["syncing"] == false
      assert :ok = Private.stop(created["session_id"])

      assert {:ok, %{"state" => "dormant"}} =
               Client.call(client, "session.archive", %{
                 "command_id" => Client.command_id(),
                 "session_id" => created["session_id"]
               })
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp start_private(session_id, ctx) do
    result =
      Private.start(session_id,
        plane: ctx.name,
        device: "test-laptop",
        subscribe: fn _id -> :ok end,
        key_manager: &fake_key_manager/2
      )

    case result do
      {:ok, sealer, context} ->
        on_exit(fn -> stop(sealer) end)
        {:ok, sealer, context}

      other ->
        other
    end
  end

  defp stop(sealer) do
    if Process.alive?(sealer), do: Process.exit(sealer, :normal)
  end

  # What the real exchange answers, without the signature. Minting an assertion is the
  # plane's job and is proven in the plane's own suite; what this test is about is what
  # the daemon does with the token afterwards.
  defp fake_key_manager(_plane, _session_id) do
    kms = Application.get_env(:troupe_worker, :kms, [])
    {:ok, token: System.get_env("TROUPE_BAO_TOKEN") || kms[:token]}
  end

  # The Sealer subscribes; here nothing publishes, so the events are handed to it
  # directly. `agent_done` on the root is a turn ending, which is the sealer's own cue.
  defp send_event(context, sealer, seq) do
    event = %Event{seq: seq, type: "message", agent: ["root"], data: %{"n" => seq}}
    send(sealer, {:troupe_event, context.session_id, event})
  end

  # Unique between runs as well as within one. These become object keys, and an object store
  # is not a database: nothing rolls back at the end of a test, so a second run that picked
  # the same id would list what the first one wrote. That is what failed on CI \u2014 one test
  # here asserts a session has exactly one segment, and it had one of its own plus one from
  # a run half an hour earlier.
  defp unique(prefix) do
    "#{prefix}-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end
end
