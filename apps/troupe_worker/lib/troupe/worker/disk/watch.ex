defmodule Troupe.Worker.Disk.Watch do
  @moduledoc """
  Keeping a pod's volume from filling up.

  Two watermarks and one rule about what may be given up. Above the **low** watermark
  (default 70%) the pod evicts dormant caches, least recently used first, until it is
  back under. Above the **high** one (default 80%) the plane stops placing sessions
  there — which this process does not enforce, because it is the plane's decision; what
  it does is make sure the number the plane sees is true, by reporting it and by acting
  on it.

  **Active workspaces are never evicted.** A cache is a copy of something already in
  object storage, so losing it costs a download; an active workspace is the only copy of
  work in progress, and a pod that deleted one to make room would lose the session it
  was trying to keep running. If eviction cannot get below the low watermark, the pod
  says so and stays above it rather than reaching for something it must not touch.
  """

  use GenServer

  alias Troupe.Paths
  alias Troupe.Worker.{Cache, Disk, Sessions}

  require Logger

  @interval_ms 30_000
  @low 0.70

  defstruct [
    :state_dir,
    :timer,
    :low,
    :high,
    :usage,
    interval_ms: @interval_ms,
    evictions: 0,
    bytes_freed: 0
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Run a sweep now and say what it did. Used at dormancy and by tests."
  @spec sweep(GenServer.server()) :: map()
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep, 60_000)

  @doc "What this pod's volume looks like, and what has been given up for it."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe disk watch")

    state_dir = Keyword.get(opts, :state_dir) || Paths.state_dir()

    state = %__MODULE__{
      state_dir: state_dir,
      low: Keyword.get(opts, :low, @low),
      high: Keyword.get(opts, :high, Disk.watermarks().high),
      # How full the volume is. `df` in a pod; injectable because a test cannot fill a
      # developer's disk to prove what happens when a PVC fills, and the thing worth
      # testing is the policy rather than the measurement.
      usage: Keyword.get(opts, :usage, fn -> Disk.usage(state_dir) end),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)
    }

    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    {report, state} = run(state)
    {:reply, report, state}
  end

  def handle_call(:status, _from, state) do
    usage = state.usage.()

    {:reply,
     %{
       fraction: usage.fraction,
       used_bytes: usage.used_bytes,
       total_bytes: usage.total_bytes,
       cache_bytes: Cache.total_bytes(state.state_dir),
       low: state.low,
       high: state.high,
       pressure: Disk.pressure(usage, high: state.high),
       evictions: state.evictions,
       bytes_freed: state.bytes_freed
     }, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    {_report, state} = run(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- the sweep --------------------------------------------------------------

  defp run(state) do
    usage = state.usage.()

    if usage.fraction >= state.low do
      evict_until_under(state, usage)
    else
      {report(state, usage, [], :ok), state}
    end
  end

  defp evict_until_under(state, usage) do
    active = MapSet.new(Sessions.active_ids())

    # Least recently used first, and never an active session: a cache is a copy of
    # something already in object storage, and an active workspace is not.
    candidates =
      state.state_dir
      |> Cache.entries()
      |> Enum.reject(&MapSet.member?(active, &1.session_id))

    {evicted, freed} = evict(candidates, state, usage, [], 0)

    after_usage = state.usage.()
    outcome = if after_usage.fraction < state.low, do: :ok, else: :still_above

    if outcome == :still_above do
      Logger.warning(
        "troupe worker: still at #{round(after_usage.fraction * 100)}% after evicting " <>
          "#{length(evicted)} cache(s); active workspaces are never evicted"
      )
    end

    state = %{state | evictions: state.evictions + length(evicted), bytes_freed: state.bytes_freed + freed}
    {report(state, after_usage, evicted, outcome), state}
  end

  defp evict([], _state, _usage, evicted, freed), do: {Enum.reverse(evicted), freed}

  defp evict([candidate | rest], state, usage, evicted, freed) do
    # Re-measured after every eviction rather than estimated: a PVC shared with anything
    # else moves for reasons this process did not cause.
    if usage.fraction < state.low do
      {Enum.reverse(evicted), freed}
    else
      bytes = Cache.evict(candidate.session_id, state.state_dir)
      evict(rest, state, state.usage.(), [candidate.session_id | evicted], freed + bytes)
    end
  end

  defp report(state, usage, evicted, outcome) do
    %{
      fraction: usage.fraction,
      used_bytes: usage.used_bytes,
      total_bytes: usage.total_bytes,
      evicted: evicted,
      bytes_freed: state.bytes_freed,
      outcome: outcome,
      pressure: Disk.pressure(usage, high: state.high)
    }
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sweep, state.interval_ms)}
  end
end
