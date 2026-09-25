defmodule Troupe.ConfigTest do
  @moduledoc """
  Configuration layering and `{env:VAR}` interpolation.

  The interpolation tests matter more than they look: this is the code that decides
  whether a credential reaches a provider, and the failure mode of getting it wrong is
  sending the literal string `{env:MY_KEY}` upstream as a bearer token.
  """

  use ExUnit.Case, async: true

  alias Troupe.Config

  describe "{env:VAR} interpolation" do
    setup do
      System.put_env("TROUPE_TEST_SECRET", "s3cret-value")
      on_exit(fn -> System.delete_env("TROUPE_TEST_SECRET") end)
      :ok
    end

    test "substitutes a set variable" do
      assert Config.interpolate("{env:TROUPE_TEST_SECRET}") == "s3cret-value"
    end

    test "substitutes inside a larger string" do
      assert Config.interpolate("Bearer {env:TROUPE_TEST_SECRET}!") == "Bearer s3cret-value!"
    end

    test "an unset variable becomes empty, never the literal placeholder" do
      assert Config.interpolate("{env:TROUPE_DEFINITELY_UNSET}") == ""
      refute Config.interpolate("{env:TROUPE_DEFINITELY_UNSET}") =~ "env:"
    end

    test "walks maps and lists" do
      assert Config.interpolate(%{"api_key" => "{env:TROUPE_TEST_SECRET}", "n" => 1}) ==
               %{"api_key" => "s3cret-value", "n" => 1}

      assert Config.interpolate(["a", "{env:TROUPE_TEST_SECRET}"]) == ["a", "s3cret-value"]
    end

    test "leaves non-strings and ordinary strings alone" do
      assert Config.interpolate(42) == 42
      assert Config.interpolate(true) == true
      assert Config.interpolate("https://example.com/v1") == "https://example.com/v1"
    end

    test "handles several references in one value" do
      System.put_env("TROUPE_TEST_HOST", "gateway.example")

      on_exit(fn -> System.delete_env("TROUPE_TEST_HOST") end)

      assert Config.interpolate("https://{env:TROUPE_TEST_HOST}/{env:TROUPE_TEST_SECRET}") ==
               "https://gateway.example/s3cret-value"
    end
  end

  describe "layering" do
    setup do
      root = Path.join(System.tmp_dir!(), "troupe-config-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, ".troupe"))
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "a project file overrides defaults, and overrides are applied last", %{root: root} do
      File.write!(Path.join(root, ".troupe/config.yaml"), """
      provider: openai
      model: from-project
      max_turns: 7
      """)

      config = Config.load(root)
      assert config.provider == "openai"
      assert config.model == "from-project"
      assert config.max_turns == 7

      # Explicit options win over every file.
      assert Config.load(root, model: "from-caller").model == "from-caller"
    end

    test "a project file reads a secret from the environment", %{root: root} do
      System.put_env("TROUPE_TEST_SECRET", "s3cret-value")
      on_exit(fn -> System.delete_env("TROUPE_TEST_SECRET") end)

      File.write!(Path.join(root, ".troupe/config.yaml"), """
      provider: openai
      api_key: "{env:TROUPE_TEST_SECRET}"
      """)

      assert Config.load(root).api_key == "s3cret-value"
    end

    test "an unrecognised key warns rather than crashing the load, and an x- key is kept", %{root: root} do
      # A key that is not an existing atom used to raise from `nil && ...`, taking the
      # whole config load with it — so a typo, or a key from a newer version, made
      # Troupe unstartable.
      File.write!(Path.join(root, ".troupe/config.yaml"), """
      some_future_key: a value
      x-team-note: kept for another tool
      models:
        default: still-read
      """)

      config = Config.load(root)
      assert config.model == "still-read"
      assert config.extra == %{"x-team-note" => "kept for another tool"}
      assert [warning] = config.warnings
      assert warning =~ ".troupe/config.yaml:1: some_future_key is not a setting Troupe knows, and is ignored"
    end

    test "a missing file is not an error", %{root: root} do
      assert %Config{} = Config.load(root)
    end
  end

  # Seven of the shipped profiles name a model by alias — `cheap` for the librarian, the
  # answerer and `quick`, `expensive` for a workflow. `resolve_model/2` knew what those
  # meant and nothing called it, so the alias went out as the model id: LiteLLM answered
  # 401 ("the provider rejected the credentials") and Anthropic would answer 404, while
  # the root agent, which names no model, worked.
  describe "a model alias" do
    setup do
      %{
        config: %Config{
          provider: "openai",
          model: "big-model",
          small_model: "small-model",
          expensive_model: "premium-model"
        }
      }
    end

    test "is resolved before the request is aimed", %{config: config} do
      assert Config.target(config, "cheap").model == "small-model"
      assert Config.target(config, "small").model == "small-model"
      assert Config.target(config, "default").model == "big-model"
      assert Config.target(config, "expensive").model == "premium-model"
    end

    test "that is really a model id is itself, and no model is the default", %{config: config} do
      assert Config.target(config, "qwen3-235b").model == "qwen3-235b"
      assert Config.target(config, nil).model == "big-model"
    end

    test "falls back to the default model when that tier is unset" do
      config = %Config{provider: "openai", model: "only-model"}

      assert Config.target(config, "cheap").model == "only-model"
      assert Config.target(config, "expensive").model == "only-model"
    end

    test "is resolved for the context window too, so compaction plans against the right one" do
      config = %Config{
        provider: "openai",
        model: "big-model",
        small_model: "small-model",
        windows: %{"small-model" => 32_000, "big-model" => 400_000}
      }

      assert Config.context_window(config, "cheap") == 32_000
      assert Config.context_window(config, "default") == 400_000
    end
  end
end
