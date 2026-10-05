defmodule Troupe.Agent.PromptCacheTest do
  @moduledoc """
  What a long turn sends once the prompt is cached (Decision 770).

  One input and thirty model calls: the agent writes its task list, reads a file at a
  time, rewrites the list twice on the way and answers. The provider is a stand-in on a
  loopback port that keeps a prompt cache as the real one does — Anthropic's caches
  nothing a request did not mark — so what it reports is what the request asked for, and
  the event log has to carry the same numbers.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Catalog, Usage}
  alias Troupe.Test.PromptCacheStandIn

  @moduletag timeout: 120_000

  @calls 30
  # The calls that rewrite the task list. The request after each carries a new one.
  @todo_calls [1, 10, 20]

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

  test "every call of a 30-call turn after the first reads the cache, and the log says so",
       context do
    stand_in = start_stand_in(fn n, _body -> script(n) end)
    sid = start_turn(context, stand_in, provider: "anthropic", model: "claude-sonnet-5")

    requests = PromptCacheStandIn.drain()
    responses = events_of_type(sid, :llm_response)
    assert length(requests) == @calls
    assert length(responses) == @calls

    usages = Enum.map(responses, &Usage.from_json(&1.data["usage"]))
    reads = Enum.map(usages, & &1.cache_read)

    assert hd(reads) == 0, "the first call has nothing to read"
    assert Enum.all?(tl(reads), &(&1 > 0)), "every later call reads: #{inspect(reads)}"

    # What the provider reported is what the log holds, figure for figure.
    for {{_n, _path, _body, reported}, usage} <- Enum.zip(requests, usages) do
      assert usage.input_tokens == reported["input_tokens"]
      assert usage.cache_read == reported["cache_read_input_tokens"]
      assert usage.cache_write == reported["cache_creation_input_tokens"]
    end

    # A call whose task list is the one before's reads everything that call sent; one
    # after the list changed still reads the tools and the system prompt, the same each
    # time, and nothing of the conversation behind the list.
    for n <- 2..@calls do
      previous = Enum.at(usages, n - 2)
      current = Enum.at(usages, n - 1)

      if (n - 1) in @todo_calls do
        assert current.cache_read == Enum.at(usages, 1).cache_read
      else
        assert current.cache_read == Usage.total_input(previous),
               "call #{n} reads all of call #{n - 1}'s prompt"
      end
    end

    turn = Enum.reduce(usages, %Usage{}, &Usage.add/2)

    assert turn.cache_read > 3 * Usage.billed_input(turn),
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

  # -- helpers ------------------------------------------------------------------

  defp script(1), do: {:tool, "todo_write", %{"items" => todos(1)}}
  defp script(n) when n in @todo_calls, do: {:tool, "todo_write", %{"items" => todos(n)}}
  defp script(@calls), do: {:text, "Read them all."}
  defp script(n), do: read(n)

  defp read(n), do: {:tool, "read_file", %{"path" => "notes/part-#{n}.txt"}}

  defp todos(n) do
    [
      %{"id" => "a", "content" => "read the first notes", "status" => status(n, 0, 10)},
      %{"id" => "b", "content" => "read the middle notes", "status" => status(n, 10, 20)},
      %{"id" => "c", "content" => "read the last notes", "status" => status(n, 20, @calls + 1)}
    ]
  end

  defp status(n, from, _to) when n < from, do: "pending"
  defp status(n, _from, to) when n < to, do: "in_progress"
  defp status(_n, _from, _to), do: "completed"

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
end
