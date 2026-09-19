defmodule Troupe.LLM.ProvidersTest do
  @moduledoc """
  The HTTP adapters, driven through Req with a scripted transport.

  The socket is replaced, not the client: the request goes through Req's real
  pipeline and the `:into` callback is fed chunk by chunk, so SSE framing,
  accumulation and the request shaping are all exercised. Chunk boundaries are
  deliberately awkward — events split mid-line, several events in one chunk —
  because that is what a network does and it is where a streaming client breaks.
  """

  use ExUnit.Case, async: true

  alias Troupe.LLM.{Message, Request, Response, SSE, Text, ToolResult, ToolUse}
  alias Troupe.LLM.Providers.{Anthropic, OpenAI}
  alias Troupe.Test.FakeTransport

  describe "SSE framing" do
    test "reassembles events split across chunk boundaries" do
      {events, sse} = SSE.feed(SSE.new(), "event: message_start\ndata: {\"a\":")
      assert events == []

      {events, _sse} = SSE.feed(sse, "1}\n\nevent: ping\ndata: {}\n\n")

      assert [first, second] = events
      assert first.event == "message_start"
      assert {:ok, %{"a" => 1}} = SSE.decode(first)
      assert second.event == "ping"
    end

    test "handles CRLF, comments and the [DONE] sentinel" do
      {events, _} = SSE.feed(SSE.new(), ": keepalive\r\n\r\ndata: [DONE]\r\n\r\n")
      assert [done] = events
      assert SSE.decode(done) == :done
    end

    test "joins multi-line data fields" do
      {[event], _} = SSE.feed(SSE.new(), "data: {\"x\":\ndata: 2}\n\n")
      assert {:ok, %{"x" => 2}} = SSE.decode(event)
    end
  end

  describe "anthropic adapter" do
    test "streams text and a tool call, reporting usage" do
      chunks = anthropic_stream() |> Enum.chunk_every(2) |> Enum.map(&Enum.join/1)

      assert {:ok, %Response{} = response} = run(Anthropic, request(chunks: chunks))

      assert [%Text{text: text}, %ToolUse{} = tool] = response.content
      assert text == "Let me look."
      assert tool.name == "read_file"
      assert tool.input == %{"path" => "lib/a.ex"}
      assert response.stop_reason == :tool_use
      assert response.usage.input_tokens == 25
      assert response.usage.output_tokens == 7

      assert_received {:llm_delta, _ref, %{kind: :text, text: "Let me "}}
      assert_received {:llm_delta, _ref, %{kind: :tool_use_start, name: "read_file"}}

      [sent] = FakeTransport.drain_requests()
      assert sent.method == :post
      assert to_string(sent.url) =~ "/v1/messages"
      assert Req.Request.get_header(sent, "x-api-key") == ["test-key"]
      assert Req.Request.get_header(sent, "anthropic-version") == ["2023-06-01"]

      body = FakeTransport.body(sent)
      assert body["model"] == "claude-sonnet-5"
      assert body["stream"] == true
      assert body["system"] =~ "You are a test"
      assert [%{"name" => "read_file", "input_schema" => _}] = body["tools"]
    end

    test "encodes tool results as content blocks on a user message" do
      messages = [
        Message.user("read it"),
        Message.assistant([%ToolUse{id: "t1", name: "read_file", input: %{"path" => "a"}}]),
        Message.tool_results([%ToolResult{tool_use_id: "t1", content: "contents", error?: false}])
      ]

      assert {:ok, _response} =
               run(Anthropic, request(chunks: anthropic_text_only(), messages: messages))

      [sent] = FakeTransport.drain_requests()
      [_user, assistant, results] = FakeTransport.body(sent)["messages"]

      assert %{"role" => "assistant", "content" => [%{"type" => "tool_use"}]} = assistant
      assert %{"role" => "user", "content" => [block]} = results
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "t1"
      assert block["is_error"] == false
    end

    test "retries a 429, then a transport error, then succeeds" do
      request =
        request(
          chunks: anthropic_text_only(),
          fail_first: 1,
          fail_status: 429,
          transport_error: 1,
          max_retries: 3
        )

      assert {:ok, %Response{}} = run(Anthropic, request)

      # One transport failure, one 429, and the attempt that worked.
      assert length(FakeTransport.drain_requests()) == 3
    end

    test "gives up after the retry budget and reports an error" do
      request = request(chunks: [], fail_first: 99, fail_status: 503, max_retries: 1)

      assert {:error, {:retries_exhausted, {:http_status, 503}}} = run(Anthropic, request)
      assert length(FakeTransport.drain_requests()) == 2
    end

    test "a 400 is not retried" do
      request = request(chunks: [], fail_first: 99, fail_status: 400, max_retries: 3)

      assert {:error, {:http_status, 400, _}} = run(Anthropic, request)
      assert length(FakeTransport.drain_requests()) == 1
    end

    test "an api error inside the stream is reported, not returned as a response" do
      chunk = ~s(event: error\ndata: {"type":"error","error":{"message":"overloaded"}}\n\n)

      assert {:error, {:api_error, "overloaded"}} = run(Anthropic, request(chunks: [chunk]))
    end

    test "a missing api key fails without making a request" do
      # Guard against a developer's own key in the environment changing the outcome.
      if System.get_env("ANTHROPIC_API_KEY") in [nil, ""] do
        assert {:error, :missing_api_key} = run(Anthropic, request(chunks: [], api_key: nil))
        assert FakeTransport.drain_requests() == []
      end
    end
  end

  describe "openai-compatible adapter" do
    test "streams text and reassembles a tool call from argument fragments" do
      assert {:ok, %Response{} = response} = run(OpenAI, request(chunks: openai_stream()))

      assert [%Text{text: "Checking."}, %ToolUse{} = tool] = response.content
      assert tool.id == "call_abc"
      assert tool.name == "read_file"
      assert tool.input == %{"path" => "lib/a.ex"}
      assert response.stop_reason == :tool_use
      assert response.usage.input_tokens == 31
      assert response.usage.output_tokens == 9

      assert_received {:llm_delta, _ref, %{kind: :text, text: "Check"}}

      [sent] = FakeTransport.drain_requests()
      assert to_string(sent.url) =~ "/v1/chat/completions"
      assert Req.Request.get_header(sent, "authorization") == ["Bearer test-key"]
    end

    test "a base url that already ends in /v1 does not get a second one" do
      # What every OpenAI-compatible gateway documents, LiteLLM included.
      request =
        request(chunks: [openai_text_only()], base_url: "https://gateway.example/v1")

      assert {:ok, _response} = run(OpenAI, request)

      [sent] = FakeTransport.drain_requests()
      assert to_string(sent.url) == "https://gateway.example/v1/chat/completions"
    end

    test "turns tool results into role:tool messages and system into a message" do
      messages = [
        Message.user("read it"),
        Message.assistant([
          %Text{text: "on it"},
          %ToolUse{id: "t1", name: "read_file", input: %{"path" => "a"}}
        ]),
        Message.tool_results([%ToolResult{tool_use_id: "t1", content: "contents", error?: false}])
      ]

      assert {:ok, _response} =
               run(OpenAI, request(chunks: [openai_text_only()], messages: messages))

      [sent] = FakeTransport.drain_requests()
      body = FakeTransport.body(sent)
      [system, user, assistant, tool] = body["messages"]

      assert system["role"] == "system"
      assert system["content"] =~ "You are a test"
      assert user["role"] == "user"
      assert assistant["role"] == "assistant"
      assert assistant["content"] == "on it"

      assert [%{"function" => %{"name" => "read_file", "arguments" => args}}] =
               assistant["tool_calls"]

      assert Jason.decode!(args) == %{"path" => "a"}
      assert tool["role"] == "tool"
      assert tool["tool_call_id"] == "t1"
      assert tool["content"] == "contents"

      assert [%{"type" => "function", "function" => %{"parameters" => _}}] = body["tools"]
      assert body["stream_options"]["include_usage"] == true
    end

    test "works against any base url without an api key" do
      request =
        request(chunks: [openai_text_only()], api_key: nil, base_url: "http://localhost:8000")

      assert {:ok, %Response{content: [%Text{text: "Hello."}]}} = run(OpenAI, request)

      [sent] = FakeTransport.drain_requests()
      assert to_string(sent.url) == "http://localhost:8000/v1/chat/completions"
      assert Req.Request.get_header(sent, "authorization") == []
    end

    test "malformed tool arguments still reach the agent" do
      chunk = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"grep","arguments":"{not json"}}]}}]}

      data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

      data: [DONE]

      """

      assert {:ok, %Response{content: [%ToolUse{} = tool]}} =
               run(OpenAI, request(chunks: [chunk]))

      assert tool.name == "grep"
      assert tool.input == %{"__malformed_arguments__" => "{not json"}
    end

    test "a tool call with no id still gets one the model can match against" do
      chunk = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"grep","arguments":"{}"}}]}}]}

      data: [DONE]

      """

      assert {:ok, %Response{content: [%ToolUse{id: id}]}} = run(OpenAI, request(chunks: [chunk]))
      assert id == "call_0"
    end
  end

  describe "auth schemes" do
    test "anthropic sends its own header by default and a bearer token when asked" do
      chunks = anthropic_stream()

      assert {:ok, %Response{}} = run(Anthropic, request(chunks: chunks))
      [sent] = FakeTransport.drain_requests()
      assert Req.Request.get_header(sent, "x-api-key") == ["test-key"]
      assert Req.Request.get_header(sent, "authorization") == []

      assert {:ok, %Response{}} = run(Anthropic, %{request(chunks: chunks) | auth: :bearer})
      [sent] = FakeTransport.drain_requests()
      assert Req.Request.get_header(sent, "authorization") == ["Bearer test-key"]
      assert Req.Request.get_header(sent, "x-api-key") == []
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp run(adapter, request) do
    ref = make_ref()
    :ok = adapter.stream(request, self(), ref)

    receive do
      {:llm_done, ^ref, response} -> {:ok, response}
      {:llm_error, ^ref, reason} -> {:error, reason}
    after
      15_000 -> {:error, :timeout}
    end
  end

  defp request(opts) do
    transport =
      FakeTransport.adapter(
        chunks: Keyword.get(opts, :chunks, []),
        fail_first: Keyword.get(opts, :fail_first, 0),
        fail_status: Keyword.get(opts, :fail_status, 429),
        transport_error: Keyword.get(opts, :transport_error, 0),
        record: self()
      )

    %Request{
      model: "claude-sonnet-5",
      messages: Keyword.get(opts, :messages, [Message.user("hello")]),
      system: "You are a test.",
      tools: [
        %{
          name: "read_file",
          description: "Read a file.",
          schema: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
        }
      ],
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key, "test-key"),
      max_retries: Keyword.get(opts, :max_retries, 0),
      timeout_ms: 10_000,
      extra: %{req_adapter: transport}
    }
  end

  defp anthropic_stream do
    [
      ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}\n\n),
      ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n),
      ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me "}}\n\n),
      ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"look."}}\n\n),
      ~s(event: content_block_start\ndata: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file"}}\n\n),
      ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":"}}\n\n),
      ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"lib/a.ex\\"}"}}\n\n),
      ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}\n\n),
      ~s(event: message_stop\ndata: {"type":"message_stop"}\n\n)
    ]
  end

  defp anthropic_text_only do
    [
      ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}\n\n),
      ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n),
      ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello."}}\n\n),
      ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n)
    ]
  end

  defp openai_stream do
    [
      ~s(data: {"choices":[{"delta":{"role":"assistant","content":"Check"}}]}\n\ndata: {"choices":[{"delta":{"content":"ing."}}]}\n\n),
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"read_file","arguments":""}}]}}]}\n\n),
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]}}]}\n\n),
      ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"lib/a.ex\\"}"}}]}}]}\n\n),
      ~s(data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":31,"completion_tokens":9}}\n\n),
      ~s(data: [DONE]\n\n)
    ]
  end

  defp openai_text_only do
    ~s(data: {"choices":[{"delta":{"content":"Hello."}}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}\n\ndata: [DONE]\n\n)
  end
end
