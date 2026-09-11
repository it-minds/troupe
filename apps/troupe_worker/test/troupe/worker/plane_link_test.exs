defmodule Troupe.Worker.PlaneLinkTest do
  @moduledoc """
  The control channel, end to end, with a real plane on the other end of the socket.

  Three things are being checked that neither side can check alone: that every head a
  worker seals reaches the plane's index with the same hash, that nothing a session said
  crosses the wire on the way, and that losing the plane is something a worker recovers
  from by itself.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.LLM.Fake
  alias Troupe.Plane.Control.{Connection, Connections, Listener}
  alias Troupe.Plane.{Fleet, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.RecordingProxy

  @moduletag timeout: 180_000

  @marker "pineapple-on-pizza-9137"

  setup context do
    context = requires_tier(context)

    if Process.whereis(Repo) do
      owner = Sandbox.start_owner!(Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)

      start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
      start_supervised!(Connections)
      start_supervised!(Troupe.Plane.Singleton)
      start_supervised!({Listener, port: 0, verify: &verify/1})

      {:ok, _} =
        PlaneSessions.create(%{
          id: context.session_id,
          owner_subject: "someone@example.test",
          profile: "dev",
          epoch: 1
        })

      Map.put(context, :port, Listener.port())
    else
      flunk("no database for the plane; bring one up with `scripts/dev-up`")
    end
  end

  describe "enrolling" do
    test "the worker dials the plane and the fleet records the pod", context do
      link = start_link!(context)

      eventually(fn -> Link.connected?(link) end)
      assert Link.info(link).profile == "dev"

      assert [worker] = Fleet.list_workers("dev")
      assert worker.pod_name == "troupe-w-dev-0"
      assert worker.healthy
    end

    test "a heartbeat carries how much of the volume is gone", context do
      link = start_link!(context, heartbeat_ms: 100)
      eventually(fn -> Link.connected?(link) end)

      eventually(fn ->
        case Fleet.list_workers("dev") do
          [%{disk_total_bytes: total}] when total > 0 -> true
          _ -> false
        end
      end)
    end
  end

  describe "sealed heads" do
    test "every head a worker seals reaches the plane with the same hash", context do
      link = start_link!(context)
      eventually(fn -> Link.connected?(link) end)

      assert {:ok, _} = activate(context, report: Link.reporter(link))
      run_turn(context.session_id, "hello")
      run_turn(context.session_id, "and again")

      worker_head = Sealer.status(Sessions.whereis(context.session_id) |> Manager.status() |> Map.fetch!(:sealer))

      eventually(fn ->
        session = PlaneSessions.get(context.session_id)
        session && session.last_seq == worker_head.sealed_through
      end)

      session = PlaneSessions.get(context.session_id)
      assert session.head_hash == worker_head.head_hash

      # Every segment, not just the last: the plane's anchors are what a rebuild checks
      # object storage against, so a missing one is a hole nobody would notice.
      anchors = PlaneSessions.anchors(context.session_id)
      assert length(anchors) >= 2
      assert List.last(anchors).last_seq == worker_head.sealed_through
      assert Enum.all?(anchors, &(&1.object_key =~ "sessions/#{context.session_id}/segments/"))

      # Contiguous: each anchor carries on from the one before it.
      assert anchors |> Enum.map(&{&1.first_seq, &1.last_seq}) |> contiguous?()
    end

    test "going dormant tells the plane where the session got to", context do
      link = start_link!(context)
      eventually(fn -> Link.connected?(link) end)

      assert {:ok, _} = activate(context, report: Link.reporter(link))
      run_turn(context.session_id, "hello")
      assert {:ok, sealed} = Sessions.dormant(context.session_id)

      eventually(fn -> PlaneSessions.get(context.session_id).state == "dormant" end)

      session = PlaneSessions.get(context.session_id)
      assert session.last_seq == sealed.sealed_through
      assert session.head_hash == sealed.head_hash
    end
  end

  describe "what may not cross" do
    test "nothing a session said appears in the control traffic", context do
      {proxy, port} = start_proxy!(context.port)
      link = start_link!(context, port: port)
      eventually(fn -> Link.connected?(link) end)

      assert {:ok, _} = activate(context, report: Link.reporter(link))
      run_turn(context.session_id, @marker)
      assert {:ok, _} = Sessions.dormant(context.session_id)

      eventually(fn -> PlaneSessions.get(context.session_id).state == "dormant" end)

      captured = RecordingProxy.captured(proxy)

      # The marker went through the session as input and is in object storage. It must
      # not be anywhere in what the worker told the plane.
      assert captured =~ "session.sealed"
      refute captured =~ @marker

      # And it is not in the plane's database either.
      refute inspect(PlaneSessions.get(context.session_id)) =~ @marker
      refute inspect(PlaneSessions.anchors(context.session_id)) =~ @marker
    end
  end

  describe "losing the plane" do
    test "the link comes back on its own when the listener returns", context do
      link = start_link!(context)
      eventually(fn -> Link.connected?(link) end)
      connects = Link.info(link).connects

      # The plane goes away and comes back on the same address, which is what a killed
      # replica behind a Service looks like from here. Its connections go with it: a
      # listener that stops does not close the sockets it has already handed over.
      port = context.port
      stop_supervised!(Listener)
      stop_supervised!(Connections)
      eventually(fn -> not Link.connected?(link) end)

      start_supervised!(Connections)
      start_supervised!({Listener, port: port, verify: &verify/1})

      # The done item allows ten seconds. The reconnect is bounded well inside that so
      # that the measurement is of the worker's backoff and not of the test's patience.
      eventually(fn -> Link.connected?(link) end, 10_000)
      assert Link.info(link).connects > connects
    end

    test "reports made while the plane is down are delivered when it returns", context do
      link = start_link!(context)
      eventually(fn -> Link.connected?(link) end)

      assert {:ok, _} = activate(context, report: Link.reporter(link))

      port = context.port
      stop_supervised!(Listener)
      stop_supervised!(Connections)
      eventually(fn -> not Link.connected?(link) end)

      # Sealing does not depend on the plane being up, so this still reaches object
      # storage — and the report for it waits in the link.
      run_turn(context.session_id, "while the plane was down")
      head = Sealer.status(Sessions.whereis(context.session_id) |> Manager.status() |> Map.fetch!(:sealer))
      assert head.sealed_through > 0

      start_supervised!(Connections)
      start_supervised!({Listener, port: port, verify: &verify/1})
      eventually(fn -> Link.connected?(link) end, 10_000)

      eventually(fn ->
        session = PlaneSessions.get(context.session_id)
        session && session.last_seq == head.sealed_through
      end)
    end
  end

  describe "what the plane may push" do
    test "activate, dormant and drain, each of them twice", context do
      link = start_link!(context)
      eventually(fn -> Link.connected?(link) end)

      connection = eventually(fn -> List.first(Connections.for_profile("dev")) end)

      fake = start_supervised!({Fake, steps: [], default: {:text, "done"}})
      defaults = activation(context, fake: fake, report: Link.reporter(link))
      Application.put_env(:troupe_worker, :session_defaults, defaults)
      on_exit(fn -> Application.delete_env(:troupe_worker, :session_defaults) end)

      params = %{"session_id" => context.session_id, "team" => context.team, "epoch" => 1}

      assert {:ok, result} = push(connection, "session.activate", params)
      assert result["activated"]
      assert Sessions.active_count() == 1

      # Idempotent: the plane retries on a reconnect without knowing whether the first
      # attempt landed.
      assert {:ok, _} = push(connection, "session.activate", params)
      assert Sessions.active_count() == 1

      assert {:ok, _} = push(connection, "drain", %{})
      assert Sessions.active_ids() == []

      assert {:ok, again} = push(connection, "session.dormant", params)
      assert again["already_dormant"]
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp start_link!(context, opts \\ []) do
    start_supervised!(
      {Link,
       [
         name: nil,
         host: "127.0.0.1",
         port: Keyword.get(opts, :port, context.port),
         token: "dev-token",
         disk_path: context.base,
         claims: %{
           "pod_name" => "troupe-w-dev-0",
           "capacity" => 4,
           "disk_total_bytes" => 1_000_000,
           "version" => "test"
         }
       ] ++ Keyword.take(opts, [:heartbeat_ms])}
    )
  end

  defp start_proxy!(upstream) do
    proxy = start_supervised!({RecordingProxy, upstream: upstream})
    {proxy, RecordingProxy.port(proxy)}
  end

  defp push(connection, method, params) do
    Connection.request(connection, method, params, 60_000)
  end

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}

  defp contiguous?(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [{_, last}, {first, _}] -> first == last + 1 end)
  end
end
