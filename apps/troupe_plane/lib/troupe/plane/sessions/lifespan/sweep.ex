defmodule Troupe.Plane.Sessions.Lifespan.Sweep do
  @moduledoc """
  Every ten minutes, the throwaway sessions whose time has come
  (`Troupe.Plane.Sessions.Lifespan.sweep/1`). Ten minutes because the window is hours: a
  session ten minutes past its day is not one kept, and a pass with nothing throwaway asleep
  is one indexed query.

  One process across the cluster, registered through `Troupe.Plane.Singleton` and asked for
  by `Keeper` on every replica, as the artifacts' retention pass is. A pass that ran twice
  would do no harm: each session is taken by a conditional write, and one taken is not
  found again.
  """

  use GenServer

  alias Troupe.Plane.Sessions.Lifespan
  alias Troupe.Plane.Singleton

  require Logger

  @interval_ms :timer.minutes(10)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "The cluster's lifespan pass, started if nobody has."
  @spec ensure() :: {:ok, pid()} | {:error, term()}
  def ensure, do: Singleton.whereis(__MODULE__, :session_lifespan)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe session lifespan")
    send(self(), :pass)
    {:ok, %{interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)}}
  end

  @impl GenServer
  def handle_info(:pass, state) do
    try do
      say(Lifespan.sweep())
    rescue
      # A pass that raises, a database gone mid-query, must not take the process with it;
      # the next is ten minutes away and finds the same rows.
      exception ->
        Logger.error("troupe plane: session lifespan pass failed: #{Exception.message(exception)}")
    end

    Process.send_after(self(), :pass, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp say(%{erased: 0, failed: []}), do: :ok

  defp say(%{erased: erased, failed: failed}) do
    if erased > 0,
      do: Logger.info("troupe plane: erased #{erased} throwaway session(s) whose time had come")

    if failed != [],
      do:
        Logger.warning(
          "troupe plane: #{length(failed)} throwaway session(s) could not be erased and are tried again next pass"
        )
  end

  defmodule Keeper do
    @moduledoc """
    Asks for the cluster's lifespan pass on a timer, from every replica, as the artifacts'
    retention keeper does: nothing else asks for it, and after the replica holding it dies,
    the next ask from a survivor starts it there.
    """

    use GenServer

    alias Troupe.Plane.Sessions.Lifespan.Sweep

    @ask_ms 30_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(opts) do
      Process.set_label("troupe session lifespan keeper")
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
