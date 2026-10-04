defmodule Troupe.Agent.TurnCostTest do
  @moduledoc """
  What a turn cost, and what each of its model calls was made of, in the log (issue #389,
  Decision 769). One thing a person typed is many model calls, each resending the whole
  conversation; the log said what each call reported and nothing about the turn they
  made up, nor which part of the prompt was the large one.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Registry

  @turn_keys ~w(calls input_tokens cache_read cache_write output_tokens cost_micros unpriced)

  defp run(context, opts) do
    %{session: session} = start_session(context, opts)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    session.id
  end

  test "a turn of several calls ends with how many there were and what they cost together",
       context do
    # Every answer reports 100 fresh input tokens, 1,000 read from the cache and one
    # output token; the imaginary gateway charges 100 * 3 + 1 * 15 micros a call.
    sid =
      run(context,
        steps: [
          {:text_and_tools, "one", [{"todo_read", %{}}]},
          {:text_and_tools, "two", [{"todo_read", %{}}]},
          {:text, "done"}
        ],
        cache_read: 1_000
      )

    ended = await_event(sid, :turn_ended, 10_000)

    assert ended.data["turn"] == %{
             "calls" => 3,
             "input_tokens" => 300,
             "cache_read" => 3_000,
             "cache_write" => 0,
             "output_tokens" => 3,
             "cost_micros" => 945,
             "unpriced" => 0
           }

    # The same figures the three responses carry, added up.
    responses = events_of_type(sid, :llm_response)
    assert length(responses) == 3
    assert Enum.sum(Enum.map(responses, & &1.data["gateway"]["cost_micros"])) == 945
  end

  test "each call says what its prompt was made of, in bytes", context do
    write_file(context, "AGENTS.md", "Run the tests before you say you are done.\n")

    sid =
      run(context,
        steps: [{:text_and_tools, "one", [{"todo_read", %{}}]}, {:text, "done"}]
      )

    await_event(sid, :turn_ended, 10_000)

    [first, second] = Enum.map(events_of_type(sid, :llm_request), & &1.data["prompt_bytes"])

    for part <- ~w(system brief tools conversation tool_results),
        do: assert(is_integer(first[part]) and first[part] >= 0, "#{part} in #{inspect(first)}")

    assert first["system"] > 0
    assert first["tools"] > 0
    assert first["brief"] > byte_size("Run the tests before you say you are done.")
    # The person's "go" is all the conversation there is yet, and nothing has run.
    assert first["conversation"] == byte_size("go")
    assert first["tool_results"] == 0

    # The second call resends the first, its tool call and its result.
    assert second["conversation"] > first["conversation"]
    assert second["tool_results"] > 0
    assert second["system"] == first["system"]
    assert second["tools"] == first["tools"]
  end

  test "a model that has no price is counted, and the turn says how many calls were not priced",
       context do
    sid =
      run(context,
        steps: [{:text_and_tools, "one", [{"todo_read", %{}}]}, {:text, "done"}],
        cost_micros: nil
      )

    ended = await_event(sid, :turn_ended, 10_000)
    assert %{"calls" => 2, "cost_micros" => 0, "unpriced" => 2} = ended.data["turn"]
  end

  test "the next turn counts from nothing", context do
    sid =
      run(context,
        steps: [
          {:text, "first"},
          {:text_and_tools, "two", [{"todo_read", %{}}]},
          {:text, "second"}
        ]
      )

    first = await_event(sid, :turn_ended, 10_000)
    assert first.data["turn"]["calls"] == 1

    Troupe.send_input(sid, "again")
    second = await_event(sid, :turn_ended, 10_000)
    assert second.data["turn"]["calls"] == 2
  end

  test "a turn that delegates counts its subagent's calls as its own", context do
    sid =
      run(context,
        routes: %{
          "root" => [
            {:tools, [{"delegate", %{"agent" => "general", "task" => "look"}}]},
            {:text, "it came back"}
          ],
          "general" => [
            {:text_and_tools, "looking", [{"todo_read", %{}}]},
            {:tools, [{"finish", %{"summary" => "found it"}}]}
          ]
        }
      )

    ended = await_event(sid, :turn_ended, 10_000)
    assert ended.data["turn"]["calls"] == 4

    # The subagent's own end says what the delegation cost.
    [done] = Enum.filter(events_of_type(sid, :agent_done), &(&1.agent != ["root"]))
    assert done.data["turn"]["calls"] == 2
    assert ended.data["turn"]["cost_micros"] > done.data["turn"]["cost_micros"]
  end

  test "a cancelled turn says what it cost too", context do
    sid =
      run(context,
        steps: [
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"shell", %{"command" => "sleep 30"}}]}
        ]
      )

    await_event(sid, :tool_call_started, 10_000)
    await_event(sid, :tool_call_started, 10_000)
    Troupe.cancel(sid)

    cancelled = await_event(sid, :cancelled, 10_000)
    assert cancelled.data["turn"]["calls"] == 2
    assert Map.keys(cancelled.data["turn"]) |> Enum.sort() == Enum.sort(@turn_keys)
  end

  test "an agent that finishes says what its last turn cost", context do
    sid =
      run(context,
        steps: [
          {:text_and_tools, "on it", [{"todo_read", %{}}]},
          {:tools, [{"finish", %{"summary" => "all done"}}]}
        ]
      )

    done = await_event(sid, :agent_done, 10_000)
    assert done.data["turn"]["calls"] == 2
  end

  test "a restart in the middle of a turn still counts the calls made before it", context do
    marks = "marks.txt"

    sid =
      run(context,
        steps: [
          {:tools, [{"count", %{"path" => marks, "mark" => "first"}}]},
          {:tools, [{"count", %{"path" => marks, "mark" => "second", "delay_ms" => 400}}]},
          {:text, "done after restart"}
        ]
      )

    await_started(sid, "second")
    agent = Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

    ended = await_event(sid, :turn_ended, 10_000)
    assert ended.data["turn"]["calls"] == 3
  end

  defp await_started(session_id, mark, timeout \\ 5_000) do
    receive do
      {:troupe_event, ^session_id,
       %Event{type: "tool_call_started", data: %{"args" => %{"mark" => ^mark}}}} ->
        :ok

      _other ->
        await_started(session_id, mark, timeout)
    after
      timeout -> raise "timed out waiting for the #{mark} call to start"
    end
  end
end
