defmodule Mix.Tasks.Troupe.Prefix do
  @shortdoc "Count how often sessions' prompts changed in front of what they had sent"

  @moduledoc """
  Issue #465's counter (`Troupe.Bench.Prefix`, Decision 815) over session logs.

      mix troupe.prefix
      mix troupe.prefix PATH...
      mix troupe.prefix --json PATH...

  Each `PATH` is a session's `events.jsonl` or a directory searched for them, such as a
  state directory or a live bench's `--keep` directory; with none, the state directory
  `TROUPE_STATE_HOME` (or the platform's) names. For each session and in all: the model
  calls, those whose system prompt and whose tools changed since their agent's call
  before, those sent again without their thinking after Anthropic refused it as bound to
  another conversation, the thinking blocks the thinking-binding beta dropped, and the
  calls that sent a stable system prompt's turn context. A log written before the counts
  were has its changes judged by `prompt_bytes`, and says how many.

  It reads the logs and nothing else: no session is started, no model called.
  """

  use Mix.Task

  alias Troupe.Bench.Prefix
  alias Troupe.Session.Log

  @requirements ["app.config"]

  @measures [
    {"model_calls", "model calls"},
    {"system_changes", "system prompt changed"},
    {"tools_changes", "tools changed"},
    {"inferred", "changes judged by size"},
    {"thinking_resent", "sent again without thinking"},
    {"thinking_dropped", "thinking blocks dropped"},
    {"calls_dropping", "calls that dropped any"},
    {"turn_contexts", "turn contexts sent"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, paths, _invalid} = OptionParser.parse(argv, strict: [json: :boolean])
    paths = if paths == [], do: [Path.join(Troupe.Paths.state_dir(nil), "sessions")], else: paths

    sessions =
      paths
      |> Enum.flat_map(&logs/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, &1 |> Log.read_file() |> Prefix.count()})

    total =
      Enum.reduce(sessions, Prefix.zero(), fn {_path, count}, acc -> Prefix.add(acc, count) end)

    if opts[:json] do
      IO.puts(
        Jason.encode!(
          %{
            "sessions" =>
              Enum.map(sessions, fn {path, count} -> Map.put(count, "path", path) end),
            "total" => Map.put(total, "sessions", length(sessions))
          },
          pretty: true
        )
      )
    else
      IO.write(table(sessions, total))
    end
  end

  defp logs(path) do
    cond do
      File.regular?(path) -> [Path.expand(path)]
      File.dir?(path) -> path |> Path.expand() |> Path.join("**/events.jsonl") |> Path.wildcard()
      true -> Mix.raise("#{path} is neither a session log nor a directory")
    end
  end

  defp table(sessions, total) do
    header = "| session | " <> Enum.map_join(@measures, " | ", &elem(&1, 1)) <> " |\n"
    rule = "| --- |" <> String.duplicate(" ---: |", length(@measures)) <> "\n"

    rows =
      Enum.map(sessions, fn {path, count} -> row(session_name(path), count) end) ++
        [row("all #{length(sessions)}", total)]

    header <> rule <> Enum.join(rows)
  end

  defp row(name, count),
    do:
      "| #{name} | " <> Enum.map_join(@measures, " | ", &to_string(count[elem(&1, 0)])) <> " |\n"

  # A session's id is the name of the directory its log is in.
  defp session_name(path), do: path |> Path.dirname() |> Path.basename()
end
