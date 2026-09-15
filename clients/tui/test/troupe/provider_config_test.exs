defmodule Troupe.ProviderConfigTest do
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.LLM.{Anthropic, HTTP, OpenAI, Provider, Request}

  # A gateway that speaks both provider APIs behind its own model names, keyed
  # with a bearer token: the shape opencode writes as `authToken` + `models.<x>.id`.
  @yaml ~s"""
  providers:
    lego-anthropic:
      type: anthropic
      base_url: https://gw.example/anthropic/v1
      auth_token: lego-token-1234567890
      models:
        claude-opus-5:
          id: "eu.anthropic.claude-opus-5"
          context: 400000
          max_output: 64000
          reasoning_effort: medium
        claude-haiku-4-5:
          id: "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
    lego-openai:
      base_url: https://gw.example/openai/v1
      api_key: openai-key-1234567890
      models:
        gpt-5-6-terra:
          id: "gpt-5.6-terra-2026-07-09"
          reasoning_effort: none
  models:
    default: lego-anthropic/claude-opus-5
    cheap: lego-openai/gpt-5-6-terra
  """

  setup do
    ws = Path.join(System.tmp_dir!(), "troupe-provider-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    File.write!(Path.join([ws, ".troupe", "config.yaml"]), @yaml)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{config: Config.load(ws)}
  end

  test "a named provider hands the adapter its wire id, auth scheme and effort", %{config: cfg} do
    assert {Anthropic,
            %{
              api_key: "lego-token-1234567890",
              base_url: "https://gw.example/anthropic/v1",
              auth: :bearer,
              reasoning_effort: "medium",
              max_output: 64_000
            }, "eu.anthropic.claude-opus-5"} =
             Provider.resolve(:auto, cfg, "lego-anthropic/claude-opus-5")

    assert {OpenAI, %{auth: :api_key, reasoning_effort: "none", max_output: nil},
            "gpt-5.6-terra-2026-07-09"} =
             Provider.resolve(:auto, cfg, "lego-openai/gpt-5-6-terra")

    # a model the provider does not list goes out as typed, with nothing added
    assert {Anthropic, %{reasoning_effort: nil}, "some-other-model"} =
             Provider.resolve(:auto, cfg, "lego-anthropic/some-other-model")
  end

  test "every model a provider declares is addressable, window and all", %{config: cfg} do
    ids = Enum.map(Config.models(cfg), & &1.id)

    assert "lego-anthropic/claude-opus-5" in ids
    assert "lego-anthropic/claude-haiku-4-5" in ids
    assert "lego-openai/gpt-5-6-terra" in ids

    assert Config.context_window(cfg, "lego-anthropic/claude-opus-5") == 400_000
    assert Config.context_window(cfg, "lego-anthropic/claude-haiku-4-5") == cfg.default_window
    assert Config.model_spec(cfg, "lego-openai/gpt-5-6-terra").reasoning_effort == "none"
    assert Config.model_spec(cfg, "claude-sonnet-5") == nil
  end

  test "troupe config shows the renamed model and the auth scheme, never the token", %{
    config: cfg
  } do
    described = Config.describe(cfg)

    assert described =~ "lego-anthropic: anthropic https://gw.example/anthropic/v1"
    assert described =~ "auth=bearer"
    assert described =~ "claude-opus-5->eu.anthropic.claude-opus-5 (effort medium)"
    refute described =~ "lego-token-1234567890"
    refute described =~ "openai-key-1234567890"
  end

  test "a base url that already names the api version is not doubled" do
    assert HTTP.api_url("https://gw.example/anthropic/v1", "/v1/messages") ==
             "https://gw.example/anthropic/v1/messages"

    assert HTTP.api_url("https://gw.example/anthropic/v1/", "/v1/messages") ==
             "https://gw.example/anthropic/v1/messages"

    assert HTTP.api_url("https://api.anthropic.com", "/v1/messages") ==
             "https://api.anthropic.com/v1/messages"

    assert HTTP.api_url("https://gw.example/openai/v1", "/chat/completions") ==
             "https://gw.example/openai/v1/chat/completions"

    assert HTTP.api_url("https://gw.example/anthropic/v1", "/v1/models") ==
             "https://gw.example/anthropic/v1/models"
  end

  test "an anthropic request asks for thinking inside an output cap that fits it" do
    request = %Request{model: "claude-opus-5", max_tokens: 8_192}

    assert Anthropic.encode(request) == Anthropic.encode(request, %{})
    refute Map.has_key?(Anthropic.encode(request, %{reasoning_effort: "none"}), :thinking)

    body = Anthropic.encode(request, %{reasoning_effort: "medium"})
    assert body.thinking == %{type: "enabled", budget_tokens: 8_192}
    assert body.max_tokens == 12_288

    body = Anthropic.encode(request, %{reasoning_effort: "xhigh", max_output: 64_000})
    assert body.thinking == %{type: "enabled", budget_tokens: 32_768}
    assert body.max_tokens == 64_000

    assert Anthropic.encode(request, %{max_output: 32_000}).max_tokens == 32_000
  end

  test "an openai reasoning model gets the effort verbatim and a completion-token cap" do
    request = %Request{model: "gpt-5-6-terra", max_tokens: 8_192, system: "s"}

    plain = OpenAI.encode(request)
    assert plain.max_tokens == 8_192
    refute Map.has_key?(plain, :reasoning_effort)

    body = OpenAI.encode(request, %{reasoning_effort: "none", max_output: 32_000})
    assert body.reasoning_effort == "none"
    assert body.max_completion_tokens == 32_000
    refute Map.has_key?(body, :max_tokens)
  end

  test "a model that refuses max_tokens is asked again with max_completion_tokens" do
    body = OpenAI.encode(%Request{model: "gpt-5-5", max_tokens: 8_192})

    refused =
      ~s({"error": {"message": "Unsupported parameter: 'max_tokens' is not supported with ) <>
        ~s(this model. Use 'max_completion_tokens' instead.", "param": "max_tokens"}})

    retry = OpenAI.output_cap_retry(body, refused)
    assert retry.max_completion_tokens == 8_192
    refute Map.has_key?(retry, :max_tokens)

    # and back the other way, for a server that only knows max_tokens
    reverse = ~s({"error": {"message": "unknown field max_completion_tokens; use max_tokens"}})
    assert OpenAI.output_cap_retry(retry, reverse).max_tokens == 8_192
    refute Map.has_key?(OpenAI.output_cap_retry(retry, reverse), :max_completion_tokens)

    # every other 400 is the caller's problem, not a field to swap
    assert OpenAI.output_cap_retry(body, "context length exceeded") == nil
    assert OpenAI.output_cap_retry(body, nil) == nil
  end

  test "the session-wide provider can send its key as a bearer token" do
    ws = Path.join(System.tmp_dir!(), "troupe-session-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(ws, ".troupe"))

    File.write!(Path.join([ws, ".troupe", "config.yaml"]), ~s"""
    provider: anthropic
    base_url: https://gw.example/anthropic/v1
    auth_token: session-token-1234567890
    """)

    on_exit(fn -> File.rm_rf!(ws) end)
    cfg = Config.load(ws)

    assert cfg.auth == :bearer
    assert cfg.api_key == "session-token-1234567890"

    assert {Anthropic, %{auth: :bearer, api_key: "session-token-1234567890"}} =
             Provider.from_config(cfg)

    # a key of its own means opencode's providers are not consulted at all
    assert cfg.providers == %{}
    assert Config.describe(cfg) =~ "auth=bearer"
  end
end
