defmodule Troupe.Plane.ClusterTest do
  @moduledoc """
  Two plane replicas, and the two things they must not decide separately.

  The single-replica tests prove the actor makes the right decision. This proves the
  part that only shows up with more than one node: that there is exactly *one* actor,
  wherever the caller is, so fifty creates split across two replicas fill a profile
  once and not twice.

  A real second node, started with `:peer` and connected by Erlang distribution, with
  its own database connection pool — because a test that faked the second replica would
  not exercise `:global` at all, and `:global` is the whole mechanism.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.{
    Budget,
    Fleet,
    Identity,
    Ledger,
    Placement,
    Replica,
    Repo,
    Sessions,
    Singleton,
    TeamBudget
  }

  @moduletag timeout: 180_000

  setup_all do
    # No sandbox here: the peer node needs its own connections to the same database, and
    # a transaction on this node is invisible to it. The test cleans up what it made.
    Replica.share_database()
    on_exit(&Replica.unshare_database/0)

    case start_peer() do
      {:ok, peer, node} ->
        # The peer is linked to this process, which ExUnit takes down before running
        # `on_exit`, so by then it is usually already gone. Stopping it anyway is the
        # belt to that braces, and its absence is not a failure.
        on_exit(fn -> stop_peer(peer) end)
        {:ok, peer: peer, peer_node: node}

      {:error, reason} ->
        IO.puts(:stderr, """

        SKIPPED: could not start a second node (#{inspect(reason)}).
        These prove that placement and budgets are decided once across replicas.
        """)

        :ok
    end
  end

  setup context do
    if context[:peer_node] do
      suffix = System.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()
      start_supervised!(Singleton)
      on_exit(fn -> cleanup(suffix) end)
      %{suffix: suffix}
    else
      :ok
    end
  end

  test "fifty creates split across two replicas fill a profile exactly once", context do
    %{peer_node: peer_node, suffix: suffix} = requires_peer(context)
    profile = "dev-#{suffix}"
    make_profile(profile, 5, 4)

    # The session rows are written first, and only the placement is raced.
    #
    # Not a simplification: placement *is* the serialisation point of a create, and it
    # is what the done item is about. Doing the insert inside the racing task would also
    # have each task hold a sandbox connection while it blocked on the actor, which
    # deadlocks the pool rather than testing anything.
    for n <- 1..50 do
      {:ok, _} = Sessions.create(%{id: "s-#{suffix}-#{n}", owner_subject: "idp|alice", profile: profile})
    end

    # Half the work asks this replica, half asks the other. Whichever one the caller is
    # on, the decision is made by the same process.
    results =
      1..50
      |> Task.async_stream(
        fn n ->
          id = "s-#{suffix}-#{n}"

          if rem(n, 2) == 0 do
            Placement.reserve(profile, id)
          else
            :erpc.call(peer_node, Placement, :reserve, [profile, id], 30_000)
          end
        end,
        max_concurrency: 50,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    granted = Enum.count(results, &match?({:ok, _}, &1))
    refused = Enum.count(results, &match?({:error, :at_capacity}, &1))

    assert granted == 20, "#{granted} sessions were placed on a profile with room for 20"
    assert refused == 30

    # And no pod is over its own cap, which the total alone would not prove.
    counts = Sessions.active_counts_by_worker(profile)
    assert map_size(counts) <= 5

    for {_worker_id, used} <- counts do
      assert used <= 4, "a pod is holding #{used} sessions with a cap of 4"
    end

    assert counts |> Map.values() |> Enum.sum() == 20

    # There is one actor, and both replicas reached it.
    assert :global.whereis_name({Placement, profile}) != :undefined
  end

  test "concurrent reservations across replicas never exceed a team's budget", context do
    %{peer_node: peer_node, suffix: suffix} = requires_peer(context)
    team = make_team(suffix, 1_000)

    results =
      1..50
      |> Task.async_stream(
        fn n ->
          id = "s-#{suffix}-#{n}"

          # Through the ladder on both replicas, because that is the whole path a
          # `session.create` takes and it is the one that writes the row.
          if rem(n, 2) == 0 do
            Budget.reserve(team.id, id, "ada@example.test", 100)
          else
            :erpc.call(
              peer_node,
              Budget,
              :reserve,
              [team.id, id, "ada@example.test", 100],
              30_000
            )
          end
        end,
        max_concurrency: 50,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    granted = Enum.count(results, &match?({:ok, _}, &1))

    assert granted == 10
    assert Enum.count(results, &match?({:error, {:over_budget, :team, _}}, &1)) == 40

    promised = Ledger.open_reservations(team.id) |> Map.values() |> Enum.sum()
    assert promised == 1_000, "the team promised #{promised} against a budget of 1000"
  end

  test "losing the replica holding an actor loses nothing it had granted", context do
    %{peer_node: peer_node, suffix: suffix} = requires_peer(context)
    profile = "fail-#{suffix}"
    make_profile(profile, 1, 2)

    # Start the actor on the *other* node by asking it first.
    {:ok, _} = Sessions.create(%{id: "s-#{suffix}-1", owner_subject: "idp|alice", profile: profile})
    assert {:ok, _} = :erpc.call(peer_node, Placement, :reserve, [profile, "s-#{suffix}-1"], 30_000)

    holder = :global.whereis_name({Placement, profile})
    assert node(holder) == peer_node

    # The replica goes away, as a rolling upgrade or a node failure would take it.
    Process.exit(holder, :kill)

    eventually(fn -> :global.whereis_name({Placement, profile}) != holder end,
      "the dead actor was never forgotten")

    # The next caller starts it here, and it reads back what the other replica granted:
    # the reservation was written to the database before it was returned.
    {:ok, _} = Sessions.create(%{id: "s-#{suffix}-2", owner_subject: "idp|alice", profile: profile})
    assert {:ok, _} = Placement.reserve(profile, "s-#{suffix}-2")

    {:ok, _} = Sessions.create(%{id: "s-#{suffix}-3", owner_subject: "idp|alice", profile: profile})
    assert {:error, :at_capacity} = Placement.reserve(profile, "s-#{suffix}-3")
  end

  # Every test here is about two nodes, so without one there is nothing to assert.
  # `setup_all` has already said why.
  defp requires_peer(%{peer_node: _} = context), do: context
  defp requires_peer(_context), do: flunk("no second node; see the message from setup_all")

  # -- the second node --------------------------------------------------------

  defp start_peer, do: Replica.start()
  defp stop_peer(peer), do: Replica.stop(peer)

  # -- fixtures ---------------------------------------------------------------

  defp make_profile(name, pods, per_pod) do
    {:ok, _} = Fleet.put_profile(%{name: name, replicas: pods, sessions_per_pod: per_pod})

    for ordinal <- 0..(pods - 1)//1 do
      {:ok, _} =
        Fleet.enrol(%{
          profile: name,
          ordinal: ordinal,
          pod_name: "#{name}-#{ordinal}",
          namespace: "troupe-w-#{name}",
          capacity: per_pod,
          disk_total_bytes: 100,
          disk_used_bytes: 0
        })
    end
  end

  defp make_team(suffix, budget_micros) do
    {:ok, group} = Identity.upsert_group(%{external_id: "g-#{suffix}", display_name: "g-#{suffix}"})
    {:ok, team} = Identity.enable_team(group, %{name: "team-#{suffix}", budget_micros: budget_micros})
    team
  end

  defp cleanup(suffix) do
    import Ecto.Query

    Repo.delete_all(from s in Sessions.Session, where: like(s.id, ^"s-#{suffix}-%"))
    Repo.delete_all(from w in Fleet.Worker, where: like(w.profile, ^"%-#{suffix}"))
    Repo.delete_all(from p in Fleet.Profile, where: like(p.name, ^"%-#{suffix}"))
    Repo.delete_all(from r in Ledger.Reservation, where: like(r.session_id, ^"s-#{suffix}-%"))
    Repo.delete_all(from t in Identity.Team, where: like(t.name, ^"team-#{suffix}"))
    Repo.delete_all(from g in Identity.Group, where: like(g.external_id, ^"g-#{suffix}"))
  end

  defp eventually(predicate, message, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(predicate, message, deadline)
  end

  defp do_eventually(predicate, message, deadline) do
    cond do
      predicate.() -> :ok
      System.monotonic_time(:millisecond) < deadline -> Process.sleep(100) && do_eventually(predicate, message, deadline)
      true -> flunk(message)
    end
  end
end
