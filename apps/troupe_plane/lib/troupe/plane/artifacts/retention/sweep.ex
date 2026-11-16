defmodule Troupe.Plane.Artifacts.Retention.Sweep do
  @moduledoc """
  Every hour, what the artifact retention periods say has run out
  (`Troupe.Plane.Artifacts.Retention.sweep/1`). An hour because the periods are days: a
  version an hour past its day is not a version kept, and a pass with both periods off is
  two settings read and nothing else.

  An artifact the object store would not let go is left as it was and tried again by the
  next pass. It is said once, at `warning`, when it first fails, and again only if it
  fails after having gone through, so a store that refuses one artifact for a week is one
  line, not 168.

  One process across the cluster, registered through `Troupe.Plane.Singleton` and asked for
  by `Keeper` on every replica, as the erasure pass is. A pass that ran twice would do no
  harm: a removal reads the row again under a lock, and what went is not found again.
  """

  use GenServer

  alias Troupe.Plane.Artifacts.Retention
  alias Troupe.Plane.Singleton

  require Logger

  @interval_ms :timer.hours(1)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "The cluster's retention pass, started if nobody has."
  @spec ensure() :: {:ok, pid()} | {:error, term()}
  def ensure, do: Singleton.whereis(__MODULE__, :artifact_retention)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe artifact retention")

    interval =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        Application.get_env(:troupe_plane, :artifact_retention_ms, @interval_ms)
      end)

    send(self(), :pass)
    {:ok, %{interval_ms: interval, failed: MapSet.new()}}
  end

  @impl GenServer
  def handle_info(:pass, state) do
    failed =
      try do
        say(Retention.sweep(), state.failed)
      rescue
        # A pass that raises, a database gone mid-query, must not take the process with it;
        # the next is an hour away and finds the same rows.
        exception ->
          Logger.error("troupe plane: artifact retention pass failed: #{Exception.message(exception)}")
          state.failed
      end

    Process.send_after(self(), :pass, state.interval_ms)
    {:noreply, %{state | failed: failed}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # What went, at info, when anything did; what the store refused, at warning, only for an
  # artifact that was not refused last pass too.
  defp say(%{artifacts: artifacts, versions: versions, failed: failed}, before) do
    if artifacts + versions > 0 do
      Logger.info(
        "troupe plane: artifact retention removed #{artifacts} artifact(s) and #{versions} old version(s)"
      )
    end

    failed = MapSet.new(failed)
    new = MapSet.difference(failed, before)

    if MapSet.size(new) > 0 do
      Logger.warning(
        "troupe plane: artifact retention could not remove #{Enum.join(Enum.sort(new), ", ")}: " <>
          "the object store refused; tried again every hour, and said again only if it changes"
      )
    end

    failed
  end

  defmodule Keeper do
    @moduledoc """
    Asks for the cluster's artifact retention pass on a timer, from every replica, as the
    erasure pass's keeper does: nothing else asks for it, and after the replica holding it
    dies, the next ask from a survivor starts it there.
    """

    use GenServer

    alias Troupe.Plane.Artifacts.Retention.Sweep

    @ask_ms 30_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(opts) do
      Process.set_label("troupe artifact retention keeper")
      send(self(), :ask)
      {:ok, %{interval_ms: Keyword.get(opts, :interval_ms, @ask_ms)}}
    end

    @impl GenServer
    def handle_info(:ask, state) do
      Sweep.ensure()
      Process.send_after(self(), :ask, state.interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end
end
