defmodule Troupe.Plane.Erasure.Retry do
  @moduledoc """
  Every five minutes, the keys erasures have not yet destroyed (Decision 811).

  A key manager that refused the plane, or could not be reached, leaves a session
  `erasure_pending`. Erasing it again tries again, and so does a private session's owner
  connecting, but nothing else would for a team session nobody touches again; this does
  (`Troupe.Plane.Erasure.retry/0`), so an erasure finishes within five minutes of the key
  manager answering. Five because a key manager is down or refusing for minutes to hours,
  not seconds, and one pass is a key-manager request per session still pending, which is
  a handful.

  The same pass destroys, once, the key of every team session erased before the plane
  destroyed them itself, which is why the first runs as soon as the plane starts: that is
  the upgrade. One it cannot destroy is tried again at the next pass with the rest.

  One process across the cluster, registered through `Troupe.Plane.Singleton` and asked
  for by `Keeper` on every replica, as the scheduler is. A pass that ran twice would do
  no harm: a key already gone counts as destroyed.
  """

  use GenServer

  alias Troupe.Plane.{Erasure, Singleton}

  require Logger

  @interval_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The cluster's erasure pass, started if nobody has."
  @spec ensure() :: {:ok, pid()} | {:error, term()}
  def ensure, do: Singleton.whereis(__MODULE__, :erasure)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe erasure retry")

    interval =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Application.get_env(:troupe_plane, :erasure_retry_ms, @interval_ms)
      end)

    send(self(), :pass)
    {:ok, %{interval_ms: interval, failed: 0}}
  end

  @impl GenServer
  def handle_info(:pass, state) do
    failed =
      try do
        say(Erasure.retry(), state.failed)
      rescue
        # A pass that raises, a database gone mid-query, must not take the process with
        # it; the next is five minutes away and finds the same tombstones.
        exception ->
          Logger.error("troupe plane: erasure pass failed: #{Exception.message(exception)}")
          state.failed
      end

    Process.send_after(self(), :pass, state.interval_ms)
    {:noreply, %{state | failed: failed}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Said when there is news: a key destroyed, or a different number left. A key no pass
  # can destroy, a team's whose team and manifest are both gone, would otherwise be said
  # every five minutes for good.
  defp say(%{destroyed: 0, failed: failed}, failed), do: failed

  defp say(%{destroyed: destroyed, failed: 0}, _before) do
    if destroyed > 0,
      do: Logger.info("troupe plane: erasure pass destroyed #{destroyed} session key(s)")

    0
  end

  defp say(%{destroyed: destroyed, failed: failed}, _before) do
    Logger.warning(
      "troupe plane: erasure pass destroyed #{destroyed} session key(s); #{failed} could " <>
        "not be destroyed and are tried again in five minutes"
    )

    failed
  end

  defmodule Keeper do
    @moduledoc """
    Asks for the cluster's erasure pass on a timer, from every replica.

    The singleton idiom starts an actor when it is first asked for, and nothing asks for
    this one, so this asks, as the scheduler's keeper does; after the replica holding it
    dies, the next ask from a survivor starts it there.
    """

    use GenServer

    alias Troupe.Plane.Erasure.Retry

    @ask_ms 30_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(opts) do
      Process.set_label("troupe erasure retry keeper")
      send(self(), :ask)
      {:ok, %{interval_ms: Keyword.get(opts, :interval_ms, @ask_ms)}}
    end

    @impl GenServer
    def handle_info(:ask, state) do
      Retry.ensure()
      Process.send_after(self(), :ask, state.interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end
end
