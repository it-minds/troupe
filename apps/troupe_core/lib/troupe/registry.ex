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

  @spec watcher(String.t()) :: GenServer.name()
  def watcher(session_id), do: via({:watcher, session_id})

  @doc "The process that turns filesystem changes into durable `fs_changed` events."
  @spec files(String.t()) :: GenServer.name()
  def files(session_id), do: via({:files, session_id})

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
