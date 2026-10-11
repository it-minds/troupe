defmodule Troupe.Agent.BudgetCeilingTest do
  @moduledoc """
  What an organisation enforces holds where a session's budget is raised and where a
  model's output limit is read too (issue #622, Decision 869): the budget question raises
  `max_turns` or the wall clock no further than the enforced ceiling and names the
  organisation when that is the limit, `allow` and `always` go no further either, and an
  enforced `max_tokens` holds a named model's own `max_output`. Against a managed file
  written by the test.
  """

  # The managed file's path is the application environment's, which is the whole VM's: a
  # test that moves it runs alone.
  use Troupe.SessionCase, async: false

  alias Troupe.Config
  alias Troupe.Test.PromptCacheStandIn

  setup context do
    managed = Path.join(context.base, "managed.yaml")
    previous = Application.get_env(:troupe_core, :organisation)

    Application.put_env(:troupe_core, :organisation,
      managed_path: managed,
      cache_path: Path.join(context.base, "organisation.json")
    )

    on_exit(fn -> Application.put_env(:troupe_core, :organisation, previous) end)
    Map.put(context, :managed, managed)
  end

  defp enforce(context, yaml), do: File.write!(context.managed, "version: 1\nenforced:\n" <> yaml)

  defp tools(n), do: List.duplicate({:tools, [{"todo_read", %{}}]}, n)
  defp finish(summary), do: {:text_and_tools, "done", [{"finish", finished(summary)}]}

  defp run(context, steps, overrides) do
    %{session: session, fake: fake} =
      start_session(context, steps: steps, config_overrides: overrides)

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "keep going")
    {sid, fake}
  end

  defp await_question(sid, call_id) do
    assert_receive {:troupe_event, ^sid,
                    %Event{type: "question_asked", data: %{"call_id" => ^call_id} = asked}},
                   10_000

    asked
  end

  defp await_answered(sid, call_id) do
    assert_receive {:troupe_event, ^sid,
                    %Event{type: "budget_ask_answered", data: %{"call_id" => ^call_id} = answered}},
                   10_000

    answered
  end

  defp await_done(sid) do
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: done}},
                   10_000

    done
  end

  defp labels(asked), do: Enum.map(asked["options"], &(&1["label"] || &1[:label]))

  defp budget(sid) do
    {_state_name, state} = :sys.get_state(Troupe.Registry.agent_pid(sid, ["root"]))
    state.budget
  end

  describe "reproduction" do
    test "the budget question cannot raise max_turns past an enforced 50", context do
      enforce(context, "  max_turns: 50\n")
      {sid, _fake} = run(context, tools(6) ++ [finish("ok")], max_turns: 2)

      asked = await_question(sid, "budget-1")

      assert asked["question"] =~
               "Your organisation caps the turn limit at 50 turns (#{context.managed})"

      refute "no limit this session" in labels(asked)

      Troupe.answer(sid, "budget-1", "+100")
      assert %{"decision" => "unclear", "note" => note} = await_answered(sid, "budget-1")
      assert note =~ "your organisation caps the turn limit at 50 turns (#{context.managed})"
      refute note =~ "team's terms"

      await_question(sid, "budget-2")
      Troupe.answer(sid, "budget-2", "+25")
      assert %{"decision" => "raise", "amount" => 25} = await_answered(sid, "budget-2")
      assert await_done(sid)["reason"] == "finished"
    end
  end

  describe "the budget question under an enforced ceiling" do
    test "at the ceiling it offers only stop, and says whose limit it is", context do
      enforce(context, "  max_turns: 2\n")
      {sid, fake} = run(context, tools(6), max_turns: 5)

      asked = await_question(sid, "budget-1")
      assert asked["question"] =~ "turns 2/2"

      assert asked["question"] =~
               "Your organisation holds the turn limit to 2 turns (#{context.managed})"

      refute asked["question"] =~ "team's terms"
      assert labels(asked) == ["stop"]

      # Every way past it is asked back, with whose limit it is.
      for {answer, n} <- Enum.with_index(["always", "allow", "+1 run"], 1) do
        Troupe.answer(sid, "budget-#{n}", answer)
        assert %{"decision" => "unclear", "note" => note} = await_answered(sid, "budget-#{n}")
        assert note =~ "your organisation", answer
        await_question(sid, "budget-#{n + 1}")
      end

      assert budget(sid).max_turns == 2
      Troupe.answer(sid, "budget-4", "stop")
      assert await_done(sid)["limit"] == "max_turns"
      assert Fake.call_count(fake) == 2
    end

    test "allow buys the first slice again only as far as the ceiling", context do
      enforce(context, "  max_turns: 3\n")
      {sid, fake} = run(context, tools(6), max_turns: 2)

      await_question(sid, "budget-1")
      Troupe.answer(sid, "budget-1", "allow")
      assert %{"decision" => "allow"} = await_answered(sid, "budget-1")

      # Two more would be four; the organisation holds it to three.
      asked = await_question(sid, "budget-2")
      assert asked["question"] =~ "turns 3/3"
      assert budget(sid).max_turns == 3
      assert Fake.call_count(fake) == 3
    end

    test "a limit the organisation does not enforce still lifts", context do
      enforce(context, "  wall_clock_ms: 600000\n")
      {sid, _fake} = run(context, tools(3) ++ [finish("ok")], max_turns: 1)

      asked = await_question(sid, "budget-1")
      assert "no limit this session" in labels(asked)
      Troupe.answer(sid, "budget-1", "always")
      assert await_done(sid)["reason"] == "finished"
    end
  end

  describe "the ceilings a configuration carries" do
    test "the budget's limits, with where each came from, and never from an override", context do
      enforce(context, "  max_turns: 50\n  wall_clock_ms: 600000\n  max_tokens: 1000\n")

      config = Config.load(context.workspace, ceilings: %{})

      assert config.ceilings == %{
               max_turns: %{limit: 50, source: context.managed},
               wall_clock: %{limit: 600_000, source: context.managed}
             }

      enforce(context, "  approvals: deny\n")

      assert Config.load(context.workspace, ceilings: %{max_turns: %{limit: 1, source: "x"}}).ceilings ==
               %{}
    end
  end

  describe "a named model's own output limit" do
    test "an enforced max_tokens holds a model's max_output, and a lower max_output still lowers it",
         context do
      enforce(context, "  max_tokens: 1000\n")

      assert max_tokens_sent(context, 64_000, max_tokens: 50_000) == 1000
      assert max_tokens_sent(context, 500, max_tokens: 50_000) == 500
    end
  end

  # The output limit the first model call of a session went out with, to a named provider
  # whose model declares `max_output`.
  defp max_tokens_sent(context, max_output, overrides) do
    stand_in = PromptCacheStandIn.start(script: fn _n, _body -> {:text, "done"} end)
    on_exit(fn -> PromptCacheStandIn.stop(stand_in) end)

    provider = %{
      type: :anthropic,
      base_url: stand_in.base_url,
      api_key: "test-key",
      auth: :api_key,
      source: :yaml,
      models: %{
        "big" => %{id: "big", context: nil, max_output: max_output, reasoning_effort: nil}
      }
    }

    %{session: session} =
      start_session(context,
        config_overrides: [providers: %{"gw" => provider}, model: "gw/big"] ++ overrides
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "say done")
    await_state(sid, [:idle], 30_000)

    [{1, "/v1/messages", body, _usage} | _] = PromptCacheStandIn.drain()
    body["max_tokens"]
  end
end
