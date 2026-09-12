defmodule Troupe.Plane.Triggers.Scheduler do
  @moduledoc """
  The in-plane cron: one process across the cluster, ticking every thirty seconds.

  A deployment without Hatchet is still complete for schedules. Every tick reads the
  enabled triggers whose source is a schedule, works out the latest cron minute at or
  before now, and fires each one whose minute has passed since it last fired — with the
  idempotency key `cron:<trigger id>:<minute>`, so a tick that runs twice, on two
  replicas that both believe they are the singleton, produces one session.

  A plane that was down fires each trigger *once* when it comes back, for the latest
  missed minute, rather than once per minute missed: a nightly job that was skipped
  should run, and a job that fires every five minutes should not run twelve times to
  make up an hour. A trigger that has never fired is not backfilled at all; its first
  firing is its next minute.

  Registered with `:global` through `Troupe.Plane.Singleton`, the idiom `Placement` and
  `TeamBudget` use. Nothing asks for the scheduler the way a create asks for placement,
  so `Keeper` — one per replica, in the supervision tree — asks for it on a timer, and
  the replica that finds it gone after a failover starts it again.

  Handles no webhooks and no retries beyond the next tick, which is the honest reason to
  run Hatchet beside a larger plane.
  """

  use GenServer

  alias Troupe.Plane.Singleton
  alias Troupe.Plane.Triggers
  alias Troupe.Plane.Triggers.Cron

  require Logger

  @tick_ms 30_000

  # How recent a due minute must be for a trigger that has never fired: within two
  # ticks, so enabling `0 3 * * *` at ten in the morning does not fire it at once.
  @first_fire_window_seconds 120

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The cluster's scheduler, started if nobody has."
  @spec ensure() :: {:ok, pid()} | {:error, term()}
  def ensure, do: Singleton.whereis(__MODULE__, :cron)

  @doc """
  One tick, at a given time: fire what is due and say what fired.

  Public and pure of process state, so a test can hand it a clock; the running
  scheduler calls it with the wall clock.
  """
  @spec tick(DateTime.t()) :: [
          {Triggers.Trigger.t(), DateTime.t(), {:ok, map()} | {:error, term()}}
        ]
  def tick(now \\ DateTime.utc_now()) do
    for trigger <- Triggers.scheduled(),
        {:ok, cron} <- [Cron.parse(trigger.source["cron"])],
        due = Cron.previous(cron, now),
        due?(trigger, due, now),
        # Marked before firing, so a tick that is interrupted between the two does not
        # fire the same minute again when it resumes; the run row is the record of
        # whether the firing itself worked.
        Triggers.mark_fired(trigger, due) do
      key = "cron:#{trigger.id}:#{DateTime.to_iso8601(due)}"
      event = %{"kind" => "schedule", "at" => DateTime.to_iso8601(due)}

      result =
        case Triggers.fire(trigger, key, event, "scheduler") do
          {:ok, fired} -> {:ok, Triggers.fired_json(fired)}
          {:error, error} -> {:error, error}
        end

      report(trigger, due, result)
      {trigger, due, result}
    end
  end

  defp due?(_trigger, nil, _now), do: false

  defp due?(%{last_fired_at: nil}, due, now) do
    DateTime.diff(now, due, :second) < @first_fire_window_seconds
  end

  defp due?(%{last_fired_at: last}, due, _now), do: DateTime.compare(due, last) == :gt

  defp report(trigger, due, {:ok, %{"state" => state}}) do
    Logger.info(
      "troupe plane: scheduler fired #{trigger.name} for #{DateTime.to_iso8601(due)}: #{state}"
    )
  end

  defp report(trigger, due, {:error, error}) do
    Logger.warning(
      "troupe plane: scheduler could not fire #{trigger.name} for #{DateTime.to_iso8601(due)}: " <>
        inspect(error)
    )
  end

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe trigger scheduler")
    interval = Keyword.get(opts, :interval_ms, @tick_ms)
    Process.send_after(self(), :tick, interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    try do
      tick()
    rescue
      # A tick that raises — a database that went away mid-query — must not take the
      # scheduler with it; the next tick is thirty seconds away and will see the same
      # triggers.
      exception ->
        Logger.error("troupe plane: scheduler tick failed: #{Exception.message(exception)}")
    end

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defmodule Keeper do
    @moduledoc """
    Asks for the cluster's scheduler on a timer, from every replica.

    The singleton idiom starts an actor when it is first asked for. Placement is asked
    for by every create; the scheduler is asked for by nobody, so this asks. After the
    replica holding it dies, the next ask from any survivor starts it there.
    """

    use GenServer

    alias Troupe.Plane.Triggers.Scheduler

    @ask_ms 30_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(opts) do
      Process.set_label("troupe trigger scheduler keeper")
      interval = Keyword.get(opts, :interval_ms, @ask_ms)
      send(self(), :ask)
      {:ok, %{interval_ms: interval}}
    end

    @impl GenServer
    def handle_info(:ask, state) do
      Scheduler.ensure()
      Process.send_after(self(), :ask, state.interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end
end
