defmodule Troupe.Config.KeyProblemTest do
  @moduledoc """
  Whether the default model can be asked at all, and what the report says when it cannot.

  A fresh machine has the defaults — `anthropic`, `claude-sonnet-5` — and no key, and
  `troupe-daemon config` used to say `key=(none)` and `no key` and stop there. The key a
  request would carry is the provider's own, or the vendor's variable at the vendor's own
  endpoint (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), and the report now says which, and
  ends with the one next step when there is none.

  `async: false`: the vendor variables and the config directory are process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config

  @vars ~w(ANTHROPIC_API_KEY OPENAI_API_KEY TROUPE_CONFIG_HOME)

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(~w(ANTHROPIC_API_KEY OPENAI_API_KEY), &System.delete_env/1)

    home = Path.join(System.tmp_dir!(), "troupe-key-problem-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("TROUPE_CONFIG_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)

      Enum.each(previous, fn {var, value} ->
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end)
    end)
  end

  describe "key_problem/1" do
    test "the defaults, with nothing in the environment, have no key" do
      assert Config.key_problem(%Config{}) == {:no_key, "anthropic"}
    end

    test "ANTHROPIC_API_KEY stands in for a key at Anthropic's own endpoint" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-the-environment")
      assert Config.key_problem(%Config{}) == nil
    end

    test "but never at a gateway in front of Anthropic, which is sent no key it was not given" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-the-environment")

      assert Config.key_problem(%Config{base_url: "https://llm-gw.example/anthropic/v1"}) ==
               {:no_key, "anthropic"}
    end

    test "a key of the provider's own is a key" do
      assert Config.key_problem(%Config{api_key: "sk-ant-in-the-file"}) == nil
    end

    test "OpenAI's own endpoint wants OPENAI_API_KEY; an OpenAI-compatible gateway may want none" do
      assert Config.key_problem(%Config{provider: "openai", model: "gpt-5"}) == {:no_key, "openai"}

      assert Config.key_problem(%Config{provider: "openai", model: "qwen3", base_url: "http://localhost:8000/v1"}) ==
               nil
    end

    test "the fake provider asks nobody" do
      assert Config.key_problem(%Config{provider: "fake"}) == nil
    end

    test "a named provider is judged by its own key, and named in the answer" do
      config = %Config{model: "gw/claude-opus-5", providers: %{"gw" => provider(:anthropic, "https://gw.example/v1", nil)}}
      assert Config.key_problem(config) == {:no_key, "gw"}

      keyed = put_in(config.providers["gw"].api_key, "gw-key-1234567890")
      assert Config.key_problem(keyed) == nil
    end

    test "a provider refused for an unset variable says why" do
      why = "api_key reads {env:NOPE}, and NOPE is not set; the session-wide provider is refused until it is"
      assert Config.key_problem(%Config{refused: why}) == {:refused, why}
    end
  end

  describe "describe/1" do
    test "with no key, it ends with the next step and the simplest file" do
      report = Config.describe(%Config{})

      assert report =~ "key=(none)"
      assert report =~ "no key"
      assert report =~ "next step: anthropic has no key, so no model can be asked. Run `troupe config` to set up a provider."
      assert report =~ ~s(provider: anthropic\n    api_key: "{env:ANTHROPIC_API_KEY}")
      # The simplest case before the gateways.
      assert :binary.match(report, "provider: anthropic\n") < :binary.match(report, "gateway such as LiteLLM")
    end

    test "a key from the environment is named, and there is no next step" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-from-the-environment")
      report = Config.describe(%Config{})

      assert report =~ "key=(ANTHROPIC_API_KEY)"
      refute report =~ "no key"
      refute report =~ "next step"
      refute report =~ "sk-ant-from-the-environment"
    end

    test "a refused provider points at the warning that says why" do
      why = "api_key reads {env:NOPE}, and NOPE is not set; the session-wide provider is refused until it is"
      report = Config.describe(%Config{refused: why, warnings: [why]})

      assert report =~ "key=(refused)"
      assert report =~ "next step: the default model's provider is refused"
    end
  end

  defp provider(type, base_url, key),
    do: %{type: type, base_url: base_url, api_key: key, auth: :api_key, models: %{}, source: :yaml, refused: nil}
end
