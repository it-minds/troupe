defmodule Troupe.Plane.Budget.Rung do
  @moduledoc """
  The one server behind every rung of the ladder `Troupe.Plane.Budget` walks: the person's,
  the profile's, the team's and the platform's.

  Each rung is one actor per key, reached through `Troupe.Plane.Singleton` under the rung
  module's own name, because two replicas deciding whether a reservation fits is how
  somebody spends more than they have. What a rung decides is the same at every scope:
  what it has spent this period, plus what it is holding, plus what is asked, against its
  ceiling. So the deciding lives here once, and a rung module says only what is its own:
  where its ceiling and its spend come from, and what its summary names.

  A rung decides and holds; it does not write. One promise is one row, written by
  `Troupe.Plane.Budget` once every rung has agreed: a row written by the first rung would
  be counted by the rungs after it as though somebody else had made it.

  ## Reloaded, not trusted

  Every reserve and every inspect reloads from the ledger first. Charges reach the ledger
  through the team's actor, a pod restart or a replica handover can move a count under
  this one, and the month turns over at midnight UTC on the 1st: a count held in a process
  and not reloaded becomes permanently wrong the first time anything happens it did not
  see. One query per session create is not a hot path.

  Reloading is also what makes respawning on another replica safe: the new actor reads
  back from the ledger what was promised.
  """

  use GenServer

  alias Troupe.Plane.Singleton

  @enforce_keys [:rung, :key]
  defstruct [:rung, :key, ceiling: :unlimited, spent_micros: 0, reservations: %{}, loaded: %{}]

  @type t :: %__MODULE__{
          rung: module(),
          key: term(),
          ceiling: pos_integer() | :unlimited,
          spent_micros: non_neg_integer(),
          reservations: %{optional(String.t()) => non_neg_integer()},
          loaded: map()
        }

  @typedoc """
  What a rung reads for its key: its ceiling (`:unlimited` where none is set, zero and
  `nil` included), what it has spent this period, the reservations the ledger knows about,
  and anything else its summary names.
  """
  @type loaded :: %{
          required(:ceiling) => pos_integer() | :unlimited,
          required(:spent_micros) => non_neg_integer(),
          required(:reservations) => %{optional(String.t()) => non_neg_integer()},
          optional(atom()) => term()
        }

  @doc "The ceiling, the spend and the open reservations for `key`, read now."
  @callback load(key :: term()) :: loaded()

  @doc "The fields of this rung's summary that are its own: its scope, its key, its ceiling."
  @callback summary(key :: term(), loaded()) :: map()

  @doc "The process label, for diagnostics."
  @callback label(key :: term()) :: String.t()

  @doc "A call this rung answers beyond reserve, release and inspect."
  @callback handle_call(message :: term(), GenServer.from(), t()) :: {:reply, term(), t()}

  @optional_callbacks handle_call: 3

  defmacro __using__(_opts) do
    rung = __MODULE__

    quote do
      @behaviour unquote(rung)

      @doc false
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts), do: unquote(rung).start_link(__MODULE__, opts)
    end
  end

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(rung, opts) do
    GenServer.start_link(__MODULE__, {rung, Keyword.fetch!(opts, :key)},
      name: Keyword.fetch!(opts, :name)
    )
  end

  @doc "Whether `rung` can promise `amount_micros` more for `key`; held, not written."
  @spec reserve(module(), term(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:over_budget, map()}}
  def reserve(rung, key, session_id, amount_micros) do
    Singleton.call(rung, key, {:reserve, session_id, amount_micros})
  end

  @doc "Give a promise back."
  @spec release(module(), term(), String.t()) :: :ok
  def release(rung, key, session_id), do: Singleton.call(rung, key, {:release, session_id})

  @doc "What the ceiling is and how much of it is gone, reloaded."
  @spec inspect_state(module(), term()) :: map()
  def inspect_state(rung, key), do: Singleton.call(rung, key, :inspect)

  @doc """
  A stored budget as a ceiling. Zero and `nil` mean no limit rather than no money: a team,
  person or profile that has never been given one should not be unable to work.
  """
  @spec ceiling(integer() | nil) :: pos_integer() | :unlimited
  def ceiling(budget) when is_integer(budget) and budget > 0, do: budget
  def ceiling(_none), do: :unlimited

  @impl GenServer
  def init({rung, key}) do
    Process.set_label(rung.label(key))
    {:ok, %__MODULE__{rung: rung, key: key}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl GenServer
  def handle_call({:reserve, session_id, amount}, _from, state) do
    state = load(state)

    cond do
      # Reserving twice for one session is a retry, not a second slice.
      Map.has_key?(state.reservations, session_id) ->
        {:reply, {:ok, summary(state)}, state}

      fits?(state, amount) ->
        state = %{state | reservations: Map.put(state.reservations, session_id, amount)}
        {:reply, {:ok, summary(state)}, state}

      true ->
        {:reply, {:error, {:over_budget, summary(state)}}, state}
    end
  end

  def handle_call({:release, session_id}, _from, state) do
    {:reply, :ok, %{state | reservations: Map.delete(state.reservations, session_id)}}
  end

  def handle_call(:inspect, _from, state) do
    state = load(state)
    {:reply, summary(state), state}
  end

  def handle_call(message, from, %__MODULE__{rung: rung} = state) do
    rung.handle_call(message, from, state)
  end

  # Reservations the ledger knows about are merged *under* what this actor is holding, so
  # a session granted a moment ago and not yet written is counted once rather than twice.
  defp load(%__MODULE__{rung: rung, key: key} = state) do
    loaded = rung.load(key)

    %{
      state
      | ceiling: loaded.ceiling,
        spent_micros: loaded.spent_micros,
        reservations: Map.merge(loaded.reservations, state.reservations),
        loaded: loaded
    }
  end

  defp fits?(%__MODULE__{ceiling: :unlimited}, _amount), do: true

  defp fits?(state, amount), do: state.spent_micros + reserved(state) + amount <= state.ceiling

  defp reserved(state), do: state.reservations |> Map.values() |> Enum.sum()

  defp summary(%__MODULE__{rung: rung, key: key, loaded: loaded} = state) do
    remaining =
      case state.ceiling do
        :unlimited -> :unlimited
        cap -> max(cap - state.spent_micros - reserved(state), 0)
      end

    key
    |> rung.summary(loaded)
    |> Map.merge(%{
      spent_micros: state.spent_micros,
      reserved_micros: reserved(state),
      remaining_micros: remaining,
      node: node()
    })
  end
end
