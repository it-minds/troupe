defmodule Troupe.Registry do
  @moduledoc """
  Names for every actor in a session.

  Keys are shaped so `:observer`'s process list reads as the delegation tree, and so
  a subagent five levels down can be addressed without threading pids through the
  supervision tree.

  `agent_path` is the list of names from the root, e.g. `["root"]` or
  `["root", "explore#1"]`.
  """

  @registry __MODULE__

  @type agent_path :: [String.t()]

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @spec session(String.t()) :: GenServer.name()
  def session(session_id), do: via({:session, session_id})

  @spec log(String.t()) :: GenServer.name()
  def log(session_id), do: via({:log, session_id})

  @spec approvals(String.t()) :: GenServer.name()
  def approvals(session_id), do: via({:approvals, session_id})

  @doc "Questions an agent asked a person, waiting for their answer (Decision 651)."
  @spec questions(String.t()) :: GenServer.name()
  def questions(session_id), do: via({:questions, session_id})

  @spec watcher(String.t()) :: GenServer.name()
  def watcher(session_id), do: via({:watcher, session_id})

  @doc "The process that runs the session's `/loop` (Decision 681)."
  @spec loop(String.t()) :: GenServer.name()
  def loop(session_id), do: via({:loop, session_id})

  @doc "The process that turns filesystem changes into durable `fs_changed` events."
  @spec files(String.t()) :: GenServer.name()
  def files(session_id), do: via({:files, session_id})

  @doc "The workspace's own MCP servers for a session (Decision 654)."
  @spec session_mcp(String.t()) :: GenServer.name()
  def session_mcp(session_id), do: via({:session_mcp, session_id})

  @doc "One local MCP server on its standard streams."
  @spec mcp_server(String.t(), String.t()) :: GenServer.name()
  def mcp_server(session_id, name), do: via({:mcp_server, session_id, name})

  @doc "Tools an attached client hosts for this session, and who may invoke them."
  @spec client_tools(String.t()) :: GenServer.name()
  def client_tools(session_id), do: via({:client_tools, session_id})

  @doc "The session's compact projection, for fleet and summary subscribers."
  @spec summary(String.t()) :: GenServer.name()
  def summary(session_id), do: via({:summary, session_id})

  @doc "The scripted model, when the fake provider is selected."
  @spec fake(String.t()) :: GenServer.name()
  def fake(session_id), do: via({:fake, session_id})

  @spec node_sup(String.t(), agent_path()) :: GenServer.name()
  def node_sup(session_id, path), do: via({:node, session_id, path})

  @spec tasks(String.t(), agent_path()) :: GenServer.name()
  def tasks(session_id, path), do: via({:tasks, session_id, path})

  @spec children_sup(String.t(), agent_path()) :: GenServer.name()
  def children_sup(session_id, path), do: via({:children, session_id, path})

  @spec agent(String.t(), agent_path()) :: GenServer.name()
  def agent(session_id, path), do: via({:agent, session_id, path})

  @doc "The pid registered under a key, or `nil`."
  @spec whereis(tuple()) :: pid() | nil
  def whereis(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Claim a key for the calling process: `true` the first time, `false` while the process
  that claimed it lives. `Troupe.Session.Log.first?/2` claims one for a whole session.
  """
  @spec first?(tuple()) :: boolean()
  def first?(key) do
    case Registry.register(@registry, key, nil) do
      {:ok, _owner} -> true
      {:error, {:already_registered, _pid}} -> false
    end
  end

  @spec agent_pid(String.t(), agent_path()) :: pid() | nil
  def agent_pid(session_id, path), do: whereis({:agent, session_id, path})

  @spec watcher_pid(String.t()) :: pid() | nil
  def watcher_pid(session_id), do: whereis({:watcher, session_id})

  @doc """
  Every registered key belonging to a session, for diagnostics and for asserting
  that a killed subtree left nothing behind.
  """
  @spec keys_for_session(String.t()) :: [tuple()]
  def keys_for_session(session_id) do
    Registry.select(@registry, [
      {{:"$1", :"$2", :"$3"}, [], [:"$1"]}
    ])
    |> Enum.filter(fn
      {_kind, ^session_id} -> true
      {_kind, ^session_id, _path} -> true
      _ -> false
    end)
  end

  @doc "Every live agent path under a prefix, including the prefix itself."
  @spec agent_paths_under(String.t(), agent_path()) :: [agent_path()]
  def agent_paths_under(session_id, prefix) do
    session_id
    |> keys_for_session()
    |> Enum.flat_map(fn
      {:agent, _sid, path} -> if List.starts_with?(path, prefix), do: [path], else: []
      _ -> []
    end)
  end

  defp via(key), do: {:via, Registry, {@registry, key}}
end
