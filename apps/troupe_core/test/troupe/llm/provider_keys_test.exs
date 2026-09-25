defmodule Troupe.LLM.ProviderKeysTest do
  @moduledoc """
  Which key a request carries, and when it carries none.

  A vendor's own key variable — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` — is that vendor's
  and goes to that vendor's endpoint only: a provider pointed at another URL without a
  key of its own is sent none. And a provider the config refused, because a `{env:VAR}`
  its key reads is not set, makes no request at all.

  `async: false`: the vendor variables are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.LLM.{Message, Provider, Request}
  alias Troupe.LLM.Providers.{Anthropic, OpenAI}
  alias Troupe.Test.FakeTransport

  setup do
    previous = for var <- ~w(ANTHROPIC_API_KEY OPENAI_API_KEY), into: %{}, do: {var, System.get_env(var)}
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-vendor-only")
    System.put_env("OPENAI_API_KEY", "sk-openai-vendor-only")

    on_exit(fn ->
      Enum.each(previous, fn {var, value} ->
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end)
    end)
  end

  describe "a vendor's key variable" do
    test "goes to Anthropic's own endpoint" do
      run(Anthropic, request(base_url: nil, chunks: anthropic_done()))
      [sent] = FakeTransport.drain_requests()
      assert Req.Request.get_header(sent, "x-api-key") == ["sk-ant-vendor-only"]
    end

    test "never goes to a gateway in front of Anthropic" do
      assert {:error, :missing_api_key} =
               run(Anthropic, request(base_url: "https://llm-gw.example/anthropic/v1", chunks: anthropic_done()))

      assert FakeTransport.drain_requests() == []
    end

    test "goes to OpenAI's own endpoint" do
      run(OpenAI, request(base_url: "https://api.openai.com/v1", chunks: openai_done()))
      [sent] = FakeTransport.drain_requests()
      assert Req.Request.get_header(sent, "authorization") == ["Bearer sk-openai-vendor-only"]
    end

    test "never goes to an OpenAI-compatible gateway, which is sent no key at all" do
      run(OpenAI, request(base_url: "https://llm-gw.example/v1", chunks: openai_done()))
      [sent] = FakeTransport.drain_requests()
      assert Req.Request.get_header(sent, "authorization") == []
    end

    test "a key of the provider's own always wins" do
      run(OpenAI, request(base_url: "https://llm-gw.example/v1", api_key: "gw-key", chunks: openai_done()))
      [sent] = FakeTransport.drain_requests()
      assert Req.Request.get_header(sent, "authorization") == ["Bearer gw-key"]
    end
  end

  describe "a refused provider" do
    @why "providers.gw.api_key reads {env:GW_TOKEN}, and GW_TOKEN is not set; the provider gw is refused until it is"

    test "makes no request, and says why" do
      for adapter <- [Anthropic, OpenAI] do
        assert {:error, {:refused, @why} = reason} =
                 run(adapter, request(api_key: {:refused, @why}, base_url: nil, chunks: []))

        assert FakeTransport.drain_requests() == []
        assert Provider.describe_error(reason) == @why
      end
    end
  end

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
    %Request{
      model: "some-model",
      messages: [Message.user("hello")],
      base_url: Keyword.get(opts, :base_url),
      api_key: Keyword.get(opts, :api_key),
      max_retries: 0,
      extra: %{req_adapter: FakeTransport.adapter(chunks: Keyword.fetch!(opts, :chunks), record: self())}
    }
  end

  defp anthropic_done do
    [
      ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n),
      ~s(event: message_stop\ndata: {"type":"message_stop"}\n\n)
    ]
  end

  defp openai_done do
    [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]
  end
end
