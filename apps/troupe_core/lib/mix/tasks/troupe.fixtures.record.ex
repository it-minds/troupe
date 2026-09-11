defmodule Mix.Tasks.Troupe.Fixtures.Record do
  @shortdoc "Record a release's log fixtures and their fold hashes"

  @moduledoc """
  Freeze the current release's log shape, so later builds can prove they still read it.

      mix troupe.fixtures.record 0.2.0

  Writes `test/fixtures/logs/<version>/`: one JSONL log per scenario, and a `hashes.json`
  naming the fold each one produces. From then on CI replays every fixture of every
  version and compares.

  Run this **once per release**, and never again for a version already recorded. A
  recorded hash is a claim about what a released Troupe produced; editing one because the
  code changed is deleting the evidence rather than fixing the problem — if a fold has to
  change meaning, that is a new version with new fixtures alongside the old ones, and the
  old ones keep passing through the upcaster.
  """

  use Mix.Task

  alias Troupe.Log.Fold
  alias Troupe.Protocol.Event

  @impl Mix.Task
  def run(argv) do
    version = List.first(argv) || current_version()
    directory = Path.join(root(), version)

    if File.dir?(directory) do
      Mix.raise("""
      #{directory} already exists.

      A recorded fixture is evidence of what a released Troupe produced. If the fold has
      to change meaning, record a new version beside it rather than overwriting this one.
      """)
    end

    File.mkdir_p!(directory)

    hashes =
      scenarios()
      |> Enum.map(fn {name, events} ->
        sealed = seal(events)
        File.write!(Path.join(directory, "#{name}.jsonl"), render(sealed))
        {name, Fold.hash(sealed)}
      end)
      |> Map.new()

    File.write!(
      Path.join(directory, "hashes.json"),
      Jason.encode!(%{"version" => version, "folds" => hashes}, pretty: true) <> "\n"
    )

    Mix.shell().info("recorded #{map_size(hashes)} fixture(s) for #{version} in #{directory}")
  end

  @doc "Where fixtures live."
  @spec root() :: Path.t()
  def root, do: Path.join([File.cwd!(), "test", "fixtures", "logs"])

  @doc """
  The scenarios every version records.

  Chosen to cover the fold rather than to look like real sessions: each one exercises a
  branch that a later build could break without any other test noticing.
  """
  @spec scenarios() :: [{String.t(), [map()]}]
  def scenarios do
    [
      {"simple_turn", simple_turn()},
      {"tool_use", tool_use()},
      {"approval", approval()},
      {"subagents", subagents()},
      {"error_and_recovery", error_and_recovery()}
    ]
  end

  defp simple_turn do
    [
      {:session_created, ["root"], %{"workspace" => "/w", "profile" => "build", "visibility" => "private"}},
      {:agent_started, ["root"], %{"profile" => "build", "mode" => "primary"}},
      {:user_input, ["root"], %{"source" => "user", "text" => "hello"}},
      {:llm_request, ["root"], %{"model" => "m", "message_count" => 1, "tools" => [], "profile" => "build"}},
      {:llm_response, ["root"],
       %{
         "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hi"}]},
         "usage" => %{"input_tokens" => 10, "output_tokens" => 2},
         "stop_reason" => "end_turn"
       }}
    ]
  end

  defp tool_use do
    simple_turn() ++
      [
        {:tool_call_started, ["root"], %{"call_id" => "c1", "name" => "read_file", "args" => %{"path" => "a.ex"}}},
        {:tool_call_completed, ["root"], %{"call_id" => "c1", "name" => "read_file", "ok" => true, "content" => "defmodule A"}},
        {:tool_results, ["root"], %{"results" => []}},
        {:todo_updated, ["root"],
         %{"items" => [%{"id" => "a", "content" => "read it", "status" => "in_progress"}], "source" => "agent"}}
      ]
  end

  defp approval do
    simple_turn() ++
      [
        {:approval_requested, ["root"],
         %{"call_id" => "c2", "tool" => "shell", "args" => %{"command" => "ls"}, "agent_path" => ["root"]}},
        {:approval_decided, ["root"],
         %{
           "call_id" => "c2",
           "tool" => "shell",
           "args" => %{"command" => "ls"},
           "agent_path" => ["root"],
           "decision" => "allow"
         }},
        {:tool_call_completed, ["root"], %{"call_id" => "c2", "name" => "shell", "ok" => true, "content" => "a.ex"}}
      ]
  end

  defp subagents do
    simple_turn() ++
      [
        {:delegation_started, ["root"],
         %{"call_id" => "c3", "agent" => "explore", "child_path" => ["root", "explore"], "task" => "look"}},
        {:agent_started, ["root", "explore"], %{"profile" => "explore", "mode" => "subagent"}},
        {:user_input, ["root", "explore"], %{"source" => "user", "text" => "look"}},
        {:agent_done, ["root", "explore"], %{"reason" => "finished", "summary" => "found it"}},
        {:tool_call_completed, ["root"], %{"call_id" => "c3", "name" => "delegate", "ok" => true, "content" => "found it"}}
      ]
  end

  defp error_and_recovery do
    simple_turn() ++
      [
        {:llm_error, ["root"], %{"reason" => "the provider hung up"}},
        {:agent_restarted, ["root"], %{"replayed_events" => 5, "interrupted" => true, "incomplete_calls" => []}},
        {:user_input, ["root"], %{"source" => "user", "text" => "try again"}},
        {:llm_response, ["root"],
         %{
           "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "done"}]},
           "usage" => %{"input_tokens" => 20, "output_tokens" => 3},
           "stop_reason" => "end_turn"
         }},
        {:session_dormant, ["root"], %{"last_seq" => 9}}
      ]
  end

  # Sealed with a fixed timestamp, so recording the same scenario twice produces the
  # same bytes — a fixture whose hash moved because it was written on a Tuesday would be
  # worthless.
  defp seal(events) do
    {sealed, _previous} =
      events
      |> Enum.with_index(1)
      |> Enum.map_reduce(nil, fn {{type, agent, data}, seq}, previous ->
        event =
          %Event{type: to_string(type), agent: agent, data: data, actor: Event.Actor.system()}
          |> Event.seal(seq, previous, "2026-01-01T00:00:00.000000Z")

        {event, event}
      end)

    sealed
  end

  defp render(events) do
    Enum.map_join(events, "", &(Jason.encode!(Event.to_json(&1)) <> "\n"))
  end

  defp current_version do
    case :application.get_key(:troupe_core, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
