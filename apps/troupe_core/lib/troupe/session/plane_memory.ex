defmodule Troupe.Session.PlaneMemory do
  @moduledoc """
  The organisation's memory documents a running session was last given (#55), held for the
  whole session so its agents read them at their next turn.

  A session starts with what its configuration was resolved with (`Troupe.PlaneMemory`).
  A save on the plane after that reaches it here: on a pod the plane tells the worker
  (`session.memory`), and on a person's machine the daemon, once it has a newer copy of
  `me.memory`, tells every session it runs. Each agent of the session compares what it
  reads with what it was given as its turn begins, takes the new documents, and says in
  its log what changed and to which version (`memory_changed`). Nothing changes in the
  middle of a turn, so the system prompt of a turn is the same on every call of it.

  Placed under `Session.Log` and above the agent, as `Session.ClientTools` is, so what was
  given outlives an agent's restart: a root started again from its first configuration
  reads it at its next turn. Its name carries what was given beside it, so a reader, as
  `Troupe.Session.resolved/1` is, asks the registry and not this process.
  """

  use GenServer

  alias Troupe.PlaneMemory
  alias Troupe.Registry

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
    case Registry.whereis(key(session_id)) do
      nil -> {:error, :no_session}
      pid -> GenServer.call(pid, {:put, memory})
    end
  catch
    :exit, _gone -> {:error, :no_session}
  end

  @doc """
  Give every session running here the same documents: what a person's machine does when
  its copy of the plane's memory changes, since every session on it reads that copy.
  Answers how many sessions were given them.
  """
  @spec put_all(PlaneMemory.t()) :: non_neg_integer()
  def put_all(%{documents: documents} = memory) when is_list(documents) do
    Registry
    |> Elixir.Registry.select([{{{:plane_memory, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.count(&(put(&1, memory) == :ok))
  end

  @doc "What the session was last given since it started, or `nil` for nothing since."
  @spec given(String.t()) :: PlaneMemory.t() | nil
  def given(session_id), do: Registry.value(key(session_id))

  defp key(session_id), do: {:plane_memory, session_id}

  @impl GenServer
  def init(session_id) do
    Process.set_label("troupe plane memory #{session_id}")
    {:ok, session_id}
  end

  @impl GenServer
  def handle_call({:put, memory}, _from, session_id) do
    {^memory, _before} =
      Elixir.Registry.update_value(Registry, key(session_id), fn _before -> memory end)

    {:reply, :ok, session_id}
  end
end
