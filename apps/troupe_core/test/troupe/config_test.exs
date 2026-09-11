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

    test "an unrecognised key is kept rather than crashing the load", %{root: root} do
      # A key that is not an existing atom used to raise from `nil && ...`, taking the
      # whole config load with it — so a typo, or a key from a newer version, made
      # Troupe unstartable.
      File.write!(Path.join(root, ".troupe/config.yaml"), """
      some_future_key: a value
      model: still-read
      """)

      config = Config.load(root)
      assert config.extra["some_future_key"] == "a value"
      assert config.model == "still-read"
    end

    test "a missing file is not an error", %{root: root} do
      assert %Config{} = Config.load(root)
    end
  end
end
