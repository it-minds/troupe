defmodule Troupe.Plane.Placement do
  @moduledoc """
  One actor per profile, deciding where a session goes.

  Capacity is the thing two replicas must not decide at once. Reading the pods, picking
  the least-loaded, and recording the reservation is a read-decide-write, and two of
  those interleaved is how a pod ends up with more sessions than it is configured for.
  So it happens in one process, registered cluster-wide with `:global`, and the answer
  is serialised by its mailbox.

  Its counts are held in memory and are a *cache*: they are loaded from PostgreSQL at
  start-up and reloaded whenever the actor respawns after a replica loss. What makes
  the count true is that every reservation is written to the database in the same call
  that grants it, so a restart reads back exactly what was granted.
  """

  use GenServer

  alias Troupe.Plane.{Fleet, Sessions, Singleton}
  alias Troupe.Plane.Fleet.Worker

  @enforce_keys [:profile]
  defstruct [:profile, capacities: %{}, loaded_at: nil]

  @type reservation :: %{worker: Worker.t(), profile: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Reserve a slot for a session on the least-loaded healthy pod.

  `{:error, :at_capacity}` when every pod of the profile is full, draining, unhealthy,
  or above its disk high watermark. That is not a failure to retry blindly: it means
  the profile needs more replicas, and the caller should say so.
  """
  @spec reserve(String.t(), String.t()) :: {:ok, reservation()} | {:error, term()}
  def reserve(profile, session_id) do
    Singleton.call(__MODULE__, profile, {:reserve, session_id})
  end

  @doc "Give a slot back, because the session went dormant, moved, or was erased."
  @spec release(String.t(), String.t()) :: :ok
  def release(profile, session_id) do
    Singleton.call(__MODULE__, profile, {:release, session_id})
  end

  @doc """
  Pick a pod to *read* a dormant session from, preferring one with a warm cache.

  Reading does not consume capacity — a reader is a short-lived process with no agent
  and no model call — so this does not reserve.
  """
  @spec reader(String.t(), String.t() | nil) :: {:ok, Worker.t()} | {:error, term()}
  def reader(profile, preferred_worker_id \\ nil) do
    Singleton.call(__MODULE__, profile, {:reader, preferred_worker_id})
  end

  @doc "What this actor believes, for tests and diagnostics."
  @spec inspect_state(String.t()) :: map()
  def inspect_state(profile), do: Singleton.call(__MODULE__, profile, :inspect)

  @impl GenServer
  def init(opts) do
    profile = Keyword.fetch!(opts, :key)
    Process.set_label("troupe placement #{profile}")
    {:ok, %__MODULE__{profile: profile}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl GenServer
  def handle_call({:reserve, session_id}, _from, state) do
    {state, workers} = refresh(state)

    case choose(state, workers) do
      # A profile with no placeable pod at all is not full, it is absent, and the two
      # want opposite things done about them: one needs replicas, the other needs
      # somebody to look at why the pods are not there. Both used to answer "every pod
      # is full", and that sentence has sent more than one person to the wrong place.
      nil when workers == [] ->
        {:reply, {:error, :no_healthy_worker}, state}

      nil ->
        {:reply, {:error, :at_capacity}, state}

      worker ->
        # Written before it is granted. A reservation that existed only in this process
        # would be lost the moment the replica holding it went away, and the next actor
        # would hand the same slot out again.
        case Sessions.place(session_id, worker) do
          {:ok, _session} ->
            {:reply, {:ok, %{worker: worker, profile: state.profile}}, charge(state, worker.id, 1)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:release, session_id}, _from, state) do
    case Sessions.unplace(session_id) do
      {:ok, worker_id} -> {:reply, :ok, charge(state, worker_id, -1)}
      :ok -> {:reply, :ok, state}
    end
  end

  def handle_call({:reader, preferred}, _from, state) do
    workers = state.profile |> Fleet.list_workers() |> Enum.filter(& &1.healthy)

    # A pod with the session's cache already on disk can serve its history without
    # fetching a segment from object storage first.
    chosen =
      Enum.find(workers, &(&1.id == preferred)) || Enum.min_by(workers, & &1.active_sessions, fn -> nil end)

    case chosen do
      nil -> {:reply, {:error, :no_healthy_worker}, state}
      worker -> {:reply, {:ok, worker}, state}
    end
  end

  def handle_call(:inspect, _from, state) do
    state = load(state)

    {:reply,
     %{
       profile: state.profile,
       capacities: state.capacities,
       total_capacity: total_capacity(state),
       used: used(state),
       node: node()
     }, state}
  end

  # -- choosing ---------------------------------------------------------------

  defp choose(state, workers) do
    workers
    |> Enum.map(&{&1, room(state, &1)})
    |> Enum.filter(fn {_worker, room} -> room > 0 end)
    |> Enum.max_by(fn {_worker, room} -> room end, fn -> nil end)
    |> case do
      nil -> nil
      {worker, _room} -> worker
    end
  end

  # The room this actor believes a pod has. Its own count wins over the heartbeat's:
  # a heartbeat is at most five seconds old and a reservation granted since then is
  # already spent.
  defp room(state, %Worker{} = worker) do
    used = Map.get(state.capacities, worker.id, worker.active_sessions)
    max(worker.capacity - used, 0)
  end

  defp charge(state, nil, _delta), do: state

  defp charge(state, worker_id, delta) do
    capacities = Map.update(state.capacities, worker_id, max(delta, 0), &max(&1 + delta, 0))
    %{state | capacities: capacities}
  end

  # -- state ------------------------------------------------------------------

  # Reloaded from the database rather than remembered, which is what makes respawning
  # on another replica safe: every reservation was written before it was granted, so
  # this reads back exactly what was handed out.
  defp load(state) do
    counts = Sessions.active_counts_by_worker(state.profile)
    %{state | capacities: counts, loaded_at: DateTime.utc_now()}
  end

  # The pod list is read every time — pods come and go, and it is a handful of indexed
  # rows. The session *counts* are not: this actor is the only thing that grants a
  # slot, so its own numbers are the authority between reloads, and counting sessions
  # again on every reserve would put a group-by in front of every create.
  #
  # A pod it has never seen is the exception. That pod's sessions were placed by an
  # earlier incarnation of this actor, so its count has to come from the database.
  defp refresh(state) do
    workers = Fleet.placeable(state.profile)

    if Enum.all?(workers, &Map.has_key?(state.capacities, &1.id)) do
      {state, workers}
    else
      {load(state), workers}
    end
  end

  defp total_capacity(state) do
    state.profile |> Fleet.list_workers() |> Enum.map(& &1.capacity) |> Enum.sum()
  end

  defp used(state), do: state.capacities |> Map.values() |> Enum.sum()
end
