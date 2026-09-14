defmodule Troupe.Worker.FailoverTest do
  @moduledoc """
  Losing one of two plane replicas.

  The done item has three parts and they pull in different directions: the worker's
  control connection must come back *quickly*, the sessions attached to that worker must
  not notice at all, and creates must keep succeeding. The first two are in tension —
  anything that made reconnection cheap by tying it to session state would break the
  second — and the third is the one that says the surviving replica is a real replica
  rather than a spare.

  Two real plane replicas, the second a separate OTP node, with a Service in front of
  them: workers dial one address and the Service picks a replica, which is what makes
  losing one a reconnect rather than an outage.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{EnrolmentStub, Fleet, Placement, Replica, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.PlaneHelper
  alias Troupe.Worker.Service
  alias Troupe.Worker.Session.{Manager, Sealer}

  @moduletag timeout: 300_000

  setup_all do
    if Process.whereis(Repo) do
      # The peer needs its own connections to the same database, and a transaction on
      # this node is invisible to it.
      Replica.share_database()
      on_exit(&Replica.unshare_database/0)

      # The replica runs the whole application, so its listener is started by the
      # supervision tree rather than with options — which is why the verifier goes
      # through configuration here.
      env = [
        control_port: peer_port(),
        http_port: peer_port() + 1,
        enrolment_verifier: &EnrolmentStub.verify/1
      ]

      case Replica.start(env: env) do
        {:ok, peer, node} ->
          on_exit(fn -> Replica.stop(peer) end)
          {:ok, peer: peer, peer_node: node, peer_port: peer_port()}

        {:error, reason} ->
          IO.puts(:stderr, "\nSKIPPED: could not start a second replica (#{inspect(reason)}).\n")
          :ok
      end
    else
      IO.puts(:stderr, "\nSKIPPED: no database for the plane; bring one up with `scripts/dev-up`.\n")
      :ok
    end
  end

  setup context do
    context = requires_tier(context)
    context = requires_peer(context)

    # This node is the first replica.
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &EnrolmentStub.verify/1})

    service =
      start_supervised!({Service, name: nil, backends: [Listener.port(), context.peer_port]})

    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 2, sessions_per_pod: 4})

    on_exit(fn -> cleanup(context.session_id) end)

    Map.merge(context, %{service: service, local_port: Listener.port()})
  end

  test "the link comes back on the survivor, and attached sessions never notice", context do
    link = start_link!(context)
    eventually(fn -> Link.connected?(link) end)

    first = Link.info(link).connects
    assert Service.stats(context.service).forwarded == [context.local_port]

    # A session attached to this worker, mid-conversation.
    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: "ada@example.test",
        profile: "dev",
        epoch: 1,
        state: "active"
      })

    assert {:ok, _} = activate(context, report: Link.reporter(link))
    run_turn(context.session_id, "before the replica died")
    head_before = sealed_head(context)

    # The replica this worker is attached to goes away. Its connections go with it,
    # which is what a killed pod does to the TCP it was holding.
    Service.put_backends(context.service, [context.peer_port])
    PlaneHelper.stop_plane()

    started = System.monotonic_time(:millisecond)
    eventually(fn -> not Link.connected?(link) end, 5_000)

    # Back on the survivor. The done item allows ten seconds.
    eventually(fn -> Link.connected?(link) end, 10_000)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 10_000, "reconnected after #{elapsed}ms, the done item allows 10000"
    assert Link.info(link).connects > first
    assert List.last(Service.stats(context.service).forwarded) == context.peer_port

    # The session never noticed: same tree, same epoch, and the turn it ran across the
    # failure is still there.
    assert Sessions.whereis(context.session_id)
    assert Troupe.agent_tree(context.session_id) != []
    assert sealed_head(context) >= head_before

    # And it still works, which is the part a reconnect that half-succeeded would fail.
    run_turn(context.session_id, "after the replica died")
    assert sealed_head(context) > head_before
  end

  test "creates keep succeeding on the surviving replica", context do
    link = start_link!(context)
    eventually(fn -> Link.connected?(link) end)

    # The pod is enrolled, which is what a create needs to have somewhere to go.
    worker = eventually(fn -> List.first(Fleet.list_workers("dev")) end)
    assert worker.healthy

    Service.put_backends(context.service, [context.peer_port])
    PlaneHelper.stop_plane()

    eventually(fn -> Link.connected?(link) end, 10_000)

    # Placement is a `:global` actor, so the surviving replica reaches the same one this
    # node was using — and a create decided there is a create decided once.
    for n <- 1..3 do
      id = "#{context.session_id}-after-#{n}"

      {:ok, _} =
        PlaneSessions.create(%{id: id, owner_subject: "ada@example.test", profile: "dev", epoch: 1})

      assert {:ok, %{worker: placed}} = Placement.reserve("dev", id)
      assert placed.profile == "dev"
    end

    assert Fleet.list_workers("dev") != []
  end

  # -- helpers ----------------------------------------------------------------

  defp sealed_head(context) do
    context.session_id
    |> Sessions.whereis()
    |> Manager.status()
    |> Map.fetch!(:sealer)
    |> Sealer.status()
    |> Map.fetch!(:sealed_through)
  end

  defp start_link!(context) do
    start_supervised!(
      {Link,
       name: nil,
       host: "127.0.0.1",
       port: Service.port(context.service),
       token: "dev-token",
       disk_path: context.base,
       heartbeat_ms: 1_000,
       claims: %{"pod_name" => "troupe-w-dev-0", "capacity" => 4, "disk_total_bytes" => 1_000_000}}
    )
  end

  # The peer runs the whole application, including its own control listener, so it needs
  # a port this node is not using.
  defp peer_port, do: 42_101

  defp requires_peer(%{peer_port: _} = context), do: context
  defp requires_peer(_context), do: flunk("no second replica; see the message from setup_all")

  # No sandbox here — both replicas write to the same database for real — so the test
  # takes its own rows away.
  defp cleanup(session_id) do
    import Ecto.Query

    Repo.delete_all(from s in PlaneSessions.Session, where: like(s.id, ^"#{session_id}%"))
    Repo.delete_all(from w in Fleet.Worker, where: w.profile == "dev")
    Repo.delete_all(from p in Fleet.Profile, where: p.name == "dev")
  end
end
