defmodule Troupe.Plane.Fleet.Sweeper do
  @moduledoc """
  Notices pods that have stopped talking.

  A pod that fails cleanly closes its control connection and the plane knows at once.
  The interesting failure is the other one: a pod that cannot tell anyone anything —
  killed, partitioned, or wedged — and for that there is nothing to wait for but
  silence.

  So presence is a lease. A heartbeat renews it, and a pod past the timeout is marked
  unhealthy, which stops placement immediately and makes its sessions candidates for
  activation elsewhere. The sweep runs on every replica; marking a pod unhealthy twice
  is the same as marking it once.
  """

  use GenServer

  alias Troupe.Plane.Fleet

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
    case Fleet.sweep() do
      [] ->
        :ok

      lost ->
        for worker <- lost do
          Logger.warning(
            "troupe plane: #{worker.namespace}/#{worker.pod_name} stopped heartbeating; " <>
              "its sessions can be activated elsewhere"
          )
        end
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
