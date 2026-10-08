defmodule Troupe.Bench.PrefixTest do
  @moduledoc """
  Issue #465's counter (Decision 815) over events written by hand: what the log says per
  call, each agent's calls compared with its own, and a log written before the fields
  judged by `prompt_bytes`' sizes.
  """

  use ExUnit.Case, async: true

  alias Troupe.Bench.Prefix
  alias Troupe.Protocol.Event

  test "counts what each call's events say, agent by agent" do
    events = [
      request(["root"], %{}),
      response(["root"], %{}),
      request(["root"], %{"system_changed" => false, "tools_changed" => true}),
      response(["root"], %{"thinking_dropped" => 3}),
      # A subagent's first call compares with nothing, its second with its first.
      request(["root", "explore-1"], %{}),
      request(["root", "explore-1"], %{"system_changed" => true, "tools_changed" => false}),
      response(["root", "explore-1"], %{"thinking_resent" => true}),
      request(["root"], %{
        "system_changed" => true,
        "tools_changed" => false,
        "turn_context" => ["task_list"]
      }),
      response(["root"], %{"thinking_dropped" => 4})
    ]

    assert Prefix.count(events) == %{
             "model_calls" => 5,
             "system_changes" => 2,
             "tools_changes" => 1,
             "inferred" => 0,
             "thinking_resent" => 1,
             "thinking_dropped" => 7,
             "calls_dropping" => 2,
             "turn_contexts" => 1
           }
  end

  test "a log written before the fields is judged by the sizes of what each call sent" do
    events = [
      request(["root"], %{"prompt_bytes" => bytes(6000, 18_000)}),
      request(["root"], %{"prompt_bytes" => bytes(6000, 18_400)}),
      request(["root"], %{"prompt_bytes" => bytes(6200, 18_400)}),
      request(["root"], %{"prompt_bytes" => bytes(6200, 18_400)}),
      # Older still: nothing to compare.
      request(["root"], %{})
    ]

    assert %{"system_changes" => 1, "tools_changes" => 1, "inferred" => 3} =
             Prefix.count(events)

    assert Prefix.add(Prefix.count(events), Prefix.zero()) == Prefix.count(events)
  end

  defp bytes(system, tools), do: %{"system" => system, "tools" => tools}

  defp request(agent, data) do
    event("llm_request", agent, Map.merge(%{"model" => "m", "message_count" => 1}, data))
  end

  defp response(agent, data), do: event("llm_response", agent, Map.put(data, "message", %{}))

  defp event(type, agent, data) do
    %Event{
      seq: 1,
      type: type,
      agent: agent,
      data: data,
      actor: Event.Actor.system(),
      ts: "2026-10-08T00:00:00.000000Z"
    }
  end
end
