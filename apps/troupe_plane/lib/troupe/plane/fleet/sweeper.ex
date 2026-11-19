defmodule Troupe.Plane.Fleet.Sweeper do
  @moduledoc """
  Notices pods that have stopped talking.

  A pod that fails cleanly closes its control connection and the plane knows at once.
  The interesting failure is the other one: a pod that cannot tell anyone anything —
  killed, partitioned, or wedged — and for that there is nothing to wait for but
  silence.

  So presence is a lease. A heartbeat renews it, and a pod past the timeout is marked
  unhealthy, which stops placement immediately — and its sessions are marked dormant,
  which is what actually makes them activatable elsewhere.

  That second half was a sentence here and nothing in the code. A session left `active` on
  a pod that is gone is unreachable for good: opening it takes the already-running branch,
  tells nobody to restore, and answers `not_found` to every retry. It looked fixed because
  a pod that comes *back* reconciles what it holds on re-enrolment, and until the plane
  scaled profiles itself a pod nearly always came back.

  The sweep runs on every replica, and stranding is idempotent: a session that is already
  dormant is not on a worker, so the next sweep has nothing to find.

  Every rescue above starts from a pod, so a session `active` on no pod at all is reached
  by none of them, and the scaler counts it for good. A pass of its own marks such a
  session dormant once it has been so for a minute (`Sessions.adrift/1`).

  A last pass forgets a pod its substrate no longer runs, once it has been quiet past a
  drain's deadline and holds nothing (`Fleet.forget_gone/0`): a scale-down's pods were
  otherwise listed for ever as draining. Idempotent too, since a row deleted is not found
  again.
  """

  use GenServer

  alias Troupe.Plane.{Drain, Fleet, Sessions}

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run a sweep now, and say which pods were marked unhealthy."
  @spec sweep() :: [Fleet.Worker.t()]
  def sweep, do: Fleet.sweep()

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe fleet sweeper")
    # A third of the lease, so a pod is noticed well inside it rather than up to a
    # whole lease late.
    interval = Keyword.get(opts, :interval_ms, div(Fleet.lease_timeout_ms(), 3))
    schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    :ok = run()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "One whole pass, as the timer runs it: pods marked, what they held rescued, rows forgotten."
  @spec run() :: :ok
  def run do
    # Two passes because they are two questions. Marking a pod unhealthy stops placement;
    # rescuing what it was holding is about sessions, and a pod marked unhealthy an hour
    # ago still holds whatever it held.
    for worker <- Fleet.sweep() do
      Logger.warning(
        "troupe plane: #{worker.namespace}/#{worker.pod_name} stopped heartbeating; " <>
          "it will take no more sessions"
      )
    end

    for worker <- Fleet.lost(), stranded = Drain.strand(worker), stranded != [] do
      Logger.warning(
        "troupe plane: #{worker.namespace}/#{worker.pod_name} is gone with " <>
          "#{length(stranded)} session(s) on it; they are dormant and can be activated elsewhere"
      )
    end

    # A session counted as running that names no pod is reached by nothing above, since
    # every rescue starts from a pod, and the scaler keeps a pod of its profile up for it.
    # One whose pod is healthy and does not hold it is put to sleep when the pod answers
    # what it holds, which the pod's connection asks on its own schedule.
    for session <- Sessions.adrift(adrift_after_ms()), {:ok, _} <- [Drain.rest(session)] do
      Logger.warning(
        "troupe plane: #{session.id} of #{session.profile} was counted as running on no pod " <>
          "since #{DateTime.to_iso8601(session.updated_at)}; it is dormant and wakes as usual"
      )
    end

    # After the rescue, so a pod whose sessions were just marked dormant holds none, and
    # its row goes once it has been quiet past a drain's deadline and is no longer run.
    for worker <- Fleet.forget_gone() do
      Logger.info(
        "troupe plane: #{worker.namespace}/#{worker.pod_name} was removed and has not been " <>
          "heard from since #{DateTime.to_iso8601(worker.last_heartbeat_at)}; its row is forgotten"
      )
    end

    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)

  # How long a session may be `active` with no pod before the sweep calls it adrift: well
  # past the moment between a create's or a wake's row and its placement, which is one
  # placement call, and past the thirty seconds a pod is given to take a session.
  @adrift_after_ms 60_000

  @doc "How long a session counted as running may name no pod before the sweep marks it dormant."
  @spec adrift_after_ms() :: non_neg_integer()
  def adrift_after_ms, do: Application.get_env(:troupe_plane, :adrift_after_ms, @adrift_after_ms)
end
