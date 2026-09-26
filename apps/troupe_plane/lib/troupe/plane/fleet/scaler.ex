defmodule Troupe.Plane.Fleet.Scaler do
  @moduledoc """
  The plane asks for the capacity it can already see it needs.

  `Placement` has been a per-profile capacity controller since the beginning: serialised
  by `:global`, with counts backed by Postgres, and knowing *sessions* rather than the
  CPU utilisation a metrics-driven autoscaler would have to infer them from. Its own
  documentation said what should happen when it refused:

  > That is not a failure to retry blindly: it means the profile needs more replicas, and
  > the caller should say so.

  The system knew it needed another worker and its answer was to tell a person to go and
  type a number. Worse, the refusal landed on whoever created the thirty-third session,
  for a number their administrator had guessed three weeks earlier.

  This is the other half. Once an interval, per profile:

      want = ceil((active + pending) / sessions_per_worker) + warm

  clamped to the ceiling an administrator set, written to `spec.replicas`. Same writer,
  same permission and same audit trail as `spec.teams`, which the plane has always been
  the only writer of — so this widens nothing: `kubectl auth can-i` as the plane's
  ServiceAccount answers exactly what it answered before.

  ## The expensive mistake at this scale is the minimum

  Eight profiles at one replica each is eight pods running always, for a mean load of
  about one concurrent session. A profile with nothing running should have no workers,
  and that is most of what this is for; scaling *up* is the part that reads like
  autoscaling and the part that matters least.

  Scale-down already drains, seals and strands nothing, so going to zero costs nothing
  but a cold start on the way back — roughly half a minute, which is the same wait the
  client already describes honestly when it wakes a dormant session, with the same
  indeterminate bar and no invented percentage. Somebody about to spend half an hour in
  a session will wait thirty seconds. What they will not forgive is a refusal.

  ## Deliberately boring

  Fifteen seconds, arithmetic, no HPA, no metrics pipeline, no per-session pod churn.
  **A pod is never created for a session**: the unit of scale is the profile's pool and
  sessions are placed into it. At this size anything faster would be machinery reacting
  to noise, and anything cleverer would be a second opinion about a number the plane
  already knows exactly.

  ## Up at once, down after a wait

  Growing is immediate: somebody is waiting. Shrinking is not, and the cluster suite is
  what made that obvious — with no hysteresis the fleet went `1 -> 2 -> 1 -> 2 -> 1` in
  under a minute as sessions started and went dormant, which costs a pod start and a
  drain each way and makes the pod set move under everything that reads it.

  So `idle_since` is really *smaller-since*: set the first tick a profile is found
  wanting fewer workers than it has, cleared the moment it wants as many or more, and a
  reduction only happens once it has been that way for the grace period. Going to zero is
  the same rule with nothing special about it, which is the point — a profile whose last
  session went dormant ninety seconds ago is very often one somebody is about to wake.

  The clock lives on the row rather than in this process, so a failover does not reset it
  and leave a worker up for ever.
  """

  use GenServer

  alias Troupe.Plane.{ClusterPolicy, Fleet, Harness, Sessions, Singleton}
  alias Troupe.Plane.Fleet.{Profile, Provisioner, SizeClass}

  require Logger

  @tick_ms 15_000

  # How long a profile must have wanted fewer workers before it gets fewer. Two minutes:
  # long enough that waking a session somebody has just closed does not pay a cold start,
  # short enough that a profile nobody is using is not still costing a pod at lunchtime.
  @shrink_grace_seconds 120

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The cluster's scaler, started if nobody has."
  @spec ensure() :: {:ok, pid()} | {:error, term()}
  def ensure, do: Singleton.whereis(__MODULE__, :fleet)

  @doc """
  One pass over every profile: what each should be, and what was changed.

  Exposed so a test can drive it at a clock it controls rather than waiting fifteen
  seconds, and so an operator can ask what the scaler makes of things right now.
  """
  @spec tick(DateTime.t()) :: [map()]
  def tick(now \\ DateTime.utc_now()) do
    Enum.map(Fleet.list_profiles(), &scale(&1, now))
  end

  @doc """
  What this profile should be running, and why.

  `want` is what the arithmetic asks for; `capped_by` names the ceiling where one bound
  it, so a console can say *this profile is at the limit you set* rather than leaving an
  administrator to work out why it stopped growing.
  """
  @spec plan(Profile.t(), DateTime.t()) :: map()
  def plan(%Profile{} = profile, now \\ DateTime.utc_now()) do
    demand = Sessions.demand_for(profile.name)
    per_worker = SizeClass.sessions_per_pod(profile.size_class)
    warm = profile.warm_workers || 0
    needed = ceil_div(demand.active + demand.pending, per_worker)

    {want, capped_by} = clamp(needed + warm, profile, per_worker)
    {want, capped_by} = under_policy(want, capped_by)
    have = profile.replicas || 0

    %{
      profile: profile.name,
      active: demand.active,
      pending: demand.pending,
      sessions_per_worker: per_worker,
      warm: warm,
      have: have,
      asks_for: want,
      want: settled(want, have, profile, now),
      capped_by: capped_by,
      max_sessions: profile.max_sessions
    }
  end

  @doc """
  The most sessions this profile may run at once, or `nil` for no ceiling.

  What a refusal quotes. In sessions rather than workers on purpose: it is the number an
  administrator chose and the number a person who has just been refused can understand.
  """
  @spec ceiling(Profile.t()) :: pos_integer() | nil
  def ceiling(%Profile{max_sessions: max}), do: max

  @doc """
  Whether this profile is within the ceiling somebody set for it.

  Asked *before* placement, not only when placement fails. The first version asked only
  on the refusal path — so a ceiling of one session on a class that fits four never bound
  until four were running, because until then there was always room on the worker and
  nothing consulted the number. A ceiling that only applies when the pods are full is not
  a ceiling; it is a second opinion about the same thing placement already knows.

  The session being created is counted: its row exists before this is asked, so `<=` is
  the comparison and it is the difference between a ceiling of one meaning one and
  meaning two.
  """
  @spec within_ceiling?(Profile.t()) :: boolean()
  def within_ceiling?(%Profile{} = profile) do
    case ceiling(profile) do
      nil -> true
      max -> Sessions.demand_for(profile.name) |> then(&(&1.active + &1.pending)) <= max
    end
  end

  # -- one profile ------------------------------------------------------------

  defp scale(%Profile{} = profile, now) do
    plan = plan(profile, now)
    mark_smaller(profile, plan, now)
    changed = plan.want != plan.have and write(profile, plan)

    # Before the scaling and after it: a worker that came up two ticks ago has room now,
    # and a session that has been waiting for it should not wait another fifteen seconds
    # because this tick happened to change nothing.
    Map.merge(plan, %{changed: changed, admitted: admit(profile)})
  end

  # Oldest first, one at a time, stopping at the first refusal. Placement is the only
  # thing that knows whether there is room, so this asks rather than deciding — and a
  # refusal means the room is gone, which makes carrying on down the list pointless. A
  # session parked because its team may no longer use the profile took no room, so the
  # next one is asked.
  defp admit(%Profile{} = profile) do
    profile.name
    |> Sessions.pending_for()
    |> Enum.reduce_while([], fn session, admitted ->
      case Harness.admit(session) do
        {:ok, _endpoint} -> {:cont, [session.id | admitted]}
        {:error, parked} when parked in [:no_grant, :no_team] -> {:cont, admitted}
        {:error, _no_room} -> {:halt, admitted}
      end
    end)
    |> Enum.reverse()
  end

  # Written to the row first and to the cluster from the row, so the number the plane
  # believes and the number it asked for cannot differ: a write that failed leaves a row
  # the next tick will try again from.
  defp write(profile, plan) do
    case Fleet.put_profile(%{name: profile.name, replicas: plan.want}) do
      {:ok, updated} ->
        # Through the provisioner rather than straight to Kubernetes. What makes a worker
        # exist is the substrate's business; how many are wanted is this module's, and the
        # two were the same function until a profile could be provisioned another way.
        case Provisioner.for(updated).ensure(updated, actor: scaler()) do
          {:ok, _applied} ->
            Logger.info(
              "troupe plane: #{profile.name} #{plan.have} -> #{plan.want} worker(s) for " <>
                "#{plan.active} active and #{plan.pending} waiting"
            )

            true

          {:error, reason} ->
            # Left on the row. The next tick reads it, sees the cluster has not caught
            # up, and asks again — which is the right shape for a controller and is why
            # this does not retry here.
            Logger.warning(
              "troupe plane: could not scale #{profile.name} to #{plan.want}: #{inspect(reason)}"
            )

            false
        end

      {:error, changeset} ->
        Logger.warning("troupe plane: could not record #{profile.name}: #{inspect(changeset)}")
        false
    end
  end

  # Set the first tick a profile wants fewer workers than it has, cleared the moment it
  # wants as many or more. The clock lives on the row rather than in this process, so a
  # failover does not reset the grace period and keep a worker up for ever.
  defp mark_smaller(profile, plan, now) do
    smaller? = plan.asks_for < plan.have

    cond do
      smaller? and is_nil(profile.idle_since) ->
        {:ok, _} = Fleet.put_profile(%{name: profile.name, idle_since: now})

      not smaller? and not is_nil(profile.idle_since) ->
        {:ok, _} = Fleet.put_profile(%{name: profile.name, idle_since: nil})

      true ->
        :ok
    end
  end

  # Up at once and down after a wait. Somebody is waiting for a worker that is not there;
  # nobody is waiting for one that is.
  defp settled(want, have, _profile, _now) when want >= have, do: want

  defp settled(want, have, profile, now) do
    if smaller_long_enough?(profile, now), do: want, else: have
  end

  defp smaller_long_enough?(%Profile{idle_since: nil}, _now), do: false

  defp smaller_long_enough?(%Profile{idle_since: since}, now) do
    DateTime.diff(now, since, :second) >= @shrink_grace_seconds
  end

  # In sessions, converted to workers here and nowhere else. An administrator's ceiling
  # is a number of sessions; `spec.replicas` is a number of workers; the conversion has
  # one home so the two cannot drift.
  defp clamp(want, %Profile{max_sessions: nil}, _per_worker), do: {want, nil}

  defp clamp(want, %Profile{max_sessions: max}, per_worker) do
    allowed = ceil_div(max, per_worker)
    if want > allowed, do: {allowed, :max_sessions}, else: {want, nil}
  end

  # And under whatever the cluster admin's `TroupePolicy` allows. Not because admission
  # would let a larger number through — it would refuse it — but because a controller that
  # asked for something it knew would be refused would fail on every tick for ever, and
  # the person reading the log would be reading the plane's own mistake rather than a
  # policy they set on purpose.
  defp under_policy(want, capped_by) do
    case ClusterPolicy.current() do
      %{max_replicas: max} when is_integer(max) and max > 0 and want > max -> {max, :policy}
      _otherwise -> {want, capped_by}
    end
  end

  defp ceil_div(_numerator, denominator) when denominator <= 0, do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  # The scaler is not a person and the audit row says so. `Provision.apply/2` writes one
  # for every change to a custom resource, and a scale-up with no actor would be the one
  # change in the trail nobody could account for.
  defp scaler, do: %{subject: "system:scaler", role: :platform_admin}

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe fleet scaler")
    interval = Keyword.get(opts, :interval_ms, @tick_ms)
    Process.send_after(self(), :tick, interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    try do
      tick()
    rescue
      # A tick that raises must not take the scaler with it. The next one is fifteen
      # seconds away and will see the same profiles.
      exception ->
        Logger.error("troupe plane: scaler tick failed: #{Exception.message(exception)}")
    end

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defmodule Keeper do
    @moduledoc """
    Asks for the cluster's scaler on a timer, from every replica.

    The same shape as the scheduler's keeper and for the same reason: the singleton idiom
    starts an actor when it is first asked for, and nothing asks for this one the way a
    create asks for placement.
    """

    use GenServer

    alias Troupe.Plane.Fleet.Scaler

    @ask_ms 30_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(opts) do
      Process.set_label("troupe fleet scaler keeper")
      interval = Keyword.get(opts, :interval_ms, @ask_ms)
      send(self(), :ask)
      {:ok, %{interval_ms: interval}}
    end

    @impl GenServer
    def handle_info(:ask, state) do
      Scaler.ensure()
      Process.send_after(self(), :ask, state.interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end
end
