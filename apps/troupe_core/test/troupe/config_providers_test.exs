defmodule Troupe.ConfigProvidersTest do
  @moduledoc """
  A laptop's configuration: named providers, opencode's providers when Troupe has no
  key of its own, and the model catalog — the three things a pod never has and a
  person always does.

  `async: false` because the opencode and catalog paths are found through the
  environment, and two tests pointing them at two directories at once would read each
  other's files.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.{JSONC, OpenCode}
  alias Troupe.LLM.Catalog

  @opencode """
  {
    // comment with a "quoted" word and a trailing, comma below
    "model": "portal/glm-5.2",
    "provider": {
      "portal": {
        "options": { "baseURL": "https://llm-gw.example/v1", },
        "models": {
          "glm-5.2": { "limit": { "context": 100000, "output": 16384 } },
          "qwen": { "limit": { "context": 50000 } }
        }
      },
      "gateway": {
        "npm": "@ai-sdk/anthropic",
        "options": { "baseURL": "https://gw.example/anthropic/v1", "authToken": "gw-token-1234567890" },
        "models": {
          "claude-opus-5": { "id": "eu.anthropic.claude-opus-5", "limit": { "context": 400000, "output": 64000 } }
        }
      },
    },
  }
  """

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-laptop-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    config_home = Path.join(base, "config")
    opencode = Path.join(base, "opencode")
    File.mkdir_p!(Path.join(workspace, ".troupe"))
    File.mkdir_p!(config_home)
    File.mkdir_p!(opencode)

    # Nothing here may read the developer's real files: their config, their opencode
    # installation, their catalog cache. Every path a laptop config reaches is pointed
    # at this test's directory, and an absent file is the normal case a pod sees.
    previous = for k <- ~w(TROUPE_CONFIG_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_MODEL TROUPE_API_KEY TROUPE_AUTH_TOKEN), into: %{}, do: {k, System.get_env(k)}
    System.put_env("TROUPE_CONFIG_HOME", config_home)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(opencode, "opencode.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(opencode, "auth.json"))
    System.delete_env("TROUPE_MODEL")
    System.delete_env("TROUPE_API_KEY")
    System.delete_env("TROUPE_AUTH_TOKEN")

    on_exit(fn ->
      Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
      File.rm_rf!(base)
    end)

    %{workspace: workspace, config_home: config_home, opencode: opencode}
  end

  describe "named providers" do
    setup %{workspace: workspace} do
      File.write!(Path.join(workspace, ".troupe/config.yaml"), """
      api_key: session-key-1234567890
      providers:
        gateway:
          type: anthropic
          base_url: https://gw.example/anthropic/v1
          auth_token: gw-token-1234567890
          models:
            claude-opus-5:
              id: eu.anthropic.claude-opus-5
              context: 400000
              max_output: 64000
        local:
          base_url: http://localhost:11434/v1
      models:
        default: gateway/claude-opus-5
        cheap: gateway/claude-haiku-4-5
        windows:
          some-bare-model: 128000
      """)

      %{config: Config.load(workspace)}
    end

    test "a provider/model id resolves to that provider's url, key, scheme and wire id", %{config: config} do
      target = Config.target(config, "gateway/claude-opus-5")

      assert target.provider == "anthropic"
      assert target.model == "eu.anthropic.claude-opus-5"
      assert target.base_url == "https://gw.example/anthropic/v1"
      assert target.api_key == "gw-token-1234567890"
      assert target.auth == :bearer
      assert target.max_output == 64_000
    end

    test "a model the provider does not list still goes to it, under its own name", %{config: config} do
      target = Config.target(config, "gateway/claude-haiku-4-5")
      assert target.model == "claude-haiku-4-5"
      assert target.base_url == "https://gw.example/anthropic/v1"
      assert target.max_output == nil
    end

    test "a bare id goes to the session-wide provider with the session-wide key", %{config: config} do
      target = Config.target(config, "claude-sonnet-5")
      assert target == %{
               provider: "anthropic",
               model: "claude-sonnet-5",
               base_url: nil,
               api_key: "session-key-1234567890",
               auth: :api_key,
               max_output: nil,
               reasoning_effort: nil
             }
    end

    test "the models block sets the aliases and nil means the default", %{config: config} do
      assert config.model == "gateway/claude-opus-5"
      assert config.small_model == "gateway/claude-haiku-4-5"
      assert Config.resolve_model(config, :expensive) == "gateway/claude-opus-5"
      assert Config.target(config, nil).model == "eu.anthropic.claude-opus-5"
    end

    test "the window is the provider's declaration, then the hand-written one, then the default", %{config: config} do
      assert Config.context_window(config, "gateway/claude-opus-5") == 400_000
      assert Config.context_window(config, "some-bare-model") == 128_000
      assert Config.context_window(config, "anything-else") == config.context_window
      assert Config.compact_threshold(config, "gateway/claude-opus-5") == trunc(400_000 * config.compact_at)
    end

    test "every model a provider declares is addressable, and the report never shows a token", %{config: config} do
      ids = config |> Config.models() |> Enum.map(& &1.id)
      assert "gateway/claude-opus-5" in ids
      assert "gateway/claude-haiku-4-5" in ids
      assert "local/" in ids
      assert "some-bare-model" in ids

      report = Config.describe(config)
      assert report =~ "claude-opus-5->eu.anthropic.claude-opus-5"
      assert report =~ "auth=bearer"
      refute report =~ "gw-token-1234567890"
      refute report =~ "session-key-1234567890"
    end
  end

  describe "auth scheme" do
    test "TROUPE_AUTH_TOKEN is the session key sent as a bearer token", %{workspace: workspace} do
      System.put_env("TROUPE_AUTH_TOKEN", "tok-1234567890")
      config = Config.load(workspace)
      assert Config.target(config, nil) |> Map.take([:api_key, :auth]) == %{api_key: "tok-1234567890", auth: :bearer}
    end

    test "auth_token in a file says bearer by itself", %{workspace: workspace} do
      File.write!(Path.join(workspace, ".troupe/config.yaml"), "auth_token: file-token-123456\n")
      config = Config.load(workspace)
      assert {config.api_key, config.auth} == {"file-token-123456", :bearer}
    end
  end

  describe "opencode" do
    setup %{opencode: opencode} do
      File.write!(Path.join(opencode, "opencode.jsonc"), @opencode)
      File.write!(Path.join(opencode, "auth.json"), Jason.encode!(%{"portal" => %{"type" => "api", "key" => "portal-key-from-auth"}}))
      :ok
    end

    test "JSONC strips comments and trailing commas but not inside strings" do
      assert {:ok, %{"a" => "x // not a comment", "b" => [1, 2]}} =
               JSONC.decode(~s({"a": "x // not a comment", /* c */ "b": [1, 2,], } // end))
    end

    test "providers come from opencode.jsonc with keys from auth.json and windows from limits" do
      providers = OpenCode.providers()
      assert providers["portal"].api_key == "portal-key-from-auth"
      assert providers["portal"].base_url == "https://llm-gw.example/v1"
      assert Map.get(providers["portal"].models, "glm-5.2").context == 100_000
      assert providers["gateway"].type == :anthropic
      assert providers["gateway"].auth == :bearer
      assert Map.get(providers["gateway"].models, "claude-opus-5").id == "eu.anthropic.claude-opus-5"
      assert OpenCode.default_model() == "portal/glm-5.2"
    end

    test "with no key of its own Troupe takes opencode's providers and its default model", %{workspace: workspace} do
      config = Config.load(workspace)

      assert config.model == "portal/glm-5.2"
      assert config.providers["portal"].source == :opencode
      assert Config.target(config, nil) |> Map.take([:provider, :model, :base_url, :api_key]) ==
               %{provider: "openai", model: "glm-5.2", base_url: "https://llm-gw.example/v1", api_key: "portal-key-from-auth"}
    end

    test "a model named in a file or the environment is not displaced by opencode's", %{workspace: workspace} do
      File.write!(Path.join(workspace, ".troupe/config.yaml"), "model: gateway/claude-opus-5\n")
      assert Config.load(workspace).model == "gateway/claude-opus-5"

      System.put_env("TROUPE_MODEL", "claude-sonnet-5")
      assert Config.load(workspace).model == "claude-sonnet-5"
    end

    test "a session key of its own means opencode is not consulted", %{workspace: workspace} do
      System.put_env("TROUPE_API_KEY", "own-key-1234567890")
      config = Config.load(workspace)
      assert config.providers == %{}
      assert config.model == "claude-sonnet-5"
    end

    test "a config file's provider of the same name wins over opencode's", %{workspace: workspace} do
      File.write!(Path.join(workspace, ".troupe/config.yaml"), """
      providers:
        portal:
          base_url: https://mine.example/v1
          api_key: my-portal-key-12345
      """)

      config = Config.load(workspace)
      assert config.providers["portal"].source == :yaml
      assert config.providers["gateway"].source == :opencode
      assert Config.target(config, "portal/glm-5.2").base_url == "https://mine.example/v1"
    end
  end

  describe "the catalog" do
    test "fills the window the config did not declare, and never overrides one it did", %{workspace: workspace, config_home: config_home} do
      File.write!(Path.join(config_home, "models.json"), Jason.encode!(%{
        "fetched_at" => "2026-09-19T12:00:00Z",
        "models" => %{
          "gw/glm" => %{"context" => 200_000, "input" => 0.0000005, "output" => 0.0000015},
          "declared" => %{"context" => 999_999}
        }
      }))

      File.write!(Path.join(workspace, ".troupe/config.yaml"), """
      api_key: k-1234567890
      models:
        windows:
          declared: 32000
      """)

      config = Config.load(workspace)
      assert Config.context_window(config, "gw/glm") == 200_000
      assert Config.context_window(config, "declared") == 32_000

      choice = config |> Config.models() |> Enum.find(&(&1.id == "gw/glm"))
      assert choice.source == :catalog
      assert choice.price == "$0.50/$1.50"
      assert Catalog.Store.fetched_at() == "2026-09-19T12:00:00Z"
    end

    test "no cache file, or a corrupt one, is an empty catalog rather than a failed load", %{workspace: workspace, config_home: config_home} do
      assert Config.load(workspace).catalog == %{}
      File.write!(Path.join(config_home, "models.json"), "{not json")
      assert Config.load(workspace).catalog == %{}
    end

    test "parses the three listing shapes" do
      assert [%Catalog{id: "claude-sonnet-5", context: 200_000, max_output: 64_000}] =
               Catalog.parse(:anthropic, %{"data" => [%{"id" => "claude-sonnet-5", "max_input_tokens" => 200_000, "max_tokens" => 64_000}]})

      assert [%Catalog{id: "glm", context: 250_000, input: 5.0e-7}] =
               Catalog.parse(:litellm, %{
                 "data" => [
                   %{"model_group" => "glm", "mode" => "chat", "max_input_tokens" => 250_000.0, "input_cost_per_token" => 5.0e-7, "output_cost_per_token" => 1.5e-6},
                   %{"model_group" => "embed", "mode" => "embedding", "max_input_tokens" => 8000},
                   %{"model_group" => "*", "mode" => "chat"}
                 ]
               })

      assert [%Catalog{id: "plain", context: nil}] = Catalog.parse(:openai, %{"data" => [%{"id" => "plain"}]})
      assert Catalog.qualify([%Catalog{id: "glm"}], "portal") == [%Catalog{id: "portal/glm"}]
    end
  end
end
