defmodule Troupe.Agent.Writes do
  @moduledoc """
  What an agent and the agents under it wrote through their file tools, read off the log
  (#554, Decision 847).

  A `finish` reports it as a stat and where to read the rest; `read_branch` gives the whole
  diff, and only when it is asked to, because a diff handed back by default is the context
  a delegation exists to save. It is counted from the `write_file` and `edit_file` calls
  that succeeded, in the order they ran: an edit by the lines its old and new text differ
  in, a write by the lines it wrote, since what the file held before is not in the log. A
  command run through `shell` can change files too, and none of that is here: the stat
  says how many commands ran instead.

  A subagent works in its parent's workspace, so this is the one diff that is a child's
  own: a `git diff` of the workspace holds the parent's and its siblings' changes as well.
  """

  alias Troupe.Protocol.Event

  @tools ~w(write_file edit_file)

  # The files a stat names before it says how many more there are.
  @listed 20

  @typedoc "One write that succeeded."
  @type write :: %{path: String.t(), tool: String.t(), old: String.t() | nil, new: String.t()}

  @doc """
  The writes of the agent at `path` and every agent under it, in the order they ran, and
  how many commands they ran: a `shell` call whose approval was refused is not one.
  """
  @spec of([Event.t()], [String.t()]) :: {[write()], non_neg_integer()}
  def of(events, path) do
    mine = Enum.filter(events, &under?(&1.agent, path))

    done =
      for %Event{type: "tool_call_completed", agent: agent, data: %{"ok" => true} = data} <- mine,
          into: MapSet.new(),
          do: {agent, data["call_id"]}

    started =
      for %Event{type: "tool_call_started", agent: agent, data: data} <- mine, do: {agent, data}

    writes =
      for {agent, %{"name" => name} = data} <- started,
          name in @tools,
          MapSet.member?(done, {agent, data["call_id"]}),
          %{} = write <- [write(name, data["args"])],
          do: write

    # A command whose approval was refused never ran, and changed nothing to count.
    refused =
      for %Event{type: "approval_decided", agent: agent, data: %{"decision" => "deny"} = data} <-
            mine,
          into: MapSet.new(),
          do: {agent, data["call_id"]}

    commands =
      Enum.count(started, fn {agent, data} ->
        data["name"] == "shell" and not MapSet.member?(refused, {agent, data["call_id"]})
      end)

    {writes, commands}
  end

  @doc """
  What `finish` reports as changed: each file with the lines added and removed, the
  totals, the commands not counted, and whose writes they were, so the reader knows where
  to ask for the diff.
  """
  @spec changed([Event.t()], [String.t()], String.t()) :: map()
  def changed(events, path, session_id) do
    {writes, commands} = of(events, path)
    files = files(writes)

    %{
      "files" => files,
      "added" => files |> Enum.map(& &1["added"]) |> Enum.sum(),
      "removed" => files |> Enum.map(& &1["removed"]) |> Enum.sum(),
      "commands" => commands,
      "session_id" => session_id,
      "agent" => path
    }
  end

  @doc """
  A `changed` as a report says it: one line, and under it the files, the commands not
  counted and what the agent said it changed besides.
  """
  @spec describe(map() | nil) :: String.t()
  def describe(nil), do: "not reported"

  def describe(%{"files" => files} = changed) do
    commands = changed["commands"] || 0

    head =
      cond do
        files != [] ->
          "#{n_files(length(files))}, +#{changed["added"]} -#{changed["removed"]}; " <>
            "the full diff: #{read(changed)}"

        commands > 0 ->
          "no file through its file tools"

        true ->
          "nothing"
      end

    under =
      listed(files) ++
        if(commands > 0, do: ["not counted: what its #{n_commands(commands)} changed"], else: []) ++
        if(is_binary(changed["said"]), do: ["it says: " <> changed["said"]], else: [])

    Enum.join([head | Enum.map(under, &("  " <> &1))], "\n")
  end

  @doc """
  The whole diff of the writes, as `read_branch` gives it when asked: each write as a
  hunk, in the order they ran.
  """
  @spec diff({[write()], non_neg_integer()}) :: String.t()
  def diff({writes, commands}) do
    files = files(writes)

    head =
      case files do
        [] ->
          "No file was written through the file tools."

        _ ->
          "#{n_files(length(files))}, +#{sum(files, "added")} -#{sum(files, "removed")}, " <>
            "from its write_file and edit_file calls in the order they ran."
      end

    note =
      if commands > 0,
        do: " What its #{n_commands(commands)} changed is not in it.",
        else: ""

    Enum.join([head <> note | Enum.map(writes, &hunk/1)], "\n\n")
  end

  # -- reading the calls ---------------------------------------------------------------

  defp under?(agent, path) when is_list(agent), do: Enum.take(agent, length(path)) == path
  defp under?(_agent, _path), do: false

  defp write("write_file", %{"path" => path, "content" => content})
       when is_binary(path) and is_binary(content),
       do: %{path: tidy(path), tool: "write_file", old: nil, new: content}

  defp write("edit_file", %{"path" => path, "old_string" => old, "new_string" => new})
       when is_binary(path) and is_binary(old) and is_binary(new),
       do: %{path: tidy(path), tool: "edit_file", old: old, new: new}

  defp write(_name, _args), do: nil

  defp tidy("./" <> path), do: tidy(path)
  defp tidy(path), do: path

  # Each file once, where it was first written, with the lines its writes added and
  # removed. One written whole says so: what it held before is not counted.
  defp files(writes) do
    writes
    |> Enum.reduce({[], %{}}, fn write, {order, by_path} ->
      {added, removed} = count(write)
      whole? = write.tool == "write_file"

      entry =
        by_path
        |> Map.get(write.path, %{"path" => write.path, "added" => 0, "removed" => 0})
        |> Map.update!("added", &(&1 + added))
        |> Map.update!("removed", &(&1 + removed))
        |> then(&if(whole?, do: Map.put(&1, "whole", true), else: &1))

      order = if Map.has_key?(by_path, write.path), do: order, else: [write.path | order]
      {order, Map.put(by_path, write.path, entry)}
    end)
    |> then(fn {order, by_path} -> order |> Enum.reverse() |> Enum.map(&by_path[&1]) end)
  end

  defp count(%{tool: "write_file", new: new}), do: {length(lines(new)), 0}

  defp count(%{old: old, new: new}) do
    old
    |> lines()
    |> List.myers_difference(lines(new))
    |> Enum.reduce({0, 0}, fn
      {:ins, lines}, {added, removed} -> {added + length(lines), removed}
      {:del, lines}, {added, removed} -> {added, removed + length(lines)}
      {:eq, _lines}, acc -> acc
    end)
  end

  defp hunk(%{tool: "write_file", path: path, new: new}) do
    Enum.join(
      ["--- #{path}", "+++ #{path}", "@@ write_file: the whole file as written @@"] ++
        Enum.map(lines(new), &("+" <> &1)),
      "\n"
    )
  end

  defp hunk(%{path: path, old: old, new: new}) do
    body =
      old
      |> lines()
      |> List.myers_difference(lines(new))
      |> Enum.flat_map(fn
        {:eq, lines} -> Enum.map(lines, &(" " <> &1))
        {:del, lines} -> Enum.map(lines, &("-" <> &1))
        {:ins, lines} -> Enum.map(lines, &("+" <> &1))
      end)

    Enum.join(["--- #{path}", "+++ #{path}", "@@ edit_file @@" | body], "\n")
  end

  defp lines(""), do: []

  defp lines(text) do
    text = String.replace(text, "\r\n", "\n")
    lines = String.split(text, "\n")
    if String.ends_with?(text, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  # -- saying it -----------------------------------------------------------------------

  defp listed(files) do
    shown =
      files
      |> Enum.take(@listed)
      |> Enum.map(fn file ->
        "#{file["path"]} +#{file["added"]} -#{file["removed"]}" <>
          if(file["whole"], do: " (written whole)", else: "")
      end)

    case length(files) - @listed do
      more when more > 0 -> shown ++ ["and #{more} more"]
      _ -> shown
    end
  end

  # A subagent is read by its path in the session it ran in; a root, a branch of some
  # other session, by its session.
  defp read(%{"agent" => ["root"], "session_id" => id}),
    do: ~s[read_branch(session_id: "#{id}", diff: true)]

  defp read(%{"agent" => path}), do: ~s[read_branch(child: "#{Enum.join(path, "/")}", diff: true)]

  defp sum(files, key), do: files |> Enum.map(& &1[key]) |> Enum.sum()

  defp n_files(1), do: "1 file"
  defp n_files(n), do: "#{n} files"

  defp n_commands(1), do: "1 command"
  defp n_commands(n), do: "#{n} commands"
end
