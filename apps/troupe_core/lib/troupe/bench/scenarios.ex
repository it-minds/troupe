defmodule Troupe.Bench.Scenarios do
  @moduledoc """
  The offline suite `troupe bench` runs (Decision 772), in the order the report lists it.

  Each scenario is about the harness's shape, not about what a model says: how many calls
  a turn makes and what each one sends, what happens to a tool result too big to send,
  when compaction comes, what a cancel leaves behind, and whether the log is the session.
  Then one for each other tool whose files `troupe onboard` brings in, onboarded first,
  whose task holds only when the instructions reached the prompt
  (`Troupe.Bench.Onboarding`, Decision 834). The numbers each is held to are in
  `priv/bench/budgets.json`.
  """

  alias Troupe.Bench.{Model, Onboarding, Runner, Scenario}
  alias Troupe.LLM.Message
  alias Troupe.Log.Fold
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log

  @doc "Every scenario, in report order."
  @spec all() :: [Scenario.t()]
  def all, do: [tool_calls(), cut_output(), compaction(), cancel(), replay()] ++ Onboarding.all()

  # -- a turn of thirty tool calls --------------------------------------------------

  @notes 30

  # #389's turn: one input, many calls, each resending everything before it. What a
  # change to the system prompt, the tool definitions or what a tool result carries does
  # to every call of such a turn shows up here first.
  defp tool_calls do
    %Scenario{
      name: "tool_calls",
      title: "one turn of #{@notes} tool calls",
      prompt: "Read each file in notes/ with read_file, one at a time, then say that you have.",
      files: Map.new(1..@notes, &{"notes/#{pad(&1)}.txt", note(&1)}),
      script:
        Enum.map(1..@notes, &{:tools, [{"read_file", %{"path" => "notes/#{pad(&1)}.txt"}}]}) ++
          [{:text, "I have read all #{@notes} notes."}],
      measure: &measure_tool_calls/1
    }
  end

  defp measure_tool_calls(ctx) do
    [first | _] = calls = agent_calls(ctx)
    last = List.last(calls)
    largest = calls |> Enum.map(& &1.total) |> Enum.max()

    {[
       {"model_calls", "model calls in the turn", "calls", length(ctx.calls)},
       {"system_prompt_bytes", "system prompt", "bytes", first.system},
       {"tool_definition_bytes", "tool definitions", "bytes", first.tools},
       {"first_prompt_bytes", "first prompt", "bytes", first.total},
       {"largest_prompt_bytes", "largest prompt", "bytes", largest},
       {"growth_per_call_bytes", "growth per tool round trip", "bytes",
        div(last.total - first.total, max(length(calls) - 1, 1))},
       {"turn_input_tokens", "input tokens over the turn", "tokens",
        ctx.calls |> Enum.map(& &1.input_tokens) |> Enum.sum()},
       {"events_per_turn", "events the turn logged", "events",
        ctx.events |> Enum.drop_while(&(&1.type != "user_input")) |> length()}
     ],
     [
       {"ended", "the turn ended with the answer", ended?(ctx)},
       {"no_failures", "every tool call succeeded", failures(ctx) == 0}
     ]}
  end

  # -- a tool result over the limit --------------------------------------------------

  @matches 200

  # Every line of `big.log` matches, so `grep` returns as many lines as it ever does, and
  # longer than `tool_output_limit`'s default: the result is cut, its whole kept, and the
  # marker names the `read_output` call that pages the rest back, which the model makes.
  defp cut_output do
    line = fn n -> "entry #{n}: match " <> String.duplicate("x", 380) end

    %Scenario{
      name: "cut_output",
      title: "a tool result over the limit is cut and read back",
      prompt: "Find the lines of big.log that say match, and read whatever the search left out.",
      files: %{"big.log" => Enum.map_join(1..@matches, "\n", line) <> "\n"},
      script: [
        {:tools, [{"grep", %{"pattern" => "match"}}]},
        &read_rest/1,
        {:text, "That is all of it."}
      ],
      measure: &measure_cut_output/1
    }
  end

  @marker ~r/read_output\(id: "(sha256:[0-9a-f]{64})", offset: (\d+)/

  defp read_rest(request) do
    case Regex.run(@marker, Model.last_tool_result(request) || "") do
      [_, id, offset] ->
        {:tools, [{"read_output", %{"id" => id, "offset" => String.to_integer(offset)}}]}

      nil ->
        {:text, "Nothing was left out."}
    end
  end

  defp measure_cut_output(ctx) do
    results =
      Enum.map(ctx.requests, fn {request, _task, _usage} -> Model.last_tool_result(request) end)

    cut = Enum.at(results, 1) || ""
    page = Enum.at(results, 2) || ""
    last_line = "big.log:#{@matches}:"

    {[
       {"model_calls", "model calls in the turn", "calls", length(ctx.calls)},
       {"cut_result_bytes", "the cut result, as the next prompt carries it", "bytes",
        byte_size(cut)}
     ],
     [
       {"cut", "the result was cut and names read_output",
        Regex.match?(@marker, cut) and not String.contains?(cut, last_line)},
       {"read_back", "read_output returned what was left out",
        completed?(ctx, "read_output") and String.contains?(page, last_line)}
     ]}
  end

  # -- compaction ------------------------------------------------------------------

  @chapters 12

  # A window small enough that a dozen reads of four kilobytes cross `compact_at`'s
  # default share of it. The model counts four bytes to the token, so the threshold is
  # crossed by the prompt's real size, as it would be against a model.
  defp compaction do
    %Scenario{
      name: "compaction",
      title: "compaction fires at the configured share of the window",
      prompt: "Read the chapters in chapters/ in order with read_file, then say that you have.",
      files: Map.new(1..@chapters, &{"chapters/#{pad(&1)}.txt", chapter(&1)}),
      config: [context_window: 16_000],
      script:
        Enum.map(1..@chapters, &{:tools, [{"read_file", %{"path" => "chapters/#{pad(&1)}.txt"}}]}) ++
          [{:text, "I have read every chapter."}],
      measure: &measure_compaction/1
    }
  end

  defp measure_compaction(ctx) do
    threshold = Troupe.Config.compact_threshold(ctx.config)
    window = Troupe.Config.context_window(ctx.config, ctx.config.model)

    # Each summariser call with the call whose answer started it and the call after it,
    # which carries the compacted conversation (`nil` when the turn had ended).
    triples =
      (ctx.calls ++ [nil])
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.filter(fn [before, call, _next] -> call.summariser and not before.summariser end)

    triggers = Enum.map(triples, fn [before, _summariser, _next] -> before end)
    agent = agent_calls(ctx)

    after_share =
      case triples do
        [[trigger, _summariser, %{summariser: false} = next] | _] ->
          Float.round(next.total / trigger.total, 3)

        _none ->
          0.0
      end

    {[
       {"compactions", "compactions in the turn", "compactions", length(triggers)},
       {"fired_at_share", "fullest prompt before compaction, of the window", "share",
        triggers |> Enum.map(&Float.round(&1.input_tokens / window, 3)) |> Enum.max(fn -> 0.0 end)},
       {"largest_prompt_tokens", "largest prompt", "tokens",
        agent |> Enum.map(& &1.input_tokens) |> Enum.max()},
       {"after_compaction_share", "first prompt after compaction, of the one before", "share",
        after_share}
     ],
     [
       {"compacted", "compaction happened", triggers != []},
       {"not_early", "never before the threshold",
        Enum.all?(triggers, &(&1.input_tokens >= threshold))},
       {"not_late", "every prompt over the threshold was followed by one",
        crossings(ctx.calls, threshold) == length(triggers)},
       {"ended", "the turn ended with the answer", ended?(ctx)}
     ]}
  end

  # Agent calls at or over the threshold: each should have been the last before a summary.
  defp crossings(calls, threshold) do
    Enum.count(calls, &(not &1.summariser and &1.input_tokens >= threshold))
  end

  # -- cancel ----------------------------------------------------------------------

  # The model takes a minute over its second answer; the person cancels while it does.
  # The call's task has to go, no answer may arrive for it afterwards, and the session has
  # to take the next input as if nothing had happened.
  defp cancel do
    %Scenario{
      name: "cancel",
      title: "a cancelled turn leaves nothing running",
      prompt: "Read a.txt, then tell me what it says.",
      files: %{"a.txt" => "alpha\n"},
      script: [
        {:tools, [{"read_file", %{"path" => "a.txt"}}]},
        {:delay, 60_000, {:text, "This answer comes too late."}},
        {:text, "Still here."}
      ],
      drive: &drive_cancel/1,
      measure: &measure_cancel/1
    }
  end

  defp drive_cancel(ctx) do
    :ok = Troupe.send_input(ctx.session_id, ctx.scenario.prompt)

    task =
      receive do
        {:bench_request, _model, 2, task} -> task
      after
        60_000 -> raise "the second model call never came"
      end

    ref = Process.monitor(task)
    :ok = Troupe.cancel(ctx.session_id)
    Runner.await(ctx, "cancelled")

    left =
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> 0
      after
        5_000 -> 1
      end

    calls = length(Model.requests(ctx.model))
    rested = Troupe.snapshot(ctx.session_id).state == :idle

    :ok = Troupe.send_input(ctx.session_id, "Are you still there?")
    Runner.await(ctx, "turn_ended")

    %{ctx | marks: %{left: left, after_cancel: calls - 2, rested: rested}}
  end

  defp measure_cancel(ctx) do
    {[
       {"calls_after_cancel", "model calls made after the cancel", "calls",
        ctx.marks.after_cancel},
       {"tasks_left_running", "cancelled model calls still running", "tasks", ctx.marks.left}
     ],
     [
       {"cancelled", "the cancel is in the log",
        Enum.count(ctx.events, &(&1.type == "cancelled")) == 1},
       {"rested", "the agent rested", ctx.marks.rested},
       {"answers_again", "the next input was answered", last_answer(ctx) == "Still here."}
     ]}
  end

  # -- the log is the session -------------------------------------------------------

  @greeting "hello from the bench\n"

  # A short turn that writes a file. Then the log is read three ways, which have to agree
  # (the running session's, the file's, a client's from the start), its hashes have to
  # chain, and the session, stopped and resumed, has to come back with the conversation
  # it had.
  defp replay do
    %Scenario{
      name: "replay",
      title: "the log replays to the session it recorded",
      prompt: "Write hello.txt containing the line: hello from the bench",
      files: %{"src/greeting.txt" => "hello\n"},
      outcome: {:file, "hello.txt", @greeting},
      script: [
        {:tools, [{"list_files", %{}}]},
        {:tools, [{"write_file", %{"path" => "hello.txt", "content" => @greeting}}]},
        {:tools, [{"read_file", %{"path" => "hello.txt"}}]},
        {:text, "hello.txt is written."}
      ],
      drive: &drive_replay/1,
      measure: &measure_replay/1
    }
  end

  defp drive_replay(ctx) do
    ctx = Runner.type_and_wait(ctx)
    sid = ctx.session_id

    live = Fold.hash(Troupe.events(sid))
    path = Log.path(sid)
    {:ok, _folded, disk} = Fold.file(path)

    on_disk =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))

    seqs = sid |> Troupe.replay_from(0) |> Enum.map(& &1.seq)
    before = conversation(sid)

    :ok = Troupe.stop_session(sid)

    {:ok, _session} =
      Troupe.resume(sid,
        workspace: ctx.workspace,
        fake: ctx.model,
        config_overrides: ctx.overrides
      )

    marks = %{
      same_fold: live == disk,
      chained: chained?(on_disk),
      once: seqs == Enum.to_list(1..length(seqs)//1),
      resumed: conversation(sid) == before,
      messages: length(before)
    }

    %{ctx | marks: marks}
  end

  defp measure_replay(ctx) do
    {[
       {"conversation_messages", "messages the resumed agent rebuilt", "messages",
        ctx.marks.messages}
     ],
     [
       {"same_fold", "the file folds as the running log does", ctx.marks.same_fold},
       {"chained", "every event names the hash of the one before", ctx.marks.chained},
       {"once", "a client replaying from the start sees each event once", ctx.marks.once},
       {"resumed", "the resumed agent has the conversation it had", ctx.marks.resumed}
     ]}
  end

  defp conversation(sid), do: Troupe.snapshot(sid).conversation |> Enum.map(&Message.to_json/1)

  defp chained?([first | rest]) do
    first.prev_hash == nil and
      rest
      |> Enum.zip([first | rest])
      |> Enum.all?(fn {event, previous} -> event.prev_hash == Event.hash(previous) end)
  end

  defp chained?([]), do: false

  # -- shared ------------------------------------------------------------------------

  defp agent_calls(ctx), do: Enum.reject(ctx.calls, & &1.summariser)

  defp ended?(ctx) do
    Enum.any?(ctx.events, &(&1.type == "turn_ended" and &1.agent == ["root"])) and
      ctx |> Runner.record() |> Map.get("stop_reason") == "end_turn"
  end

  defp failures(ctx) do
    Enum.count(ctx.events, &(&1.type == "tool_call_completed" and &1.data["ok"] == false))
  end

  defp completed?(ctx, name) do
    Enum.any?(
      ctx.events,
      &(&1.type == "tool_call_completed" and &1.data["name"] == name and &1.data["ok"] == true)
    )
  end

  defp last_answer(ctx) do
    ctx.events
    |> Enum.filter(&(&1.type == "llm_response" and &1.agent == ["root"]))
    |> List.last()
    |> case do
      nil -> nil
      event -> event.data["message"] |> Message.from_json() |> Message.text()
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp note(n) do
    Enum.map_join(1..4, "", fn line ->
      "Note #{n}, line #{line}: the harbour opens at six and closes at dusk.\n"
    end)
  end

  defp chapter(n) do
    Enum.map_join(1..40, "", fn line ->
      String.pad_trailing(
        "Chapter #{n}, line #{line}: the keeper trims the wick and climbs the stair.",
        99
      ) <> "\n"
    end)
  end
end
