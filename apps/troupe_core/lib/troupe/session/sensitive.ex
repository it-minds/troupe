defmodule Troupe.Session.Sensitive do
  @moduledoc """
  Whether a session is sensitive, held once for the whole session tree.

  A session becomes sensitive by what it read: a tool call that matches one of its worker
  profile's `sensitive.markedBy` rules (`Troupe.Tools.authorize/4` asks `mark/3` before it
  lets the call run), or a person's mark by hand. From then on the profile's
  `sensitive.deny` rules refuse at the gate, in the root and in every subagent, which is why
  the mark lives here, under `Session.Log` and above every agent, and not in an agent's
  state or its configuration, both of which are copied once per agent and never change.

  **The mark is durable.** `session_marked_sensitive` is appended to the log once, by the
  first mark, before `mark/3` returns: the caller is the gate, and the call it is about to
  let run may return the data the mark is for. Every later mark is answered with the first.
  A tree that comes back folds the event from the log; a session the plane knows is
  sensitive and whose log does not say so yet (a person marked it while it slept) is given
  the mark with its activation, and the event is appended then, so the log and the plane
  agree.

  **Nothing clears it.** There is no function here, no event in the schema and no method
  on any host that takes the mark away: a sensitive session is sensitive until it is erased.

  A crash here restarts what is below it (`rest_for_one`), the agents included, which read
  the mark again from this process as it folds it back from the log.
  """

  use GenServer

  alias Troupe.Protocol.Event
  alias Troupe.Registry
  alias Troupe.Session.Log

  @type mark :: %{
          required(String.t()) => term()
        }

  @root ["root"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.sensitive(session_id))
  end

  @doc """
  The session's mark, as its `session_marked_sensitive` says it (`how`, `by`, `rule`,
  `call_id`, `at`), or `nil` while it is not sensitive, or where no tree holds it.
  """
  @spec mark_of(String.t() | nil) :: mark() | nil
  def mark_of(nil), do: nil

  def mark_of(session_id) do
    case Registry.whereis({:sensitive, session_id}) do
      nil -> nil
      pid -> GenServer.call(pid, :mark)
    end
  catch
    :exit, _gone -> nil
  end

  @doc """
  Mark the session sensitive, once: the first mark appends `session_marked_sensitive` with
  `data` (`how` is `call` or `person`; `by` the tool's name or the person's subject; `rule`
  and `call_id` for a call) and answers `{:ok, mark}`; a later one appends nothing and
  answers the first. `agent_path` is whose call it was, for the log's reader; the event is
  the session's whoever made it. `{:error, :no_session}` where no tree holds the session.
  """
  @spec mark(String.t(), map(), [String.t()]) :: {:ok, mark()} | {:error, :no_session}
  def mark(session_id, data, agent_path \\ @root) do
    case Registry.whereis({:sensitive, session_id}) do
      nil -> {:error, :no_session}
      pid -> GenServer.call(pid, {:mark, data, agent_path}, 20_000)
    end
  end

  # -- server ---------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    folded = fold(Log.replay(session_id, @root))
    mark = folded || given(session_id, Keyword.get(opts, :given))
    {:ok, %{session_id: session_id, mark: mark}}
  end

  @impl GenServer
  def handle_call(:mark, _from, state), do: {:reply, state.mark, state}

  def handle_call({:mark, _data, _path}, _from, %{mark: %{} = mark} = state),
    do: {:reply, {:ok, mark}, state}

  def handle_call({:mark, data, path}, _from, state) do
    mark = append(state.session_id, data, path)
    {:reply, {:ok, mark}, %{state | mark: mark}}
  end

  # What the log says, the first mark being the one that holds.
  defp fold(events) do
    Enum.find_value(events, fn
      %Event{type: "session_marked_sensitive", data: data} -> data
      _other -> nil
    end)
  end

  # The plane's word, at an activation, for a session whose log does not say it yet.
  defp given(session_id, %{"at" => at} = given) when is_binary(at) do
    data =
      %{"how" => given["how"] || "person", "by" => given["by"] || "unknown", "at" => at}
      |> put_present("rule", given["rule"])
      |> put_present("call_id", given["call_id"])
      |> put_present("display_name", given["display_name"])

    {:ok, _seq} = Log.append(session_id, @root, :session_marked_sensitive, data)
    data
  end

  defp given(_session_id, _none), do: nil

  defp append(session_id, data, path) do
    data =
      data
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new_lazy("at", fn -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601() end)
      |> then(fn data -> if path == @root, do: data, else: Map.put(data, "agent", path) end)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    {:ok, _seq} = Log.append(session_id, @root, :session_marked_sensitive, data)
    data
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
