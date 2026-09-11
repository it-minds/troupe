defmodule Troupe.Gateway.Idle do
  @moduledoc """
  Shuts the daemon down after a quiet period.

  A daemon that clients spawn on demand has to go away on its own, or every `troupe
  ctl` invocation leaves a process behind forever. It stops only when there is nothing
  to lose: no clients attached and no session running. Sessions that are merely
  dormant do not hold it open — they are durable in their logs and come back on the
  next activating command.
  """

  use GenServer

  alias Troupe.Gateway.Connections

  require Logger

  @default_idle_ms :timer.minutes(10)
  @check_interval_ms :timer.seconds(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the daemon currently has a reason to stay up."
  @spec busy?() :: boolean()
  def busy?, do: Connections.count() > 0 or Troupe.any_active_sessions?()

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe idle watch")

    state = %{
      idle_ms: Keyword.get(opts, :idle_shutdown_ms, @default_idle_ms),
      interval_ms: Keyword.get(opts, :idle_check_ms, @check_interval_ms),
      stop: Keyword.get(opts, :on_idle, &default_stop/0),
      quiet_since: now()
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    state =
      cond do
        busy?() ->
          %{state | quiet_since: now()}

        now() - state.quiet_since >= state.idle_ms ->
          Logger.info("troupe: idle for #{state.idle_ms}ms with nothing running, shutting down")
          state.stop.()
          state

        true ->
          state
      end

    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state), do: Process.send_after(self(), :check, state.interval_ms)
  defp now, do: System.monotonic_time(:millisecond)

  # `System.stop/0` unwinds the supervision tree, so sessions seal and close cleanly
  # rather than being cut off mid-write.
  defp default_stop, do: System.stop(0)
end
