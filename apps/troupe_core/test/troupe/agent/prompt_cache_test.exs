defmodule Troupe.Agent.PromptCacheTest do
  @moduledoc """
  What a long turn sends once the prompt is cached (Decisions 770 and 792).

  One input and thirty model calls: the agent writes its task list, reads a file at a
  time, rewrites the list nine more times on the way and answers. The provider is a
  stand-in on a loopback port that keeps a prompt cache as the real one does — Anthropic's
  caches nothing a request did not mark — so what it reports is what the request asked
  for, and the event log has to carry the same numbers.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Catalog, Message, Usage}
  alias Troupe.Test.PromptCacheStandIn
  alias Troupe.Todo

  @moduletag timeout: 120_000

  @calls 30
  # The calls that write the task list: ten in the turn, every third from the first. The
  # request after each is the first to carry the new list.
  @todo_calls Enum.to_list(1..28//3)

  @overflow {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

  setup context do
    for n <- 2..@calls do
      write_file(
        context,
        "notes/part-#{n}.txt",
        String.duplicate("note #{n} says something. ", 60)
      )
    end

    # A price with both cache rates, as the catalog quotes one for a model it prices.
    write_file(context, ".troupe/config.yaml", """
    version: 1
    models:
      prices:
        claude-sonnet-5: {input: 3, output: 15, cache_read: 0.3, cache_write: 3.75}
    """)

    :ok
  end

  test "every call of a 30-call turn reads all of the call before it, the list rewritten ten times",
       context do
    {sid, requests} = long_turn(context, provider: "anthropic", model: "claude-sonnet-5")
    responses = events_of_type(sid, :llm_response)
    assert length(requests) == @calls
    assert length(responses) == @calls

    usages = Enum.map(responses, &Usage.from_json(&1.data["usage"]))
    reads = Enum.map(usages, & &1.cache_read)

    assert hd(reads) == 0, "the first call has nothing to read"

    # What the provider reported is what the log holds, figure for figure.
    for {{_n, _path, _body, reported}, usage} <- Enum.zip(requests, usages) do
      assert usage.input_tokens == reported["input_tokens"]
      assert usage.cache_read == reported["cache_read_input_tokens"]
      assert usage.cache_write == reported["cache_creation_input_tokens"]
    end

    # Every call reads all the call before it sent, the ten after a rewritten task list
    # among them: the list the system prompt shows is the one the turn began with, so a
    # rewrite changes nothing in front of the conversation's marks (Decision 792). All but
    # the second: the list's tools are offered once there is a list (Decision 793), so it
    # is the first call to carry them, in front of everything the first wrote.
    assert Enum.at(reads, 1) == 0

    for n <- 3..@calls do
      assert Enum.at(reads, n - 1) == Usage.total_input(Enum.at(usages, n - 2)),
             "call #{n} reads all of call #{n - 1}'s prompt: #{inspect(reads)}"
    end

    turn = Enum.reduce(usages, %Usage{}, &Usage.add/2)

    assert turn.cache_read > 8 * Usage.billed_input(turn),
           "most of the turn was read from the cache"

    # Each call is priced at the cache's own rates, in micro-dollars: a million tokens
    # read cost 0.3 dollars, so one costs 0.3 micro-dollars.
    for response <- responses do
      usage = Usage.from_json(response.data["usage"])

      expected =
        usage.input_tokens * 3 + usage.cache_read * 0.3 + usage.cache_write * 3.75 +
          usage.output_tokens * 15

      assert_in_delta response.data["gateway"]["cost_micros"], expected, 1
    end
  end

  test "the model reads the task list as it is now on every call of the turn", context do
    {_sid, requests} = long_turn(context, provider: "anthropic", model: "claude-sonnet-5")

    # The last list a request carries is the newest `todo_write`'s result, which says the
    # whole list; the first call has none yet.
    for {n, _path, body, _usage} <- requests do
      assert latest_list(body) == current_list(n), "call #{n} shows the list as it is now"
    end

    # And the system prompt in front of it is the same on every call of the turn.
    systems = Enum.map(requests, fn {_n, _path, body, _usage} -> body["system"] end)
    assert [_one] = Enum.uniq(systems)
  end

  test "the next input's calls show the list the turn before left in the system prompt",
       context do
    stand_in =
      start_stand_in(fn
        1, _body -> write(1)
        2, _body -> {:text, "listed"}
        3, _body -> read(3)
        4, _body -> write(4)
        5, _body -> read(5)
        6, _body -> {:text, "done"}
      end)

    sid = start_turn(context, stand_in, provider: "anthropic", model: "claude-sonnet-5")
    Troupe.send_input(sid, "carry on")
    await_idle(sid)

    requests = PromptCacheStandIn.drain()
    assert [_, _, _, _, {5, _, fifth, _}, _] = requests
    next_turn = Enum.drop(requests, 2)

    # The new turn's prompt shows the list as the last turn left it, and goes on showing
    # it after this turn rewrites it; the rewrite's own result says the list as it is now.
    for {n, _path, body, _usage} <- next_turn do
      assert system_list(body) == rendered(todos(1)), "call #{n}'s system prompt"
    end

    assert latest_list(fifth) == rendered(todos(4))

    # What a list changed by the turn before costs: the first call of the next turn reads
    # the tools and the system prompt in front of the list, and writes the conversation
    # again. Once a turn, not once a rewrite: every call after it reads all of the one
    # before.
    [usage_2, usage_3 | later] = requests |> Enum.drop(1) |> Enum.map(&usage/1)
    assert usage_3.cache_read > 0
    assert usage_3.cache_read < Usage.total_input(usage_2)

    for {previous, current} <- Enum.zip([usage_3 | later], later) do
      assert current.cache_read == Usage.total_input(previous)
    end
  end

  test "on an OpenAI-compatible wire a rewritten task list leaves the cached conversation alone",
       context do
    {_sid, requests} = long_turn(context, provider: "openai", model: "gpt-test")
    assert length(requests) == @calls

    # The list joins the system message there (Decision 770), the prompt's first message:
    # rewritten within the turn, it left only the tools to read. Held for the turn, it
    # leaves the whole of the call before, from the third call: the second is the first to
    # offer the list's tools (Decision 793).
    later = tl(requests)

    for {{_n, _path, _body, previous}, {n, _, _, current}} <- Enum.zip(later, tl(later)) do
      assert current["prompt_tokens_details"]["cached_tokens"] == previous["prompt_tokens"],
             "call #{n} reads all of call #{n - 1}'s prompt"
    end
  end

  test "an OpenAI-compatible provider's cached tokens reach the log beside the billed input",
       context do
    calls = 6

    stand_in =
      start_stand_in(fn n, _body -> if n < calls, do: read(n + 1), else: {:text, "done"} end)

    sid = start_turn(context, stand_in, provider: "openai", model: "gpt-test")

    requests = PromptCacheStandIn.drain()
    responses = events_of_type(sid, :llm_response)
    assert length(responses) == calls

    for {{_n, "/v1/chat/completions", _body, reported}, response} <- Enum.zip(requests, responses) do
      prompt = reported["prompt_tokens"]
      cached = reported["prompt_tokens_details"]["cached_tokens"]

      assert response.data["usage"]["cache_read"] == cached
      assert response.data["usage"]["input_tokens"] == prompt - cached
    end

    [first | rest] = Enum.map(responses, & &1.data["usage"]["cache_read"])
    assert first == 0
    assert Enum.all?(rest, &(&1 > 0))
  end

  test "a gateway's cache writes for an Anthropic model are logged as writes and priced at the write rate",
       context do
    calls = 6

    # What a LiteLLM gateway's `/model_group/info` says of the model group: Sonnet 5's
    # prices, a write a quarter dearer than fresh input and a read a tenth of it.
    catalog =
      :litellm
      |> Catalog.parse(%{
        "data" => [
          %{
            "model_group" => "claude-sonnet-5",
            "mode" => "chat",
            "max_input_tokens" => 1_000_000.0,
            "max_output_tokens" => 128_000.0,
            "input_cost_per_token" => 2.0e-6,
            "output_cost_per_token" => 1.0e-5,
            "cache_read_input_token_cost" => 2.0e-7,
            "cache_creation_input_token_cost" => 2.5e-6
          }
        ]
      })
      |> Map.new(&{&1.id, &1})

    stand_in =
      start_stand_in(fn n, _body -> if n < calls, do: read(n + 1), else: {:text, "done"} end, gateway: :litellm)

    sid = start_turn(context, stand_in, provider: "openai", model: "claude-sonnet-5", catalog: catalog)

    requests = PromptCacheStandIn.drain()
    responses = events_of_type(sid, :llm_response)
    assert length(responses) == calls

    for {{_n, "/v1/chat/completions", _body, reported}, response} <- Enum.zip(requests, responses) do
      usage = Usage.from_json(response.data["usage"])

      assert usage.cache_write == reported["cache_creation_input_tokens"]
      assert usage.cache_read == reported["prompt_tokens_details"]["cached_tokens"]
      assert usage.input_tokens == reported["prompt_tokens_details"]["text_tokens"]
      assert Usage.total_input(usage) == reported["prompt_tokens"]

      # Micro-dollars: a token written costs 2.5, read 0.2, fresh 2, and output 10.
      expected =
        usage.input_tokens * 2 + usage.cache_read * 0.2 + usage.cache_write * 2.5 +
          usage.output_tokens * 10

      assert_in_delta response.data["gateway"]["cost_micros"], expected, 1
    end

    writes = Enum.map(responses, & &1.data["usage"]["cache_write"])
    assert Enum.all?(writes, &(&1 > 0)), "every call wrote what was new: #{inspect(writes)}"
  end

  # Decision 792, against the scripted model: which list the system prompt shows when the
  # turn is not a plain run of calls.
  describe "the task list in the system prompt" do
    test "is the list as it is now once a compaction has rewritten the conversation", context do
      steps = [
        {:text, "first answer"},
        {:text, "second answer"},
        {:tools, [{"todo_write", %{"items" => todos(1)}}]},
        {:tools, [{"todo_write", %{"items" => todos(4)}}]},
        @overflow,
        {:text, "summary of the work so far"},
        {:text, "done"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["first", "second", "write the list"], &turn(session.id, &1))

      assert [_] = events_of_type(session.id, "compacted")
      [_, _, wrote, rewrote, overflowed, _summariser, resent] = Fake.requests(fake)

      # The turn began with no list, and its prompt shows none until the compaction, which
      # may have put the call that wrote the list into the summary.
      assert Enum.map([wrote, rewrote, overflowed], & &1.system_tail) == ["", "", ""]
      assert resent.system_tail =~ rendered(todos(4))
    end

    test "is the one the turn began with after a restart in the middle of it", context do
      steps = [
        {:tools, [{"todo_write", %{"items" => todos(1)}}]},
        {:text, "listed"},
        {:tools, [{"todo_write", %{"items" => todos(4)}}]},
        {:tools, [{"count", %{"path" => "marks.txt", "mark" => "slow", "delay_ms" => 400}}]},
        {:text, "done after the restart"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      turn(session.id, "write the list")

      Troupe.send_input(session.id, "work through it")
      await_started(session.id, "slow")
      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
      await_reply(session.id, "done after the restart")

      [_, _, began, rewrote, restarted] = Fake.requests(fake)
      tails = Enum.map([began, rewrote, restarted], & &1.system_tail)

      assert [shown] = Enum.uniq(tails)
      assert shown =~ rendered(todos(1))
      assert Troupe.snapshot(session.id).todos == parsed(todos(4))
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp script(n) when n in @todo_calls, do: write(n)
  defp script(@calls), do: {:text, "Read them all."}
  defp script(n), do: read(n)

  defp read(n), do: {:tool, "read_file", %{"path" => "notes/part-#{n}.txt"}}
  defp write(n), do: {:tool, "todo_write", %{"items" => todos(n)}}

  # The list as the newest rewrite at or before call `n` wrote it: ten steps, those before
  # the one in progress done.
  defp todos(n) do
    at = Enum.count(@todo_calls, &(&1 <= n)) - 1

    for step <- 0..9 do
      %{
        "id" => "s#{step + 1}",
        "content" => "read part #{step + 1} of the notes",
        "status" => status(step, at)
      }
    end
  end

  defp status(step, at) when step < at, do: "completed"
  defp status(at, at), do: "in_progress"
  defp status(_step, _at), do: "pending"

  defp parsed(items) do
    {:ok, todos} = Todo.parse_list(items)
    todos
  end

  defp rendered(items), do: items |> parsed() |> Todo.render()

  # The list call `n` should show: the one the call before it wrote, if any has.
  defp current_list(1), do: nil
  defp current_list(n), do: rendered(todos(n - 1))

  # The last list an Anthropic request carries: its newest `todo_write` result, else the
  # one in its system prompt.
  defp latest_list(body) do
    updated =
      for %{"content" => blocks} <- body["messages"],
          is_list(blocks),
          %{"type" => "tool_result", "content" => "Task list updated:\n" <> list} <- blocks,
          do: list

    List.last(updated) || system_list(body)
  end

  # The items of the system prompt's `<task_list>`, without whatever it says about them.
  defp system_list(body) do
    text = body["system"] |> List.wrap() |> Enum.map_join("\n", &block_text/1)

    case Regex.run(~r/<task_list>\n(.*?)\n<\/task_list>/s, text) do
      [_, section] ->
        section
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "["))
        |> Enum.join("\n")

      nil ->
        nil
    end
  end

  defp block_text(%{"text" => text}), do: text
  defp block_text(text) when is_binary(text), do: text

  defp usage({_n, _path, _body, reported}) do
    %Usage{
      input_tokens: reported["input_tokens"],
      cache_read: reported["cache_read_input_tokens"],
      cache_write: reported["cache_creation_input_tokens"]
    }
  end

  defp long_turn(context, overrides) do
    stand_in = start_stand_in(fn n, _body -> script(n) end)
    sid = start_turn(context, stand_in, overrides)
    {sid, PromptCacheStandIn.drain()}
  end

  defp start_stand_in(script, opts \\ []) do
    stand_in = PromptCacheStandIn.start([script: script] ++ opts)
    on_exit(fn -> PromptCacheStandIn.stop(stand_in) end)
    stand_in
  end

  defp start_turn(context, stand_in, overrides) do
    overrides = overrides ++ [base_url: stand_in.base_url, api_key: "test-key"]
    %{session: session} = start_session(context, config_overrides: overrides)

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "read the notes")
    await_idle(sid)
    sid
  end

  defp turn(session_id, text) do
    Troupe.send_input(session_id, text)
    await_state(session_id, [:idle], 10_000)
  end

  defp await_idle(sid) do
    receive do
      {:troupe_event, ^sid,
       %Event{type: "agent_state", agent: ["root"], data: %{"state" => "idle"}}} ->
        :ok

      {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"], data: data}} ->
        flunk("the turn ended early: #{inspect(data)}")
    after
      60_000 -> flunk("the turn did not finish")
    end
  end

  defp await_started(sid, mark) do
    receive do
      {:troupe_event, ^sid,
       %Event{type: "tool_call_started", data: %{"args" => %{"mark" => ^mark}}}} ->
        :ok
    after
      5_000 -> flunk("the #{mark} call did not start")
    end
  end

  defp await_reply(sid, text) do
    receive do
      {:troupe_event, ^sid, %Event{type: "llm_response", data: %{"message" => message}}} ->
        if Message.text(Message.from_json(message)) == text, do: :ok, else: await_reply(sid, text)
    after
      10_000 -> flunk("no reply #{inspect(text)}")
    end
  end
end
