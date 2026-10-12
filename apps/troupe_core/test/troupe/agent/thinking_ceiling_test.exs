defmodule Troupe.Agent.ThinkingCeilingTest do
  @moduledoc """
  An organisation's enforced `max_tokens` holds every model call, the room a reasoning
  effort asks for included (issue #644). An agent's request to a named Anthropic provider,
  sent to a loopback stand-in that records the body, asks for no more than the ceiling:
  its thinking is shortened so the answer keeps its share under it, and is off where less
  than Anthropic's 1,024-token minimum is left. An OpenAI-compatible provider at the same
  effort asks for no more either, the summariser's own call is held too, and the session
  is told once, naming where the limit came from. Against a managed file written by the
  test.
  """

  # The managed file's path is the application environment's, which is the whole VM's: a
  # test that moves it runs alone.
  use Troupe.SessionCase, async: false

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

  describe "reproduction" do
    test "with max_tokens 1000 enforced and effort high, the request asks for 1000 and no thinking",
         context do
      enforce(context, "  max_tokens: 1000\n")
      {sid, [body]} = turns(context, :anthropic, "claude-opus-5-5", "high", 1)

      assert body["max_tokens"] == 1000
      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "output_config")

      assert [note] = events_of_type(sid, "config_note")
      assert note.agent == ["root"]

      assert note.data == %{
               "key" => "max_tokens",
               "limit" => 1000,
               "source" => context.managed,
               "model" => "claude-opus-5-5",
               "effort" => "high",
               "thinking" => 0,
               "message" =>
                 "Your organisation caps a model call's output at 1,000 tokens " <>
                   "(#{context.managed}), so reasoning is off for this session: " <>
                   "reasoning_effort high asks for 16,384 tokens of thinking, and " <>
                   "less than 1,024 is left beside the answer."
             }
    end
  end

  describe "Anthropic under a ceiling" do
    test "a thinking budget shrinks so the answer keeps its 4,096 tokens", context do
      enforce(context, "  max_tokens: 8192\n")
      {sid, [body]} = turns(context, :anthropic, "claude-haiku-4-5", "high", 1)

      assert body["max_tokens"] == 8192
      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 4096}

      assert [%{data: %{"thinking" => 4096, "message" => message}}] =
               events_of_type(sid, "config_note")

      assert message ==
               "Your organisation caps a model call's output at 8,192 tokens " <>
                 "(#{context.managed}), so reasoning is shortened for this session: " <>
                 "4,096 tokens of thinking where reasoning_effort high asks for 16,384."
    end

    test "adaptive thinking's level comes down to the room that is left", context do
      enforce(context, "  max_tokens: 8192\n")
      {_sid, [body]} = turns(context, :anthropic, "claude-opus-5-5", "high", 1)

      assert body["max_tokens"] == 8192
      assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert body["output_config"] == %{"effort" => "low"}
    end

    test "a ceiling the thinking fits under changes nothing and says nothing", context do
      enforce(context, "  max_tokens: 32768\n")
      {sid, [body]} = turns(context, :anthropic, "claude-opus-5-5", "high", 1)

      assert body["max_tokens"] == 16_384 + 4_096
      assert body["output_config"] == %{"effort" => "high"}
      assert events_of_type(sid, "config_note") == []
    end

    test "the session is told once, however many calls are held", context do
      enforce(context, "  max_tokens: 1000\n")
      {sid, bodies} = turns(context, :anthropic, "claude-opus-5-5", "high", 2)

      assert length(bodies) == 2
      assert Enum.all?(bodies, &(&1["max_tokens"] == 1000 and not Map.has_key?(&1, "thinking")))
      assert [_once] = events_of_type(sid, "config_note")
    end

    test "nothing enforced, the cap is raised to hold the thinking as before", context do
      {sid, [body]} = turns(context, :anthropic, "claude-opus-5-5", "high", 1)

      assert body["max_tokens"] == 16_384 + 4_096
      assert body["output_config"] == %{"effort" => "high"}
      assert events_of_type(sid, "config_note") == []
    end
  end

  describe "an OpenAI-compatible provider under a ceiling" do
    test "at effort high asks for no more than the ceiling, the reasoning inside it", context do
      enforce(context, "  max_tokens: 1000\n")
      {sid, [body]} = turns(context, :openai, "reasoner", "high", 1)

      assert body["max_completion_tokens"] == 1000
      assert body["reasoning_effort"] == "high"
      refute Map.has_key?(body, "max_tokens")
      assert events_of_type(sid, "config_note") == []
    end
  end

  describe "every call" do
    test "the summariser's own call asks for no more than the ceiling", context do
      enforce(context, "  max_tokens: 1000\n")

      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [context_window: 120, compact_at: 0.5],
          steps: [
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]},
            {:tools, [{"todo_read", %{}}]},
            {:text, "here is a summary of everything that happened earlier"},
            {:text, "carrying on"}
          ]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "do several things")
      await_state(session.id, [:idle], 10_000)

      requests = Fake.requests(fake)
      assert summariser = Enum.find(requests, &(&1.system =~ "compress a coding session"))
      assert summariser.max_tokens == 1000
      assert Enum.all?(requests, &(&1.max_tokens <= 1000))
    end
  end

  describe "a session that comes back" do
    test "is not told again after it was stopped and resumed", context do
      enforce(context, "  max_tokens: 1000\n")
      overrides = named(stand_in(), :anthropic, "claude-opus-5-5", "high")

      %{session: session} = start_session(context, config_overrides: overrides)
      sid = session.id
      :ok = Troupe.subscribe(sid)
      turn(sid)
      assert_received {:prompt_cache_stand_in, 1, _path, %{"max_tokens" => 1000}, _usage}
      assert [_told] = events_of_type(sid, "config_note")

      :ok = Troupe.stop_session(sid)
      released(sid, 200)

      fake = start_supervised!({Fake, steps: []}, id: :resumed_fake)

      {:ok, _resumed} =
        Troupe.resume(sid,
          workspace: context.workspace,
          fake: fake,
          config_overrides:
            [provider: "fake", auto_approve: true, state_dir: context.state_dir] ++ overrides
        )

      on_exit(fn -> Troupe.stop_session(sid) end)

      # The note goes before the call it is about, so the second call is the moment to look.
      Troupe.send_input(sid, "think again")
      assert_receive {:prompt_cache_stand_in, 2, _path, %{"max_tokens" => 1000}, _usage}, 30_000
      assert [_still_once] = events_of_type(sid, "config_note")
    end
  end

  # `n` turns of one call each to a named provider of `type` whose model has `effort`, and
  # the bodies the stand-in received, in order.
  defp turns(context, type, model, effort, n) do
    overrides = named(stand_in(), type, model, effort)
    %{session: session} = start_session(context, config_overrides: overrides)

    sid = session.id
    :ok = Troupe.subscribe(sid)
    for _turn <- 1..n, do: turn(sid)

    {sid, for({_n, _path, body, _usage} <- PromptCacheStandIn.drain(), do: body)}
  end

  defp stand_in do
    stand_in = PromptCacheStandIn.start(script: fn _n, _body -> {:text, "done"} end)
    on_exit(fn -> PromptCacheStandIn.stop(stand_in) end)
    stand_in
  end

  # The session's model, through a named provider at the stand-in.
  defp named(stand_in, type, model, effort) do
    provider = %{
      type: type,
      base_url: stand_in.base_url,
      api_key: "test-key",
      auth: if(type == :anthropic, do: :api_key, else: :bearer),
      source: :yaml,
      models: %{model => %{id: model, context: nil, max_output: nil, reasoning_effort: effort}}
    }

    [providers: %{"gw" => provider}, model: "gw/" <> model]
  end

  defp turn(sid) do
    Troupe.send_input(sid, "think about it")
    await_state(sid, [:idle], 30_000)
  end

  # `stop_session/1` returns before the registry has noticed the exit.
  defp released(_sid, 0), do: :ok

  defp released(sid, attempts) do
    if Registry.whereis({:session, sid}) || Registry.whereis({:log, sid}) do
      Process.sleep(5)
      released(sid, attempts - 1)
    else
      :ok
    end
  end
end
