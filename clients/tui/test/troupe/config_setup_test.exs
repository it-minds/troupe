defmodule Troupe.ConfigSetupTest do
  @moduledoc """
  `troupe config` on a machine with no model settings: what it offers, what each answer
  sends the daemon, and that a machine that is set up, or has nobody to ask, gets no
  questions. A person and a daemon are played by functions (`ConfigSetup.io/1`'s shape),
  so nothing here reads a terminal, a file or a socket.
  """

  use ExUnit.Case, async: true

  alias Troupe.CLI.ConfigSetup

  @path "/home/me/.config/troupe/config.yaml"
  @nothing %{"exists" => false, "path" => @path, "api_key_source" => nil}

  test "a machine with a config.yaml gets the report, without asking the daemon" do
    assert ConfigSetup.run("/w", io(local_file?: true)) == 0
    assert said() == ["REPORT"]
    refute_received {:call, _, _}
  end

  test "settings in TROUPE_* variables are settings" do
    assert ConfigSetup.run("/w", io(daemon: settings(%{@nothing | "api_key_source" => "env"}))) == 0
    assert said() == ["REPORT"]
    refute_received {:ask, _}
  end

  describe "with opencode set up" do
    @opencode %{names: ["gateway", "portal"], default: "gateway/claude-opus-5"}

    test "yes copies it through config.import" do
      imported = %{
        "providers" => ["gateway", "portal"],
        "kept" => [],
        "default" => "gateway/claude-opus-5"
      }

      daemon = fn
        "config.get", _ -> {:ok, %{@nothing | "api_key_source" => "opencode"}}
        "config.import", _ -> {:ok, %{"path" => @path, "imported" => imported}}
      end

      assert ConfigSetup.run("/w", io(daemon: daemon, opencode: @opencode, answers: [""])) == 0
      assert_received {:ask, question}
      assert question =~ "Copy them into #{@path}"
      assert_received {:call, "config.import", %{"from" => "opencode", "command_id" => _}}

      text = Enum.join(said(), "\n")

      assert text =~
               "opencode is set up here, with gateway, portal (default model gateway/claude-opus-5)"

      assert text =~ "copied into #{@path}: gateway, portal"
    end

    test "no leaves opencode's config in use, and copies nothing" do
      daemon = settings(%{@nothing | "api_key_source" => "opencode"})

      assert ConfigSetup.run("/w", io(daemon: daemon, opencode: @opencode, answers: ["n"])) == 0
      refute_received {:call, "config.import", _}
      assert Enum.join(said(), "\n") =~ "keeps reading opencode's config"
    end

    test "without a terminal it says how to copy, and asks nothing" do
      daemon = settings(%{@nothing | "api_key_source" => "opencode"})

      assert ConfigSetup.run("/w", io(daemon: daemon, opencode: @opencode, interactive?: false)) ==
               0

      refute_received {:ask, _}
      assert Enum.join(said(), "\n") =~ "`troupe config` in a terminal can copy them"
    end
  end

  describe "with nothing at all" do
    test "without a terminal it names the ways on, and asks nothing" do
      assert ConfigSetup.run("/w", io(daemon: settings(@nothing), interactive?: false)) == 0
      refute_received {:ask, _}

      text = Enum.join(said(), "\n")
      assert text =~ "No model settings yet: #{@path} does not exist."
      assert text =~ "troupe login <plane-url>, then troupe config pull"
      assert text =~ "write #{@path} with a provider"
    end

    test "a plane: sign in, then take its settings" do
      answers = ["1", "https://plane.example"]
      assert ConfigSetup.run("/w", io(daemon: settings(@nothing), answers: answers)) == 0
      assert_received {:login, "https://plane.example"}
      assert_received {:pull, "https://plane.example"}
    end

    test "a provider set up here: the key's reference is saved, the model is picked from the list" do
      System.put_env("TROUPE_SETUP_TEST_KEY", "k-from-env")
      on_exit(fn -> System.delete_env("TROUPE_SETUP_TEST_KEY") end)

      daemon = fn
        "config.get", _ ->
          {:ok, @nothing}

        "config.models", _ ->
          {:ok,
           %{"models" => [%{"id" => "qwen3.6-35b"}, %{"id" => "qwen3-235b"}], "failures" => []}}

        "config.set", _ ->
          {:ok, %{"path" => @path, "api_key_set" => true}}
      end

      # choice, provider, base URL, key, default model, cheap model, save
      answers = ["2", "1", "https://llm-gw.example/v1", "{env:TROUPE_SETUP_TEST_KEY}", "2", "1", ""]
      assert ConfigSetup.run("/w", io(daemon: daemon, answers: answers)) == 0

      assert_received {:secret, _}
      # The provider is asked with the key itself...
      assert_received {:call, "config.models", %{"api_key" => "k-from-env", "provider" => "openai"}}
      # ...and the file gets the reference.
      assert_received {:call, "config.set", params}

      assert %{
               "provider" => "openai",
               "base_url" => "https://llm-gw.example/v1",
               "api_key" => "{env:TROUPE_SETUP_TEST_KEY}",
               "models" => %{"default" => "qwen3-235b", "cheap" => "qwen3.6-35b"}
             } = params

      assert Enum.join(said(), "\n") =~ "saved to #{@path}"
    end

    test "a provider that lists nothing still takes a model typed out" do
      daemon = fn
        "config.get", _ ->
          {:ok, @nothing}

        "config.models", _ ->
          {:ok,
           %{"models" => [], "failures" => [%{"provider" => "anthropic", "reason" => "no API key"}]}}

        "config.set", _ ->
          {:ok, %{"path" => @path, "api_key_set" => false}}
      end

      answers = ["2", "2", "", "", "claude-sonnet-5", "", "y"]
      assert ConfigSetup.run("/w", io(daemon: daemon, answers: answers)) == 0

      assert_received {:call, "config.set", params}
      assert params["provider"] == "anthropic"
      assert params["models"] == %{"default" => "claude-sonnet-5"}
      refute Map.has_key?(params, "api_key")
      refute Map.has_key?(params, "base_url")

      text = Enum.join(said(), "\n")
      assert text =~ "anthropic: no API key"
      assert text =~ "no key is in force yet"
    end

    test "saying no at the end saves nothing" do
      daemon = fn
        "config.get", _ -> {:ok, @nothing}
        "config.models", _ -> {:ok, %{"models" => [%{"id" => "m"}], "failures" => []}}
      end

      assert ConfigSetup.run("/w", io(daemon: daemon, answers: ["2", "1", "", "key", "", "", "n"])) ==
               1

      refute_received {:call, "config.set", _}
    end

    test "not now names the ways on" do
      assert ConfigSetup.run("/w", io(daemon: settings(@nothing), answers: ["3"])) == 0
      assert Enum.join(said(), "\n") =~ "When you are ready, either:"
    end
  end

  test "a daemon that cannot be reached still gets the report, and a failure" do
    assert ConfigSetup.run("/w", io(daemon: fn _, _ -> {:error, :econnrefused} end)) == 1
    assert ["REPORT", line] = said()
    assert line =~ "could not ask the daemon"
  end

  # -- a person and a daemon, played ------------------------------------------------

  defp settings(answer), do: fn "config.get", _ -> {:ok, answer} end

  defp io(opts) do
    test = self()
    Process.put(:answers, Keyword.get(opts, :answers, []))

    daemon =
      Keyword.get(opts, :daemon, fn _, _ -> flunk("the daemon was not expected to be asked") end)

    %{
      interactive?: Keyword.get(opts, :interactive?, true),
      say: fn line -> send(test, {:say, line}) end,
      ask: fn prompt ->
        send(test, {:ask, prompt})
        answer()
      end,
      secret: fn prompt ->
        send(test, {:secret, prompt})
        answer()
      end,
      call: fn method, params ->
        send(test, {:call, method, params})
        daemon.(method, params)
      end,
      login: fn url ->
        send(test, {:login, url})
        0
      end,
      pull: fn url ->
        send(test, {:pull, url})
        0
      end,
      describe: fn -> "REPORT" end,
      opencode: fn -> Keyword.get(opts, :opencode, %{names: [], default: nil}) end,
      local_file?: fn -> Keyword.get(opts, :local_file?, false) end
    }
  end

  defp answer do
    case Process.get(:answers) do
      [next | rest] ->
        Process.put(:answers, rest)
        next

      [] ->
        nil
    end
  end

  defp said(lines \\ []) do
    receive do
      {:say, line} -> said([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end
end
