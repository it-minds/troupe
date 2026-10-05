defmodule Troupe.LLM.ThinkingTest do
  @moduledoc """
  The thinking a reasoning effort sends to Anthropic, in the form each model takes
  (Decision 780): adaptive thinking with an effort level for the models that refuse a
  budget, a `budget_tokens` for those that still take one, and a refusal said in words
  that name the setting to change.

  The request bodies are compared against bodies written out in full, the way the API's
  documentation of 2026-10-05 has each form, through the adapter's real Req pipeline.
  """

  use ExUnit.Case, async: true

  alias Troupe.LLM.{Catalog, Message, Provider, Request}
  alias Troupe.LLM.Providers.Anthropic
  alias Troupe.Test.FakeTransport

  # What a request for Claude Opus 5.5 at `reasoning_effort: high` goes out as.
  @opus_5_5_high ~S"""
  {
    "model": "claude-opus-5-5",
    "max_tokens": 20480,
    "stream": true,
    "system": "You are a test.",
    "messages": [{"role": "user", "content": [{"type": "text", "text": "hello"}]}],
    "thinking": {"type": "adaptive", "display": "summarized"},
    "output_config": {"effort": "high"}
  }
  """

  # And for Claude Haiku 4.5 at `reasoning_effort: medium`, as it went before.
  @haiku_4_5_medium ~S"""
  {
    "model": "claude-haiku-4-5",
    "max_tokens": 12288,
    "stream": true,
    "system": "You are a test.",
    "messages": [{"role": "user", "content": [{"type": "text", "text": "hello"}]}],
    "thinking": {"type": "enabled", "budget_tokens": 8192}
  }
  """

  describe "Anthropic's newest models" do
    test "a reasoning effort sends adaptive thinking and the effort, not a budget" do
      assert sent("claude-opus-5-5", "high") == Jason.decode!(@opus_5_5_high)
    end

    test "every model that refuses a budget gets the newer form, a gateway's renaming too" do
      for model <- [
            "claude-opus-5-5",
            "claude-opus-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-sonnet-5-5",
            "claude-sonnet-5",
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-mythos-5-1",
            "eu.anthropic.claude-opus-5",
            "anthropic/claude-sonnet-5-5"
          ] do
        body = sent(model, "medium")
        assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}, model
        assert body["output_config"] == %{"effort" => "medium"}, model
        assert body["max_tokens"] == 8_192 + 4_096, "#{model}: the cap still holds the thinking"
      end
    end

    test "Troupe's levels and budgets map onto Anthropic's five levels" do
      for {effort, level} <- [
            {"minimal", "low"},
            {"low", "low"},
            {"medium", "medium"},
            {"high", "high"},
            {"xhigh", "xhigh"},
            {"max", "max"},
            {"1024", "low"},
            {"4096", "low"},
            {"8192", "medium"},
            {"12000", "high"},
            {"16384", "high"},
            {"32768", "xhigh"},
            {"64000", "max"}
          ] do
        assert sent("claude-sonnet-5-5", effort)["output_config"] == %{"effort" => level}, effort
      end
    end

    test "no effort, or none, sends no thinking at all" do
      for effort <- [nil, "none", "off", "500"] do
        body = sent("claude-opus-5-5", effort)
        refute Map.has_key?(body, "thinking"), inspect(effort)
        refute Map.has_key?(body, "output_config"), inspect(effort)
        assert body["max_tokens"] == 8_192
      end
    end
  end

  describe "models that still take a budget" do
    test "a reasoning effort sends budget_tokens, as it did before" do
      assert sent("claude-haiku-4-5", "medium") == Jason.decode!(@haiku_4_5_medium)
    end

    test "every model before Opus 4.7 keeps the budget, dated or renamed" do
      for model <- [
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "us.anthropic.claude-haiku-4-5-20251001-v1:0",
            "claude-sonnet-4-5@20250929",
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "claude-opus-4-5",
            "claude-opus-4-1",
            "claude-sonnet-4-20250514",
            "claude-3-7-sonnet-20250219"
          ] do
        body = sent(model, "high")
        assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 16_384}, model
        refute Map.has_key?(body, "output_config"), model
      end

      assert sent("claude-opus-4-6", "12000")["thinking"] == %{
               "type" => "enabled",
               "budget_tokens" => 12_000
             }

      assert sent("claude-opus-4-6", "max")["thinking"] == %{
               "type" => "enabled",
               "budget_tokens" => 32_768
             }
    end
  end

  describe "a model nothing describes" do
    test "a level sends the newer form, and a number of tokens a budget" do
      body = sent("house-model", "high")
      assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert body["output_config"] == %{"effort" => "high"}

      body = sent("house-model", "12000")
      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 12_000}
      refute Map.has_key?(body, "output_config")
    end

    test "a 400 that names thinking says which setting to change" do
      refusal =
        "thinking.type: Input tag 'adaptive' found using 'type' does not match any of the expected tags: 'disabled', 'enabled'"

      assert {:error, reason} = run(request("house-model", "high", fail: refusal))
      described = Provider.describe_error(reason)

      assert described =~ "refused adaptive thinking at effort high"
      assert described =~ "reasoning_effort"
      assert described =~ "a number of tokens"
      assert described =~ "or remove it"
      assert described =~ "does not match any of the expected tags"

      refusal =
        ~s("thinking.type.enabled" is not supported for this model. Use "thinking.type.adaptive")

      assert {:error, reason} = run(request("house-model", "12000", fail: refusal))
      described = Provider.describe_error(reason)

      assert described =~ "refused a thinking budget of 12000 tokens"
      assert described =~ "low, medium, high, xhigh or max"
    end

    test "a 400 about something else is not taken for a thinking refusal" do
      assert {:error, reason} = run(request("house-model", "high", fail: "tools.0: bad schema"))
      assert Provider.describe_error(reason) == "the provider answered 400 (tools.0: bad schema)"

      assert {:error, reason} =
               run(
                 request("house-model", nil, fail: ~s("thinking.type.enabled" is not supported))
               )

      refute Provider.describe_error(reason) =~ "reasoning_effort"
    end
  end

  describe "what the model list says" do
    test "Anthropic's listing says which form each model takes, and the cache keeps it" do
      # `GET /v1/models` as it lists a model of each kind, capabilities cut to thinking.
      listing = %{
        "data" => [
          model("claude-opus-5-5", enabled: false, adaptive: true),
          model("claude-opus-4-6", enabled: true, adaptive: true),
          model("claude-haiku-4-5-20251001", enabled: true, adaptive: false),
          %{"id" => "claude-older", "max_input_tokens" => 200_000, "max_tokens" => 8_192}
        ]
      }

      forms = :anthropic |> Catalog.parse(listing) |> Map.new(&{&1.id, &1.thinking})

      assert forms == %{
               "claude-opus-5-5" => :adaptive,
               "claude-opus-4-6" => :budget,
               "claude-haiku-4-5-20251001" => :budget,
               "claude-older" => nil
             }

      for entry <- Catalog.parse(:anthropic, listing) do
        assert Catalog.from_map(
                 entry.id,
                 entry |> Catalog.to_map() |> Jason.encode!() |> Jason.decode!()
               ) == entry
      end
    end

    test "what the list says wins over the name, and the name over the kind of value" do
      assert sent(%{request("claude-opus-5-5", "medium") | thinking: :budget})["thinking"] ==
               %{"type" => "enabled", "budget_tokens" => 8_192}

      assert sent(%{request("house-model", "12000") | thinking: :adaptive})["output_config"] ==
               %{"effort" => "high"}

      assert sent(%{request("claude-opus-5-5", "12000") | thinking: nil})["output_config"] ==
               %{"effort" => "high"}
    end

    test "a refusal of a form the list or the name chose names only the effort" do
      refusal = ~s("thinking.type.enabled" is not supported for this model.)
      assert {:error, reason} = run(request("claude-opus-4-6", "medium", fail: refusal))
      described = Provider.describe_error(reason)

      assert described =~
               "claude-opus-4-6 refused a thinking budget of 8192 tokens, which reasoning_effort medium asks for"

      assert described =~ "remove reasoning_effort from the model's models: entry"
      refute described =~ "a level sends"
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp model(id, enabled: enabled, adaptive: adaptive) do
    %{
      "id" => id,
      "max_input_tokens" => 1_000_000,
      "max_tokens" => 128_000,
      "capabilities" => %{
        "thinking" => %{
          "supported" => true,
          "types" => %{
            "enabled" => %{"supported" => enabled},
            "adaptive" => %{"supported" => adaptive}
          }
        }
      }
    }
  end

  defp sent(model, effort), do: sent(request(model, effort))

  defp sent(%Request{} = request) do
    assert {:ok, _response} = run(request)
    [sent] = FakeTransport.drain_requests()
    FakeTransport.body(sent)
  end

  defp run(request) do
    ref = make_ref()
    :ok = Anthropic.stream(request, self(), ref)

    receive do
      {:llm_done, ^ref, response} -> {:ok, response}
      {:llm_error, ^ref, reason} -> {:error, reason}
    after
      15_000 -> {:error, :timeout}
    end
  end

  defp request(model, effort, opts \\ []) do
    transport =
      case Keyword.get(opts, :fail) do
        nil ->
          FakeTransport.adapter(chunks: text_only(), record: self())

        refusal ->
          FakeTransport.adapter(
            fail_first: 99,
            fail_status: 400,
            fail_body: refusal,
            record: self()
          )
      end

    %Request{
      model: model,
      messages: [Message.user("hello")],
      system: "You are a test.",
      api_key: "test-key",
      reasoning_effort: effort,
      max_retries: 0,
      timeout_ms: 10_000,
      extra: %{req_adapter: transport}
    }
  end

  defp text_only do
    [
      ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}\n\n),
      ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n),
      ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello."}}\n\n),
      ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n)
    ]
  end
end
