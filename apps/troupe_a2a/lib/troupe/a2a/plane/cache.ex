defmodule Troupe.A2A.Plane.Cache do
  @moduledoc """
  Plane tokens, one per caller credential, kept until shortly before they expire.

  A plane token lasts at most fifteen minutes and an A2A caller may make many calls in
  that time, each carrying the same credential. Exchanging on every call would put a
  round trip to the plane and a verification at the identity provider in front of
  every `tasks/get`. So the exchange is remembered, keyed by a digest of the credential
  rather than the credential itself — the table never holds a secret — and consulted
  only while the token has a minute left, which is longer than any one request takes.

  The table is public and written by request processes. The process here owns it and
  sweeps out what has expired, so a credential that was used once and never again is
  not remembered forever.
  """

  use GenServer

  @table __MODULE__
  # Refreshed while this much of the token's life remains. A request that started with
  # thirty seconds on the clock and spent them waiting for a pod would present a token
  # that had just died; a minute is comfortably more than a request takes.
  @margin_seconds 60
  @sweep_every :timer.minutes(5)

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The remembered exchange for a credential, if it is still good for a while."
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(credential) do
    case :ets.lookup(@table, key(credential)) do
      [{_key, caller, expires_at}] ->
        if expires_at - @margin_seconds > now(), do: {:ok, caller}, else: :error

      [] ->
        :error
    end
  end

  @doc "Remember an exchange. One without an expiry is not remembered at all."
  @spec put(term(), map(), term()) :: :ok
  def put(credential, caller, expires_at) when is_integer(expires_at) do
    true = :ets.insert(@table, {key(credential), caller, expires_at})
    :ok
  end

  def put(_credential, _caller, _expires_at), do: :ok

  @doc "Forget everything. For a test that changes what the plane would answer."
  @spec clear() :: :ok
  def clear do
    true = :ets.delete_all_objects(@table)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now() - @margin_seconds
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  defp key(credential), do: :crypto.hash(:sha256, :erlang.term_to_binary(credential))

  defp now, do: System.system_time(:second)
end
