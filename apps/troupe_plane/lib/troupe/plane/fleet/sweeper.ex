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
  """

  use GenServer

  alias Troupe.Plane.{Drain, Fleet}

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

    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
