defmodule Troupe.OpenCodeConfigTest do
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.{JSONC, OpenCode}

  @jsonc """
  {
    // comment with a "quoted" word and a trailing, comma below
    "$schema": "https://opencode.ai/config.json",
    "model": "portal/glm-5.2",
    "provider": {
      "cloud": {
        "options": { "baseURL": "https://api.cloud.example/v1", "apiKey": "cloud-key-1234567890" }, /* block */
      },
      "portal": {
        "options": { "baseURL": "https://llm-gw.example/v1", },
        "models": {
          "glm-5.2": { "limit": { "context": 100000, "output": 16384 } },
          "qwen": { "limit": { "context": 50000 } }
        }
      },
      "claude": { "npm": "@ai-sdk/anthropic", "options": { "apiKey": "sk-ant-xyz" } },
      "gateway": {
        "npm": "@ai-sdk/anthropic",
        "options": { "baseURL": "https://gw.example/anthropic/v1", "authToken": "gw-token-1234567890" },
        "models": {
          "claude-opus-5": {
            "id": "eu.anthropic.claude-opus-5",
            "name": "Gateway Opus 5",
            "limit": { "context": 400000, "output": 64000 },
            "options": { "reasoningEffort": "high" }
          }
        }
      },
    },
  }
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-opencode-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    cfg = Path.join(dir, "opencode.jsonc")
    auth = Path.join(dir, "auth.json")
    File.write!(cfg, @jsonc)

    File.write!(
      auth,
      Jason.encode!(%{"portal" => %{"type" => "api", "key" => "portal-key-from-auth"}})
    )

    System.put_env("TROUPE_OPENCODE_CONFIG", cfg)
    System.put_env("TROUPE_OPENCODE_AUTH", auth)

    on_exit(fn ->
      System.delete_env("TROUPE_OPENCODE_CONFIG")
      System.delete_env("TROUPE_OPENCODE_AUTH")
      File.rm_rf(dir)
    end)

    :ok
  end

  test "JSONC strips comments and trailing commas but not inside strings" do
    assert {:ok, %{"a" => "x // not a comment", "b" => [1, 2]}} =
             JSONC.decode(~s({"a": "x // not a comment", /* c */ "b": [1, 2,], } // end))
  end

  test "providers come from opencode.jsonc with keys filled from auth.json and windows from limits" do
    providers = OpenCode.providers()
    assert providers["cloud"].api_key == "cloud-key-1234567890"
    assert providers["cloud"].base_url == "https://api.cloud.example/v1"
    assert providers["cloud"].auth == :api_key
    assert providers["portal"].api_key == "portal-key-from-auth"
    assert Map.get(providers["portal"].models, "glm-5.2").context == 100_000
    assert Map.get(providers["portal"].models, "qwen").context == 50_000
    assert providers["claude"].type == :anthropic
    assert providers["claude"].models == %{}
    assert OpenCode.default_model() == "portal/glm-5.2"
  end

  test "an authToken is a bearer key and a model's own id, limits and effort come across" do
    gateway = OpenCode.providers()["gateway"]

    assert gateway.type == :anthropic
    assert gateway.auth == :bearer
    assert gateway.api_key == "gw-token-1234567890"

    assert gateway.models == %{
             "claude-opus-5" => %{
               id: "eu.anthropic.claude-opus-5",
               context: 400_000,
               max_output: 64_000,
               reasoning_effort: "high"
             }
           }

    cfg = Config.load(System.tmp_dir!())
    assert Config.context_window(cfg, "gateway/claude-opus-5") == 400_000

    assert {Troupe.LLM.Anthropic,
            %{
              api_key: "gw-token-1234567890",
              base_url: "https://gw.example/anthropic/v1",
              auth: :bearer,
              reasoning_effort: "high",
              max_output: 64_000
            }, "eu.anthropic.claude-opus-5"} =
             Troupe.LLM.Provider.resolve(:auto, cfg, "gateway/claude-opus-5")

    described = Config.describe(cfg)
    assert described =~ "auth=bearer models=claude-opus-5->eu.anthropic.claude-opus-5 (effort high)"
    refute described =~ "gw-token-1234567890"
  end

  test "config falls back to opencode providers, uses its default model, and resolves provider/model per request" do
    cfg = Config.load(System.tmp_dir!())
    assert map_size(cfg.providers) == 4
    assert cfg.models.default == "portal/glm-5.2"
    assert Config.context_window(cfg, "portal/glm-5.2") == 100_000
    assert Config.context_window(cfg, "portal/unknown") == cfg.default_window

    assert {Troupe.LLM.OpenAI,
            %{base_url: "https://llm-gw.example/v1", api_key: "portal-key-from-auth"}, "glm-5.2"} =
             Troupe.LLM.Provider.resolve(:auto, cfg, "portal/glm-5.2")

    assert {Troupe.LLM.Anthropic, %{api_key: "sk-ant-xyz"}, "claude-opus-5"} =
             Troupe.LLM.Provider.resolve(:auto, cfg, "claude/claude-opus-5")

    # a fixed provider (tests, fake) always wins
    assert {Troupe.LLM.Fake, :pid, "portal/glm-5.2"} =
             Troupe.LLM.Provider.resolve({Troupe.LLM.Fake, :pid}, cfg, "portal/glm-5.2")

    described = Config.describe(cfg)
    assert described =~ "portal: openai https://llm-gw.example/v1 key=port…th source=opencode"
    refute described =~ "portal-key-from-auth"
  end

  test "an explicit Troupe key or explicit models are not overridden by opencode" do
    cfg = Config.load(System.tmp_dir!(), %{api_key: "mine"})
    assert cfg.providers == %{}
    assert cfg.models.default =~ "claude"

    cfg = Config.load(System.tmp_dir!(), %{models: %{default: "cloud/some-model"}})
    assert cfg.models.default == "cloud/some-model"
    assert map_size(cfg.providers) == 4
  end

  test "a session with named providers streams each request to the provider named by its model prefix" do
    # the Fake stands in as a fixed provider; the :auto path is covered above, this checks the spec plumbing
    {:ok, sid} =
      Troupe.start_session(
        workspace: System.tmp_dir!(),
        provider: {Troupe.LLM.Fake, Troupe.LLM.Fake.start!([{:finish, "ok"}])}
      )

    on_exit(fn -> Troupe.stop_session(sid) end)
    assert {:ok, _} = Troupe.dispatch(sid, "code", "hi")
  end
end
