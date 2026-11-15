defmodule Troupe.Agent.ContextStatusTest do
  @moduledoc """
  How full the root's context window is, for a client's gauge (#920): an ephemeral
  `context_status` before the first call and after every call, with the window the model is
  known to have, or null where only the fallback is.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Config
  alias Troupe.Session.Log

  test "the root says its window before its first call and how full it is after each one", context do
    steps = [
      {:text_and_tools, "looking", [{"todo_read", %{}}]},
      {:text_and_tools, "done", [{"finish", finished("ok")}]}
    ]

    %{session: session} =
      start_session(context,
        steps: steps,
        config_overrides: [model: "window-model", windows: %{"window-model" => 64_000}]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")

    assert_receive {:troupe_event, ^sid, %Event{type: "context_status", agent: ["root"], data: first} = event},
                   10_000

    assert event.ephemeral?
    assert first == %{"window_tokens" => 64_000, "used_tokens" => 0}

    assert_receive {:troupe_event, ^sid, %Event{type: "llm_response", agent: ["root"]}}, 10_000

    assert_receive {:troupe_event, ^sid, %Event{type: "context_status", data: %{"window_tokens" => 64_000, "used_tokens" => used}}},
                   10_000

    assert used == 100, "the last call's whole prompt, as the fake reports it"

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 10_000

    # One after each of the two calls, and the turn's second call on the same model says
    # nothing before it.
    assert_received {:troupe_event, ^sid, %Event{type: "context_status"}}
    refute_received {:troupe_event, ^sid, %Event{type: "context_status"}}

    refute Enum.any?(Log.replay(sid), &(&1.type == "context_status")),
           "derived, so not in the durable log"
  end

  test "a model nobody gave a window to says null rather than the fallback", context do
    steps = [{:text_and_tools, "done", [{"finish", finished("ok")}]}]

    %{session: session} = start_session(context, steps: steps, config_overrides: [model: "unknown-model"])
    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")

    assert_receive {:troupe_event, ^sid, %Event{type: "context_status", data: %{"window_tokens" => nil}}}, 10_000
  end

  test "known_window/2 has no fallback; context_window/2 keeps it" do
    config = %Config{model: "m", windows: %{"m" => 32_000}, context_window: 200_000}

    assert Config.known_window(config, "m") == 32_000
    assert Config.known_window(config, "other") == nil
    assert Config.known_window(config, nil) == nil
    assert Config.context_window(config, "other") == 200_000
  end
end
