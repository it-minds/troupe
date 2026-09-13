defmodule Troupe.Plane.Ledger.Cache do
  @moduledoc """
  Sums over the ledger, remembered for a moment.

  `usage_records` is append-only and only grows, and the questions a panel asks of it —
  what has this team spent, what did it spend on what — are aggregates over a window
  that does not change once it is past. Answering them from Postgres on every page load
  is a sequential scan that gets slower every day the product is used.

  Everything here is derived and everything here may be thrown away. A miss costs a
  query; a stale entry cannot happen, because the only writer of the underlying table is
  `Troupe.Plane.TeamBudget`, which is one actor per team, and it invalidates this on the
  way past. That is the whole reason the invalidation is safe without a lock: the write
  is already serialised somewhere else.

  The table is public and read by request processes; this process owns it and sweeps out
  what has aged, so a team that was looked at once is not remembered forever.
  """

  use GenServer

  @table __MODULE__
  @ttl_seconds 60
  @sweep_every :timer.minutes(5)

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The remembered answer for a question, or compute and remember it.

  A cache that is not running answers by computing, every time. That is what a test and
  a `mix` task get, and it is the only behaviour difference between having this and not.
  """
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, compute) when is_function(compute, 0) do
    case lookup(key) do
      {:ok, value} -> value
      :error -> remember(key, compute.())
    end
  end

  @doc "Forget everything remembered about a team. Called by the only writer."
  @spec invalidate(term()) :: :ok
  def invalidate(team_id) do
    :ets.select_delete(@table, [{{{:"$1", :_}, :_, :_}, [{:==, :"$1", team_id}], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forget everything. For a test that changes what the ledger would answer."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe ledger cache")
    _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{_key, value, expires_at}] when expires_at > 0 ->
        if expires_at > now(), do: {:ok, value}, else: :error

      _miss ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp remember(key, value) do
    :ets.insert(@table, {key, value, now() + @ttl_seconds})
    value
  rescue
    ArgumentError -> value
  end

  defp now, do: System.system_time(:second)
end
