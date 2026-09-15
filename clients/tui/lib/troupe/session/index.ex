defmodule Troupe.Session.Index do
  @moduledoc """
  What a workspace has on disk: one summary per persisted session, built without
  starting it. This is what the TUI's session picker (`/resume`) and `troupe
  resume` without an id read.

  Sessions are found by the workspace they were started in — the state dir keys
  them by a hash of that path (`Troupe.Paths.sessions_root/1`), so listing the
  current directory's sessions costs one wildcard, not a scan of every project.

  Each session's log is streamed and only the lines that carry a branch's fate
  are decoded, so a session with a megabyte of `llm_delta` costs about as much
  as one with none (Decision 65).
  """

  alias Troupe.{Codec, Paths, Session}
  alias Troupe.Session.Log

  @typedoc "One branch of a persisted session, in the state the log left it in."
  @type branch :: %{
          path: String.t(),
          name: String.t(),
          state: atom(),
          prompt: String.t()
        }

  @typedoc """
  A session as the picker shows it: when it was created (from its id) and last
  written to (the log's mtime), whether it is closed, whether it is running in
  this VM right now, and its branches with the first one's prompt as the title.
  """
  @type entry :: %{
          session_id: String.t(),
          workspace: String.t(),
          dir: String.t(),
          created_at: integer() | nil,
          updated_at: integer() | nil,
          closed_at: integer() | nil,
          running?: boolean(),
          branches: [branch()],
          title: String.t()
        }

  # The only event types that change what the picker shows; every other line is
  # skipped without being decoded.
  @wanted ~w(branch_spawned branch_state branch_failed window_dismissed)

  @doc """
  This workspace's sessions, most recently written to first. The log's mtime has
  a resolution of a second, so sessions touched within the same one are ordered
  by when they were created — newest first either way.
  """
  @spec list(String.t()) :: [entry()]
  def list(workspace) do
    workspace
    |> Paths.sessions_root()
    |> Path.join("*/meta.json")
    |> Path.wildcard()
    |> Enum.flat_map(&entry/1)
    |> Enum.sort_by(&{&1.updated_at || 0, &1.created_at || 0}, :desc)
  end

  @doc "One session by id, or `:error` when this workspace has no such session."
  @spec fetch(String.t(), String.t()) :: {:ok, entry()} | :error
  def fetch(workspace, session_id) do
    case Enum.find(list(workspace), &(&1.session_id == session_id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "The branches a resumed session would put on screen: everything not dismissed."
  @spec live_branches(entry()) :: [branch()]
  def live_branches(%{branches: branches}),
    do: Enum.reject(branches, &(&1.state == :dismissed))

  defp entry(meta_path) do
    case Log.read_meta(meta_path) do
      {:ok, meta} ->
        dir = Path.dirname(meta_path)
        log = Path.join(dir, "events.jsonl")
        branches = branches(meta.session_id, log)

        [
          %{
            session_id: meta.session_id,
            workspace: meta.workspace,
            dir: dir,
            created_at: created_at(meta.session_id),
            updated_at: written_at(log),
            closed_at: meta.closed_at,
            running?: Session.whereis(meta.session_id, :session) != nil,
            branches: branches,
            title: title(branches)
          }
        ]

      :error ->
        []
    end
  end

  # The first branch's prompt, folded to one line. It is still model- and
  # user-supplied text: a renderer has to sanitise it (`Model.one_line/1`).
  defp title([]), do: "(no branches)"

  defp title([%{prompt: prompt} | _]) do
    case prompt |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> "(no prompt)"
      text -> text
    end
  end

  # The id starts as the creation time in base 36 (`Paths.new_session_id/1`).
  defp created_at(session_id) do
    with [stamp | _] <- String.split(session_id, "-"),
         {ms, ""} <- Integer.parse(stamp, 36) do
      ms
    else
      _ -> nil
    end
  end

  defp written_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) -> mtime * 1000
      _ -> nil
    end
  end

  defp branches(session_id, path) do
    path
    |> stream(session_id)
    |> Enum.reduce(%{}, &fold/2)
    |> Map.values()
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(&%{path: &1.path, name: &1.name, state: &1.state, prompt: &1.prompt})
  end

  defp stream(path, session_id) do
    if File.regular?(path) do
      pattern = :binary.compile_pattern(Enum.map(@wanted, &~s("type":"#{&1}")))

      path
      |> File.stream!()
      |> Stream.filter(&(:binary.match(&1, pattern) != :nomatch))
      |> Stream.flat_map(fn line ->
        case Codec.decode_event(session_id, line) do
          {:ok, event} -> [event]
          {:error, _reason} -> []
        end
      end)
    else
      []
    end
  end

  ## Fold — the Dispatcher's ledger, narrowed to what a picker row needs

  defp fold(%{type: :branch_spawned, agent_path: path, seq: seq, data: data}, acc) do
    Map.put_new(acc, path, %{
      path: path,
      name: Map.get(data, :name) || "?",
      state: :running,
      prompt: Map.get(data, :prompt) || "",
      seq: seq || 0
    })
  end

  defp fold(%{type: :branch_state, agent_path: path, data: %{state: branch_state}}, acc) do
    nested? = root(path) != path

    update(acc, root(path), fn branch ->
      cond do
        branch.state == :dismissed -> branch
        # A subagent finishing does not finish its branch, as in the Dispatcher's fold.
        nested? and branch_state == :done_unread -> branch
        true -> %{branch | state: branch_state}
      end
    end)
  end

  defp fold(%{type: :branch_failed, agent_path: path}, acc),
    do: update(acc, root(path), &%{&1 | state: :failed_unread})

  defp fold(%{type: :window_dismissed, agent_path: path}, acc),
    do: update(acc, path, &%{&1 | state: :dismissed})

  defp fold(_event, acc), do: acc

  defp update(acc, path, fun) do
    case Map.get(acc, path) do
      nil -> acc
      branch -> Map.put(acc, path, fun.(branch))
    end
  end

  defp root(path), do: path |> String.split("/") |> hd()
end
