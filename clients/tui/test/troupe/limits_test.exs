defmodule Troupe.LimitsTest do
  @moduledoc """
  Every way a turn can stop that is not the agent choosing to finish: the four
  Troupe budgets, the model's context window, the output cap and a refusal.

  The shape each of these has to have is the one `Troupe.Tool.Bound` already has
  (Decision 85): never silently lose work, and always hand back the call that
  recovers it.
  """

  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Agent.{Budget, Headroom}
  alias Troupe.LLM.{Fake, Message, Provider}

  # A response in the shape a real adapter produces on a warm conversation: the
  # prompt cache carries the whole prompt and `input_tokens` is nearly nothing.
  defp event(type, data, ts),
    do: %Troupe.Event{session_id: "s", agent_path: "code-1", type: type, data: data, ts: ts}

  defp cached_tool(name, input, cache_read) do
    %{
      content: [Message.tool_use("call_#{System.unique_integer([:positive])}", name, input)],
      usage: %{input_tokens: 40, output_tokens: 20, cache_read: cache_read, cache_write: 0},
      stop_reason: :tool_use
    }
  end

  describe "compaction against the whole prompt" do
    # The regression the suite was missing. `compaction_needed?/2` measured
    # `input_tokens`, which Anthropic reports *excluding* the cache figures — so
    # once Decision 84 put breakpoints on every request a 200k conversation
    # reported a few hundred and compaction never fired in production. The Fake
    # hardcoded `cache_read: 0`, so the old test passed against a shape the real
    # adapter no longer produces.
    test "a prompt the provider served from cache still crosses the compaction threshold" do
      ws = tmp_workspace(%{"f.txt" => "x"})

      script =
        List.duplicate(cached_tool("read_file", %{"path" => "f.txt"}, 1_400), 6) ++
          [{:finish, "done"}]

      {sid, fake, _} =
        start_session!(
          workspace: ws,
          script: script,
          config: %{default_window: 1_500, compaction: %{fraction: 0.5, keep_last_turns: 1}}
        )

      {:ok, path} = Troupe.dispatch(sid, "code", "read it a few times")
      await_state(path, :done_unread, 15_000)

      assert events_of(sid, path, :compaction) != []
      assert Enum.any?(Fake.requests(fake), &(&1.purpose == :compaction))
    end

    test "a prompt the provider did not cache and that fits does not compact" do
      ws = tmp_workspace(%{"f.txt" => "x"})
      script = [cached_tool("read_file", %{"path" => "f.txt"}, 0), {:finish, "done"}]

      {sid, _fake, _} =
        start_session!(
          workspace: ws,
          script: script,
          config: %{default_window: 1_500, compaction: %{fraction: 0.5, keep_last_turns: 1}}
        )

      {:ok, path} = Troupe.dispatch(sid, "code", "read it once")
      await_state(path, :done_unread, 15_000)
      assert events_of(sid, path, :compaction) == []
    end
  end

  describe "context overflow" do
    # The wedge that used to lose a multi-million-token branch: the provider
    # answers 400, the branch goes `failed_unread`, and the only recovery the UI
    # offered was typing more input — which rebuilds the same oversized prompt.
    test "a context-overflow 400 compacts once and re-sends the turn instead of failing" do
      ws = tmp_workspace(%{"f.txt" => "x"})

      script =
        List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 5) ++
          [
            {:error, {:http, 400, "prompt is too long: 250000 tokens > 200000 maximum"}},
            {:finish, "recovered"}
          ]

      {sid, _fake, _} =
        start_session!(
          workspace: ws,
          script: script,
          config: %{compaction: %{keep_last_turns: 1}}
        )

      {:ok, path} = Troupe.dispatch(sid, "code", "go")
      await_state(path, :done_unread, 15_000)

      assert [%{data: %{reason: :context_overflow}}] = events_of(sid, path, :compaction_started)
      assert length(events_of(sid, path, :compaction)) == 1
      assert events_of(sid, path, :llm_error) == []
      assert window(sid, path).reason == :finished
    end

    # Compacting twice over the same wall is a loop, so the second time it fails
    # — but with a line that says what to do rather than the provider's raw 400.
    test "a branch that overflows again after compacting fails with an actionable message" do
      ws = tmp_workspace(%{"f.txt" => "x"})
      overflow = {:error, {:http, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

      script =
        List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 5) ++ [overflow, overflow]

      {sid, _fake, _} =
        start_session!(workspace: ws, script: script, config: %{compaction: %{keep_last_turns: 1}})

      {:ok, path} = Troupe.dispatch(sid, "code", "go")
      await_state(path, :done_unread, 15_000)

      assert [%{data: %{message: message}}] = events_of(sid, path, :llm_error)
      assert message =~ "no longer fits the model's context window"
      assert message =~ "compaction.fraction"
      assert window(sid, path).reason == :llm_error
    end

    test "a branch too short to compact says so rather than compacting nothing" do
      ws = tmp_workspace(%{"f.txt" => "x"})

      {sid, _fake, _} =
        start_session!(
          workspace: ws,
          script: [{:error, {:http, 400, "prompt is too long"}}],
          config: %{compaction: %{keep_last_turns: 4}}
        )

      {:ok, path} = Troupe.dispatch(sid, "code", "go")
      await_state(path, :done_unread, 15_000)

      assert events_of(sid, path, :compaction) == []
      assert [%{data: %{message: message}}] = events_of(sid, path, :llm_error)
      assert message =~ "too few messages to compact"
    end

    test "/compact summarizes a resting branch on demand" do
      ws = tmp_workspace(%{"f.txt" => "x"})

      script =
        List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 4) ++ [{:finish, "done"}]

      {sid, _fake, _} =
        start_session!(workspace: ws, script: script, config: %{compaction: %{keep_last_turns: 1}})

      {:ok, path} = Troupe.dispatch(sid, "code", "go")
      await_state(path, :done_unread, 15_000)

      :ok = Troupe.Client.compact(sid, path)
      assert_receive {:troupe_event, %{type: :compaction, agent_path: ^path}}, 10_000
      assert [%{data: %{reason: :requested}}] = events_of(sid, path, :compaction_started)

      # Compacting a branch that has come to rest leaves it at rest.
      assert window(sid, path).state == :done_unread
    end
  end

  describe "the output cap" do
    # `stop_reason: :max_tokens` was parsed, logged and read by nothing, so a
    # reply cut in half — or one where thinking ate the whole allowance and left
    # `content: []` — reported the branch as finished with a half sentence.
    test "a reply cut off with no tool call is retried once and then fails visibly" do
      ws = tmp_workspace()
      truncated = %{content: [], usage: Provider.empty_usage(), stop_reason: :max_tokens}

      {sid, _fake, _} = start_session!(workspace: ws, script: [truncated, truncated])

      {:ok, path} = Troupe.dispatch(sid, "code", "write me something long")
      await_state(path, :done_unread, 15_000)

      assert window(sid, path).reason == :output_truncated
      assert [first, second] = events_of(sid, path, :truncated)
      assert first.data.note =~ "output token cap"
      assert second.data.final == true
      assert window(sid, path).summary =~ "output token cap"
    end

    test "the retry carries a note telling the model to answer in smaller steps" do
      ws = tmp_workspace()
      truncated = %{content: [], usage: Provider.empty_usage(), stop_reason: :max_tokens}

      {sid, fake, _} = start_session!(workspace: ws, script: [truncated, {:finish, "smaller"}])

      {:ok, path} = Troupe.dispatch(sid, "code", "write me something long")
      await_state(path, :done_unread, 15_000)

      assert window(sid, path).reason == :finished

      retry = fake |> Fake.requests() |> Enum.filter(&(&1.purpose == :turn)) |> List.last()
      text = retry.messages |> List.last() |> Map.get(:content) |> Message.text()
      assert text =~ "cut off because it reached the output token cap"
    end

    # A `tool_use` whose arguments were cut off mid-JSON reaches the agent as
    # `%{"_raw" => "{\"path\": \"li"}`. Running a tool on a fragment is worse than
    # saying so — and every `tool_use` still owes a `tool_result`, or the next
    # request is rejected outright.
    test "a tool call cut off mid-argument is answered with an error, not run" do
      ws = tmp_workspace(%{"f.txt" => "x"})

      cut_off = %{
        content: [Message.tool_use("call_cut", "read_file", %{"_raw" => "{\"path\": \"f.t"})],
        usage: Provider.empty_usage(),
        stop_reason: :max_tokens
      }

      {sid, _fake, _} = start_session!(workspace: ws, script: [cut_off, {:finish, "done"}])

      {:ok, path} = Troupe.dispatch(sid, "code", "read it")
      await_state(path, :done_unread, 15_000)

      assert [%{data: %{ok: false, content: content}} | _] =
               events_of(sid, path, :tool_call_completed)

      assert content =~ "cut off mid-argument"
      assert [%{data: %{calls: 1}}] = events_of(sid, path, :truncated)
      assert window(sid, path).reason == :finished
    end

    test "a refusal ends the branch as :refused, not as a successful finish" do
      ws = tmp_workspace()

      refusal = %{
        content: [Message.text_block("I can't help with that.")],
        usage: Provider.empty_usage(),
        stop_reason: :refusal
      }

      {sid, _fake, _} = start_session!(workspace: ws, script: [refusal])

      {:ok, path} = Troupe.dispatch(sid, "code", "do the thing")
      await_state(path, :done_unread, 15_000)

      assert window(sid, path).reason == :refused
      assert window(sid, path).summary =~ "refused"
    end
  end

  describe "warnings before the wall" do
    # The signal that arrives while there is still budget left to spend. Before
    # this there was no denominator anywhere in the UI: the first thing a user
    # saw was either the budget question at 100% or a red llm_error after the fact.
    test "each dimension warns once per slice, not once per turn" do
      ws = tmp_workspace(%{"f.txt" => "x"})
      script = List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 10)

      {sid, _fake, _} =
        start_session!(workspace: ws, script: script, config: %{budget: %{warn_at: 0.5}})

      {:ok, path} = Troupe.dispatch(sid, "code", %{prompt: "loop", budget: %{max_turns: 4}})

      ask = await_event(path, :budget_ask_started, 15_000)

      warnings = events_of(sid, path, :budget_warning)
      turns = Enum.filter(warnings, &(&1.data.dimension == :turns))

      assert length(turns) == 1, "one warning per dimension, not one per turn"
      assert hd(turns).data.fraction >= 0.5
      assert hd(turns).data.detail =~ "turns"

      # A fresh slice is a fresh warning: `y` clears what has been warned about.
      :ok = Troupe.approve(sid, ask.data.call_id, :allow)
      await_event(path, :budget_ask_started, 15_000)

      assert length(
               Enum.filter(events_of(sid, path, :budget_warning), &(&1.data.dimension == :turns))
             ) ==
               2
    end
  end

  describe "Headroom" do
    test "reports every dimension and names the tightest" do
      budget = %Budget{
        max_turns: 10,
        max_input_tokens: 1_000,
        max_output_tokens: 1_000,
        max_wall_clock_ms: 10_000
      }

      usage = %{turns: 5, input_tokens: 900, output_tokens: 100}
      h = Headroom.of(budget, usage, 1_000, 50_000, 200_000)

      assert h.turns.fraction == 0.5
      assert h.input.fraction == 0.9
      assert h.wall.fraction == 0.1
      assert h.context.fraction == 0.25
      assert {:input, %{used: 900, limit: 1_000}} = Headroom.tightest(h)
      assert Headroom.describe(:input, h.input) == "input tokens 900/1.0k (90%)"
    end

    test "crossed/3 skips what has already been warned about, tightest first" do
      budget = %Budget{
        max_turns: 10,
        max_input_tokens: 1_000,
        max_output_tokens: 1_000,
        max_wall_clock_ms: 10_000
      }

      h = Headroom.of(budget, %{turns: 9, input_tokens: 950, output_tokens: 0}, 0, 0, 200_000)

      assert [{:input, _}, {:turns, _}] = Headroom.crossed(h, 0.8, [])
      assert [{:turns, _}] = Headroom.crossed(h, 0.8, [:input])
      assert Headroom.crossed(h, 0.8, [:input, :turns]) == []
    end

    test "a zero prompt reads as an empty context, not a full one" do
      h = Headroom.of(%Budget{}, Budget.empty_usage(), 0, 0, 200_000)
      assert h.context.fraction == 0.0
    end
  end

  describe "Budget grants" do
    test "a slice is the budget's own size again, and grants accumulate" do
      budget = %Budget{max_turns: 10, max_input_tokens: 100, max_output_tokens: 50}
      slice = Budget.slice(budget)

      assert slice.turns == 10
      assert Budget.with_grant(budget, slice).max_turns == 20

      assert budget |> Budget.with_grant(Budget.add_grant(slice, slice)) |> Map.get(:max_turns) ==
               30
    end

    test "exhausted_dimension names which ceiling tripped" do
      budget = %Budget{max_turns: 2, max_input_tokens: 100, max_output_tokens: 100}

      assert Budget.exhausted_dimension(budget, %{turns: 2, input_tokens: 0, output_tokens: 0}, 0) ==
               :turns

      assert Budget.exhausted_dimension(budget, %{turns: 0, input_tokens: 100, output_tokens: 0}, 0) ==
               :input

      assert Budget.exhausted_dimension(budget, %{turns: 0, input_tokens: 0, output_tokens: 0}, 0) ==
               nil
    end
  end

  describe "provider error classification" do
    # A typo in a model name and a blown context window used to be the same
    # opaque `llm_error` on screen.
    test "a 400 naming a context error is an overflow; every other 400 is not" do
      assert {:context_overflow, _} =
               Provider.classify({:http, 400, "prompt is too long: 250000 tokens"})

      assert {:context_overflow, _} =
               Provider.classify({:http, 400, "This model's maximum context length is 128000"})

      assert {:http, 400, _} = Provider.classify({:http, 400, "invalid_request: bad tool schema"})
    end

    test "auth, unknown model and rate limits are told apart" do
      assert {:auth, _} = Provider.classify({:http, 401, "invalid x-api-key"})
      assert {:model_not_found, _} = Provider.classify({:http, 404, "model: not_a_model"})
      assert {:rate_limited, _} = Provider.classify({:http, 429, "slow down"})
    end

    test "an overflow that exhausted its retries is still an overflow" do
      assert {:context_overflow, _} =
               Provider.classify({:retries_exhausted, {:http, 400, "prompt is too long"}})
    end

    test "describe_error says what happened in words a user can act on" do
      assert Provider.describe_error({:http, 404, "no such model"}) =~ "does not know that model"
      assert Provider.describe_error({:http, 401, ""}) =~ "rejected the credentials"
    end
  end

  describe "the wall clock" do
    # `elapsed_ms` used to run from the agent's first event, so a session resumed
    # the next day had already blown its three-hour budget and the first thing
    # the branch did was ask the budget question.
    test "a gap longer than a stream's lifetime is not counted as work" do
      now = System.system_time(:millisecond)

      events = [
        event(:input, %{content: "go"}, now - 86_400_000),
        event(:todo_updated, %{items: []}, now - 86_400_000 + 5_000),
        event(:todo_updated, %{items: []}, now)
      ]

      state = Enum.reduce(events, %Troupe.Agent.State{}, &Troupe.Agent.State.apply(&2, &1))

      # Five seconds of work, then a day of nothing.
      assert state.work_ms == 5_000
      assert Troupe.Agent.State.elapsed_ms(state) < 60_000
    end
  end

  describe "full send" do
    # `--full-send` lifts every budget for the whole session: the budget question
    # that an exhausted branch would otherwise ask never appears, and neither do
    # the warnings leading up to it. This is the same override `a` (allow_session)
    # sets mid-run, seeded at session start so a full-send run never asks.
    test "an exhausted budget is not asked about and no warnings are logged" do
      ws = tmp_workspace(%{"f.txt" => "x"})
      script = List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 5) ++ [{:finish, "done"}]

      {sid, _fake, _} = start_session!(workspace: ws, script: script, full_send: true)

      {:ok, path} =
        Troupe.dispatch(sid, "code", %{prompt: "loop", budget: %{max_turns: 1}})

      await_state(path, :done_unread, 15_000)

      assert window(sid, path).reason == :finished
      assert events_of(sid, path, :budget_ask_started) == []
      assert events_of(sid, path, :budget_warning) == []
    end

    test "without full send an exhausted budget asks, as it does without the flag" do
      ws = tmp_workspace(%{"f.txt" => "x"})
      script = List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 5)

      {sid, _fake, _} = start_session!(workspace: ws, script: script, full_send: false)

      {:ok, path} =
        Troupe.dispatch(sid, "code", %{prompt: "loop", budget: %{max_turns: 1}})

      ask = await_event(path, :budget_ask_started, 15_000)
      assert ask.data.dimension == :turns

      :ok = Troupe.approve(sid, ask.data.call_id, :deny)
      await_state(path, :done_unread, 15_000)
      assert window(sid, path).reason == :budget_exhausted
    end
  end
end
