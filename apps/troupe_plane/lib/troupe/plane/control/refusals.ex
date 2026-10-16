defmodule Troupe.Plane.Control.Refusals do
  @moduledoc """
  When the plane last said it refused a plaintext connection from an address, and how
  many it has refused there since without saying so.

  A pod an operator made before it handed its namespace the plane's CA dials in plaintext,
  and with TLS required it is closed and dials again within a second or two, until a drain
  replaces it. A warning for each would bury the rest of the plane's log, so it is said
  once a minute per address, with the count of those it did not say. By address and not by
  address and port, since every reconnect comes from a new port.

  A public ETS table, owned by the listener as `Troupe.Plane.Control.Replay`'s is, and
  written by the connections. Two refusals from one address at once may both be said;
  nothing worse comes of the race.
  """

  @table __MODULE__

  # An address that has not been refused for this long is forgotten, so the table holds
  # the pods that are still dialling rather than every address a pod ever had.
  @forget_after_ms :timer.hours(1)

  @doc "Make the table, owned by the caller, unless it is there."
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  @doc """
  Note one refusal from `address` at `now` (monotonic milliseconds): `{:log, untold}` when
  it is to be said, with how many from there went unsaid since the last line, else
  `:quiet`. Without the table every refusal is said.
  """
  @spec note(term(), non_neg_integer(), integer()) :: {:log, non_neg_integer()} | :quiet
  def note(address, interval_ms, now \\ System.monotonic_time(:millisecond)) do
    if :ets.whereis(@table) == :undefined do
      {:log, 0}
    else
      case :ets.lookup(@table, address) do
        [{^address, said_at, _untold}] when now - said_at < interval_ms ->
          :ets.update_counter(@table, address, {3, 1})
          :quiet

        [{^address, _said_at, untold}] ->
          true = :ets.insert(@table, {address, now, 0})
          {:log, untold}

        [] ->
          forget_before(now - @forget_after_ms)
          true = :ets.insert(@table, {address, now, 0})
          {:log, 0}
      end
    end
  rescue
    # The listener, and its table, went between the check and the write.
    ArgumentError -> {:log, 0}
  end

  defp forget_before(cutoff) do
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
  end
end
