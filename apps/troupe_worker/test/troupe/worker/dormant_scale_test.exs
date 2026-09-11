defmodule Troupe.Worker.DormantScaleTest do
  @moduledoc """
  Ten thousand sleeping sessions on one pod.

  The done item is a memory bound, and the reason it holds is a design decision rather
  than an optimisation: a dormant session has no process, no timer and no cached bytes in
  memory. Everything it is lives in object storage, and what the pod keeps of it is an
  encrypted file on the volume.

  So the measurement here is deliberately of the two things that would break that: the
  number of processes, and the memory the processes hold. A regression that started a
  process per dormant session would show up in the first; one that read a cache into
  memory to index it would show up in the second.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.{Fleet, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.Cache

  @moduletag timeout: 600_000

  @dormant 10_000
  # Generous, and still an order of magnitude below what a process each would cost: the
  # BEAM's smallest process is about 2.5 KiB, so ten thousand of them would be 25 MiB
  # before any of them did anything.
  @process_memory_bound 8 * 1024 * 1024

  test "ten thousand dormant sessions cost no processes and stay within the bound", context do
    context = requires_tier(context)

    # One real session first, so every module the pod uses is loaded and the baseline is
    # a working pod rather than an empty VM.
    assert {:ok, _} = activate(context)
    run_turn(context.session_id, "hello")
    assert {:ok, _} = Sessions.dormant(context.session_id)

    baseline = settle()

    ids = Enum.map(1..@dormant, &"dormant-#{&1}")
    blob = :crypto.strong_rand_bytes(256)

    {elapsed_us, :ok} =
      :timer.tc(fn ->
        Enum.each(ids, &Cache.put_workspace(&1, context.state_dir, 1, blob))
      end)

    after_caches = settle()

    assert length(Cache.entries(context.state_dir)) >= @dormant

    # The two numbers the done item is about.
    processes = after_caches.process_count - baseline.process_count
    memory = after_caches.process_memory - baseline.process_memory

    assert Sessions.active_count() == 0
    assert Sessions.active_ids() == []

    assert processes <= 2,
           "#{@dormant} dormant sessions added #{processes} processes; a dormant session must cost none"

    assert memory < @process_memory_bound,
           "#{@dormant} dormant sessions added #{div(memory, 1024)}KiB of process memory, " <>
             "over the #{div(@process_memory_bound, 1024)}KiB bound"

    IO.puts(
      :stderr,
      "\n#{@dormant} dormant caches in #{div(elapsed_us, 1000)}ms: " <>
        "+#{processes} processes, +#{div(memory, 1024)}KiB process memory\n"
    )

    # And one of them still reads back, so this is ten thousand real caches rather than
    # ten thousand empty directories.
    assert {:ok, 1, ^blob} = Cache.get_workspace("dormant-5000", context.state_dir)
  end

  test "the plane can assign ten thousand of them to one pod and still answer", context do
    _context = requires_tier(context)

    unless Process.whereis(Repo) do
      flunk("no database for the plane; bring one up with `scripts/dev-up`")
    end

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, worker} =
      Fleet.enrol(%{
        profile: "dev",
        namespace: "troupe-w-dev",
        pod_name: "troupe-w-dev-0",
        ordinal: 0,
        capacity: 4,
        disk_total_bytes: 1_000_000_000
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..@dormant, fn index ->
        %{
          id: "scale-#{index}",
          owner_subject: "ada@example.test",
          profile: "dev",
          visibility: "private",
          state: "dormant",
          epoch: 1,
          worker_id: worker.id,
          last_seq: index,
          last_active_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Chunked: PostgreSQL's wire protocol takes 65,535 parameters in one statement, and
    # eleven columns times ten thousand rows is not one statement.
    inserted =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, total ->
        {count, _} = Repo.insert_all(PlaneSessions.Session, chunk)
        total + count
      end)

    assert inserted == @dormant

    # A dormant session is a row and nothing more, so the pod's own view of itself is
    # unchanged by ten thousand of them.
    assert Sessions.active_count() == 0
    assert PlaneSessions.get("scale-5000").state == "dormant"

    # And the pod still has room: dormant sessions do not consume capacity.
    assert [placeable] = Fleet.placeable("dev")
    assert placeable.id == worker.id
  end

  # Settle first, so what is measured is what is held rather than what is waiting to be
  # collected.
  defp settle do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    :erlang.garbage_collect()

    %{
      process_count: :erlang.system_info(:process_count),
      process_memory: :erlang.memory(:processes)
    }
  end
end
