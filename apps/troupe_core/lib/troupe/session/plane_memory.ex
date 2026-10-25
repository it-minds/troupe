defmodule Troupe.Session.PlaneMemory do
  @moduledoc """
  The organisation's memory documents a running session was last given (#55), held for the
  whole session so its agents read them at their next turn, and what its last turn read.

  A session starts with what its configuration was resolved with (`Troupe.PlaneMemory`).
  A save on the plane after that reaches it here: on a pod the plane tells the worker
  (`session.memory`), and on a person's machine the daemon, once it has a newer copy of
  `me.memory`, tells every session it runs. Each agent of the session compares what it
  reads with what it was given as its turn begins, takes the new documents, and says in
  its log what changed and to which version (`memory_changed`). Nothing changes in the
  middle of a turn, so the system prompt of a turn is the same on every call of it.

  **Asked as a turn begins.** A host that knows where the documents come from installs a
  check (`install_check/1`): a pod asks the plane, with what the session holds, whether that
  is in force, and is answered with the documents where it is not (`before_turn/2`). So a
  push lost between two turns leaves no turn on the versions before it. A host with no check
  (a person's machine, whose copy its daemon keeps) asks nothing. The root agent's turn asks,
  once a turn; a subagent takes what the root was given at its own next turn.

  **What each turn read** is kept here too (`read/2`, `reads/0`), each document's scope,
  name, version and hash and when the turn began, which a person's machine tells the plane
  with its poll, so the console sees which sessions are behind.

  Placed under `Session.Log` and above the agent, as `Session.ClientTools` is, so what was
  given outlives an agent's restart: a root started again from its first configuration
  reads it at its next turn. Its name carries what was given beside it, so a reader, as
  `Troupe.Session.resolved/1` is, asks the registry and not this process.
  """

  use GenServer

  alias Troupe.PlaneMemory
  alias Troupe.Protocol.Memory, as: Shape
  alias Troupe.Registry

  require Logger

  @typedoc "A document as a turn read it: its scope, name, version and hash."
  @type stamp :: %{String.t() => term()}

  @typedoc """
  What a host's check answers: `:current` where the session holds what is in force, the
  documents in force where it does not, or an error, which leaves the session as it is.
  """
  @type check :: (String.t(), [stamp()] -> {:ok, :current | [map()]} | {:error, term()})

  @doc false
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, session_id,
      name: {:via, Elixir.Registry, {Registry, key(session_id), nil}}
    )
  end

  @doc """
  Give a running session new documents, for its agents to read at their next turn.
  `{:error, :no_session}` where the session is not running here.
  """
  @spec put(String.t(), PlaneMemory.t()) :: :ok | {:error, :no_session}
  def put(session_id, %{documents: documents} = memory) when is_list(documents) do
    call(session_id, {:put, memory})
  end

  @doc """
  Give every session running here the same documents: what a person's machine does when
  its copy of the plane's memory changes, since every session on it reads that copy.
  Answers how many sessions were given them.
  """
  @spec put_all(PlaneMemory.t()) :: non_neg_integer()
  def put_all(%{documents: documents} = memory) when is_list(documents) do
    Enum.count(running(), &(put(&1, memory) == :ok))
  end

  @doc "What the session was last given since it started, or `nil` for nothing since."
  @spec given(String.t()) :: PlaneMemory.t() | nil
  def given(session_id), do: Registry.value(key(session_id))

  @doc """
  As the session's turn begins, with `documents` its configuration holds: ask the host's
  check whether what the session holds (what it was last given, or those) is in force, and
  where it is not, give it what is, for the turn to take. A check that cannot answer leaves
  the session as it is, said in the host's debug log, never stopping the turn.
  """
  @spec before_turn(String.t(), [map()] | nil) :: :ok
  def before_turn(session_id, documents) do
    case Application.get_env(:troupe_core, :plane_memory_check) do
      fun when is_function(fun, 2) -> ask(fun, session_id, (given(session_id) || %{documents: documents}).documents)
      _no_check -> :ok
    end
  end

  defp ask(fun, session_id, held) do
    case fun.(session_id, Enum.map(List.wrap(held), &Shape.stamp/1)) do
      {:ok, :current} ->
        :ok

      {:ok, in_force} when is_list(in_force) ->
        {memory, _warnings} = PlaneMemory.in_force(in_force)
        _given = put(session_id, memory)
        :ok

      {:error, reason} ->
        Logger.debug("troupe: #{session_id} could not ask whether its memory is current: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Install `fun` as how this host asks, as a turn begins, whether a session's memory is in force."
  @spec install_check(check()) :: :ok
  def install_check(fun) when is_function(fun, 2),
    do: Application.put_env(:troupe_core, :plane_memory_check, fun)

  @doc "Keep `documents` as what the session's turn beginning now reads."
  @spec read(String.t(), [map()] | nil) :: :ok
  def read(session_id, documents) do
    case call(session_id, {:read, Enum.map(List.wrap(documents), &Shape.stamp/1), DateTime.utc_now()}) do
      :ok -> :ok
      {:error, :no_session} -> :ok
    end
  end

  @doc """
  What every session running here read at its last turn, for those that have had one: each
  `session_id`, `turn_at` and its `documents`' stamps. What a person's machine tells the plane
  with its poll of `me.memory`.
  """
  @spec reads() :: [%{String.t() => term()}]
  def reads do
    running()
    |> Enum.flat_map(fn session_id ->
      case call(session_id, :last_read) do
        %{} = read -> [Map.put(read, "session_id", session_id)]
        _none -> []
      end
    end)
  end

  defp running,
    do: Elixir.Registry.select(Registry, [{{{:plane_memory, :"$1"}, :_, :_}, [], [:"$1"]}])

  defp call(session_id, message) do
    case Registry.whereis(key(session_id)) do
      nil -> {:error, :no_session}
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _gone -> {:error, :no_session}
  end

  defp key(session_id), do: {:plane_memory, session_id}

  @impl GenServer
  def init(session_id) do
    Process.set_label("troupe plane memory #{session_id}")
    {:ok, %{session_id: session_id, read: nil}}
  end

  @impl GenServer
  def handle_call({:put, memory}, _from, state) do
    {^memory, _before} =
      Elixir.Registry.update_value(Registry, key(state.session_id), fn _before -> memory end)

    {:reply, :ok, state}
  end

  def handle_call({:read, stamps, at}, _from, state) do
    {:reply, :ok, %{state | read: %{"documents" => stamps, "turn_at" => DateTime.to_iso8601(at)}}}
  end

  def handle_call(:last_read, _from, state), do: {:reply, state.read, state}
end
