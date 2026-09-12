defmodule Troupe.Gateway.Commands do
  @moduledoc """
  The idempotency ledger: a `command_id` is honoured once and remembered.

  Every command that changes something carries a client-generated `command_id`, and
  replaying it returns the original acknowledgement without producing a second
  effect. That is what makes a command safe to retry across a disconnect — the client
  reconnects, resends what it is unsure about, and cannot double-send an input or
  answer an approval twice.

  Entries expire, because remembering every command forever is a leak and no client
  retries a command from last week.
  """

  use GenServer

  @default_ttl_ms :timer.minutes(30)
  @sweep_interval_ms :timer.minutes(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Run `fun` unless this key has been seen, in which case return what it returned the
  first time.

  The key is whatever makes a command unique on this server — `Dispatch` uses the
  principal's subject together with the client's `command_id`, because a `command_id` is
  only promised unique per client and two clients counting from `c-1` must not share an
  acknowledgement. The ledger is claimed before `fun` runs, so two connections replaying
  the same key concurrently cannot both execute it.
  """
  @spec once(term(), (-> term())) :: term()
  def once(command_id, fun) when is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:claim, command_id}, 15_000) do
      {:done, result} ->
        result

      :claimed ->
        result = fun.()
        GenServer.cast(__MODULE__, {:record, command_id, result})
        result
    end
  catch
    # With no ledger running there is nothing to deduplicate against; running the
    # command is better than failing it, and local commands are the ones at risk.
    :exit, _ -> fun.()
  end

  @doc "How many acknowledgements are remembered. Tests and diagnostics."
  @spec size() :: non_neg_integer()
  def size, do: GenServer.call(__MODULE__, :size)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe command ledger")
    schedule_sweep()

    {:ok, %{entries: %{}, ttl_ms: Keyword.get(opts, :command_ttl_ms, @default_ttl_ms)}}
  end

  @impl GenServer
  def handle_call({:claim, command_id}, _from, state) do
    case Map.get(state.entries, command_id) do
      {:done, result, _at} ->
        {:reply, {:done, result}, state}

      {:claimed, _at} ->
        # A concurrent replay of an id still in flight. Treating it as claimed means
        # the second caller gets the acknowledgement shape without a second effect.
        {:reply, {:done, {:ok, %{"accepted" => true, "duplicate" => true}}}, state}

      nil ->
        entries = Map.put(state.entries, command_id, {:claimed, now()})
        {:reply, :claimed, %{state | entries: entries}}
    end
  end

  def handle_call(:size, _from, state), do: {:reply, map_size(state.entries), state}

  @impl GenServer
  def handle_cast({:record, command_id, result}, state) do
    {:noreply, %{state | entries: Map.put(state.entries, command_id, {:done, result, now()})}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now() - state.ttl_ms

    entries =
      state.entries
      |> Enum.reject(fn {_id, entry} -> elem(entry, tuple_size(entry) - 1) < cutoff end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
  defp now, do: System.monotonic_time(:millisecond)
end
