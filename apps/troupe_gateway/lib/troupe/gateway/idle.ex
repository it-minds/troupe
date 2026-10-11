defmodule Troupe.Gateway.Idle do
  @moduledoc """
  Shuts the daemon down after a quiet period.

  A daemon that clients spawn on demand has to go away on its own, or every invocation
  that starts one leaves a process behind forever. It stops only when there is nothing
  to lose: no clients attached and no session running. Sessions that are merely
  dormant do not hold it open — they are durable in their logs and come back on the
  next activating command. Nor, for long, does one that is idle or waiting on a person:
  `Troupe.Sessions.Index` puts it to sleep, minutes after the last client has gone, since
  an unanswered approval or question is as durable as the rest of its log. This is the
  last rung of the ladder from a running turn to the daemon's exit, every clock of which
  is set in one place: [troupe-daemon](../../../../troupe_daemon/README.md#how-long-it-stays-up).

  It is also what stops the daemon when `troupe update` asks it to, between turns, so its
  release can be replaced (`daemon.stop`, Decision 865): the same stop, on request.
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

  @doc """
  Stop the daemon now, for `daemon.stop` (Decision 865), when it was started to be
  stopped so: `stop_on_request: true`, which `troupe-daemon run` passes and a TUI that
  runs the daemon inside itself does not. `:not_stoppable` otherwise. The stop comes a
  moment after the answer, so the answer reaches the client that asked.
  """
  @spec stop_on_request() :: :ok | :not_stoppable
  def stop_on_request, do: GenServer.call(__MODULE__, :stop_on_request)

  @doc "Whether `stop_on_request/0` would stop this daemon."
  @spec stoppable?() :: boolean()
  def stoppable?, do: GenServer.call(__MODULE__, :stoppable?)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe idle watch")

    state = %{
      idle_ms: Keyword.get(opts, :idle_shutdown_ms, @default_idle_ms),
      interval_ms: Keyword.get(opts, :idle_check_ms, @check_interval_ms),
      stop: Keyword.get(opts, :on_idle, &default_stop/0),
      on_request: Keyword.get(opts, :stop_on_request, false),
      quiet_since: now()
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:stoppable?, _from, state), do: {:reply, state.on_request, state}

  def handle_call(:stop_on_request, _from, %{on_request: false} = state),
    do: {:reply, :not_stoppable, state}

  def handle_call(:stop_on_request, _from, state) do
    Logger.info("troupe: asked to stop between turns (daemon.stop), shutting down")
    Process.send_after(self(), :stop_now, 250)
    {:reply, :ok, state}
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

  def handle_info(:stop_now, state) do
    state.stop.()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state), do: Process.send_after(self(), :check, state.interval_ms)
  defp now, do: System.monotonic_time(:millisecond)

  # `System.stop/0` unwinds the supervision tree, so sessions seal and close cleanly
  # rather than being cut off mid-write.
  defp default_stop, do: System.stop(0)
end
