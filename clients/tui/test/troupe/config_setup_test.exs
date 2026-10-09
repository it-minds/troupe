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
    assert ConfigSetup.run("/w", io(local_file?: true, usable?: true)) == 0
    assert said() == ["REPORT"]
    refute_received {:call, _, _}
  end

  test "a vendor's key in the environment is settings too, with no config.yaml" do
    assert ConfigSetup.run("/w", io(daemon: settings(@nothing), usable?: true)) == 0
    assert said() == ["REPORT"]
    refute_received {:ask, _}
  end

  describe "a config.yaml through which no model can be asked" do
    @file_without_key %{"exists" => true, "path" => @path, "api_key_source" => nil}

    test "gets the report, whose next step is here: the ways on follow" do
      assert ConfigSetup.run(
               "/w",
               io(local_file?: true, daemon: settings(@file_without_key), answers: ["3"])
             ) == 0

      assert_received {:ask, "choice [1]: "}

      text = Enum.join(said(), "\n")
      assert text =~ "REPORT"
      assert text =~ "How should this machine reach a model?"
      assert text =~ "When you are ready, either:"
    end

    test "without a terminal gets the report alone" do
      daemon = settings(@file_without_key)
      assert ConfigSetup.run("/w", io(local_file?: true, daemon: daemon, interactive?: false)) == 0
      assert said() == ["REPORT"]
      refute_received {:ask, _}
    end
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
      # The simplest first: a key in the environment, then a gateway, then a plane.
      assert text =~ ~s(provider: anthropic\n      api_key: "{env:ANTHROPIC_API_KEY}")
      assert position(text, "provider: anthropic") < position(text, "provider: openai")
      assert position(text, "provider: openai") < position(text, "troupe login")
    end

    test "a plane: sign in, then take its settings" do
      answers = ["2", "https://plane.example"]
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
      answers = ["1", "2", "https://llm-gw.example/v1", "{env:TROUPE_SETUP_TEST_KEY}", "2", "1", ""]
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

    # A fresh machine, answering Enter to everything: Anthropic, its own endpoint, the
    # key read from ANTHROPIC_API_KEY, and the default model. The test VM has no
    # ANTHROPIC_API_KEY (test_helper.exs), so the provider lists nothing and the note says
    # what to set.
    test "Enter all the way is Anthropic with the key from ANTHROPIC_API_KEY" do
      daemon = fn
        "config.get", _ ->
          {:ok, @nothing}

        "config.models", _ ->
          {:ok,
           %{"models" => [], "failures" => [%{"provider" => "anthropic", "reason" => "no API key"}]}}

        "config.set", _ ->
          {:ok, %{"path" => @path, "api_key_set" => true}}
      end

      assert ConfigSetup.run("/w", io(daemon: daemon, answers: ["", "", "", "", "", "", ""])) == 0

      assert_received {:ask, "provider: 1 Anthropic, 2 OpenAI" <> _}

      assert_received {:secret,
                       "API key, or {env:VAR} to read it from the environment [{env:ANTHROPIC_API_KEY}]: "}

      assert_received {:ask, "default model id [claude-sonnet-5]: "}
      # Asked with what the variable holds, which here is nothing.
      assert_received {:call, "config.models", ask_params}
      refute Map.has_key?(ask_params, "api_key")

      assert_received {:call, "config.set", params}
      assert params["provider"] == "anthropic"
      assert params["api_key"] == "{env:ANTHROPIC_API_KEY}"
      assert params["models"] == %{"default" => "claude-sonnet-5"}
      refute Map.has_key?(params, "base_url")

      text = Enum.join(said(), "\n")
      assert text =~ "anthropic: no API key"
      assert text =~ "note: ANTHROPIC_API_KEY is not set in this shell"
    end

    test "a gateway given no key saves none, and says no key is in force" do
      daemon = fn
        "config.get", _ -> {:ok, @nothing}
        "config.models", _ -> {:ok, %{"models" => [], "failures" => []}}
        "config.set", _ -> {:ok, %{"path" => @path, "api_key_set" => false}}
      end

      answers = ["1", "2", "http://localhost:8000/v1", "", "qwen3", "", "y"]
      assert ConfigSetup.run("/w", io(daemon: daemon, answers: answers)) == 0

      assert_received {:secret, "API key, or {env:VAR} to read it from the environment: "}
      assert_received {:call, "config.set", params}
      refute Map.has_key?(params, "api_key")
      assert params["models"] == %{"default" => "qwen3"}
      assert Enum.join(said(), "\n") =~ "no key is in force yet"
    end

    # The desktop app's last question too (root Decision 762), where there is a
    # troupe-daemon to start: Enter is no, yes is `troupe daemon login on`.
    test "saved settings end with whether troupe-daemon starts at login" do
      daemon = fn
        "config.get", _ -> {:ok, @nothing}
        "config.models", _ -> {:ok, %{"models" => [%{"id" => "m"}], "failures" => []}}
        "config.set", _ -> {:ok, %{"path" => @path, "api_key_set" => true}}
      end

      setup = ["1", "1", "", "key", "", "", ""]

      assert ConfigSetup.run("/w", io(daemon: daemon, troupe_daemon?: true, answers: setup ++ [""])) ==
               0

      assert_received {:ask, "Start troupe-daemon when you log in" <> question}
      assert question =~ "[y/N]"
      refute_received {:troupe_daemon, _}

      assert ConfigSetup.run(
               "/w",
               io(daemon: daemon, troupe_daemon?: true, answers: setup ++ ["y"])
             ) ==
               0

      assert_received {:ask, "Start troupe-daemon when you log in" <> _}
      assert_received {:troupe_daemon, ["login", "on"]}

      # Without one installed there is nothing to start, and nothing is asked.
      assert ConfigSetup.run("/w", io(daemon: daemon, answers: setup ++ ["y"])) == 0
      refute_received {:troupe_daemon, _}
      refute_received {:ask, "Start troupe-daemon" <> _}
    end

    test "saying no at the end saves nothing" do
      daemon = fn
        "config.get", _ -> {:ok, @nothing}
        "config.models", _ -> {:ok, %{"models" => [%{"id" => "m"}], "failures" => []}}
      end

      assert ConfigSetup.run("/w", io(daemon: daemon, answers: ["1", "1", "", "key", "", "", "n"])) ==
               1

      refute_received {:call, "config.set", _}
    end

    test "not now names the ways on" do
      assert ConfigSetup.run("/w", io(daemon: settings(@nothing), answers: ["3"])) == 0
      assert Enum.join(said(), "\n") =~ "When you are ready, either:"
    end
  end

  describe "before plain troupe opens a session" do
    test "a machine that is set up is asked nothing, and the daemon is not asked either" do
      assert ConfigSetup.before_session("/w", io(local_file?: true, usable?: true)) == :ok
      assert ConfigSetup.before_session("/w", io(usable?: true)) == :ok
      assert said() == []
      refute_received {:call, _, _}
    end

    test "a config.yaml with no key opens the session, which says what to do on its first turn" do
      assert ConfigSetup.before_session("/w", io(local_file?: true)) == :ok
      assert said() == []
    end

    # TUI Decision 153: the daemon's questions as one screen, and its first session is the
    # one plain `troupe` opens.
    test "a machine with nothing gets the setup's screen, and opens the session it ends in" do
      outcome = {:session, "s-first", "/projects/app"}

      assert ConfigSetup.before_session("/w", io(daemon: settings(@nothing), screen: outcome)) ==
               {:open, "s-first"}

      assert_received {:screen, %{"needed" => true}}
      assert_received {:open, "/projects/app", "s-first"}
      refute_received {:ask, _}
      refute_received {:call, "config.get", _}
    end

    test "leaving the screen goes on to a session as before, having said nothing was written" do
      assert ConfigSetup.before_session("/w", io(daemon: settings(@nothing))) == :ok
      assert_received {:screen, _flow}
      refute_received {:open, _, _}
      assert said() == ["Left the setup with nothing written; troupe setup asks again."]
    end

    test "a screen that cannot be drawn gets the first run's questions, line by line" do
      daemon = fn
        "setup.get", _ -> {:ok, %{"needed" => true}}
        "config.get", _ -> {:ok, @nothing}
      end

      io = io(daemon: daemon, screen: {:cannot_draw, "no console"}, answers: ["3"])
      assert ConfigSetup.before_session("/w", io) == :ok
      assert_received {:ask, "choice [1]: "}

      text = Enum.join(said(), "\n")
      assert text =~ "the screen could not be drawn (no console)"
      assert text =~ "When you are ready, either:"
    end

    # The desktop app's first run is recorded once, for every client (TUI Decision 123).
    test "a first run done in the desktop app means no questions here" do
      daemon = fn "setup.get", _ ->
        {:ok, %{"needed" => false, "completed" => %{"choice" => "plane"}}}
      end

      assert ConfigSetup.before_session("/w", io(daemon: daemon)) == :ok
      assert said() == []
      refute_received {:ask, _}
      refute_received {:call, "config.get", _}
    end

    test "a daemon from before setup.get still gets the questions" do
      daemon = fn
        "setup.get", _ -> {:error, %{"message" => "method_not_found"}}
        "config.get", _ -> {:ok, @nothing}
      end

      assert ConfigSetup.before_session("/w", io(daemon: daemon, answers: ["3"])) == :ok
      assert_received {:ask, "choice [1]: "}
    end

    test "without a terminal, one line says what to run" do
      assert ConfigSetup.before_session("/w", io(interactive?: false)) == :ok
      assert said() == ["No provider is set up yet: run `troupe config` to set one up."]
      refute_received {:call, _, _}
    end
  end

  # TUI Decision 153: `troupe setup`, at any time, whatever is set up already.
  describe "troupe setup" do
    test "opens the screen on the daemon's flow, then the session it ended in" do
      daemon = fn "setup.get", _ -> {:ok, %{"needed" => false, "step" => "where"}} end
      outcome = {:session, "s-1", "/projects/app"}

      assert ConfigSetup.setup(
               "/w",
               io(daemon: daemon, local_file?: true, usable?: true, screen: outcome)
             ) ==
               {:open, "s-1"}

      assert_received {:screen, %{"needed" => false, "step" => "where"}}
      assert_received {:open, "/projects/app", "s-1"}
    end

    test "Esc on the screen writes nothing, and says so" do
      daemon = fn "setup.get", _ -> {:ok, %{"needed" => true}} end
      assert ConfigSetup.setup("/w", io(daemon: daemon, screen: {:left, false})) == 0
      assert said() == ["Left the setup with nothing written; troupe setup asks again."]
      refute_received {:call, "setup.answer", _}
    end

    test "a plane: sign in, then take its settings, as troupe config's choice does" do
      daemon = fn "setup.get", _ -> {:ok, %{"needed" => true}} end

      assert ConfigSetup.setup("/w", io(daemon: daemon, screen: {:plane, "https://plane.example"})) ==
               0

      assert_received {:login, "https://plane.example"}
      assert_received {:pull, "https://plane.example"}
    end

    test "a first session that did not start, or could not be opened, says so and fails" do
      daemon = fn "setup.get", _ -> {:ok, %{"needed" => true}} end

      assert ConfigSetup.setup("/w", io(daemon: daemon, screen: {:no_session, "the disk is full"})) ==
               1

      assert said() == ["Set up. The first session did not start: the disk is full"]

      io = io(daemon: daemon, screen: {:session, "s-2", "/p"}, open: {:error, "gone"})
      assert ConfigSetup.setup("/w", io) == 1
      assert [line] = said()
      assert line =~ "troupe resume s-2 opens it"
    end

    test "without a terminal it says which, names the ways on, and fails" do
      io = io(daemon: settings(@nothing), interactive?: false, not_terminal: ["standard output"])
      assert ConfigSetup.setup("/w", io) == 1
      refute_received {:screen, _}
      refute_received {:ask, _}

      text = Enum.join(said(), "\n")
      assert text =~ "troupe setup: standard output is not a terminal"
      assert text =~ "When you are ready, either:"
    end

    test "a daemon from before setup.get gets troupe config's questions" do
      daemon = fn
        "setup.get", _ -> {:error, "method_not_found"}
        "config.get", _ -> {:ok, @nothing}
      end

      assert ConfigSetup.setup("/w", io(daemon: daemon, answers: ["3"])) == 0
      refute_received {:screen, _}
      assert_received {:ask, "choice [1]: "}
      assert Enum.join(said(), "\n") =~ "the daemon does not ask the first run's questions"
    end
  end

  test "a daemon that cannot be reached still gets the report, and a failure" do
    assert ConfigSetup.run("/w", io(daemon: fn _, _ -> {:error, :econnrefused} end)) == 1
    assert ["REPORT", line] = said()
    assert line =~ "could not ask the daemon"
  end

  # -- a person and a daemon, played ------------------------------------------------

  # A daemon with the file's settings, on a machine whose first run is not done.
  defp settings(answer) do
    fn
      "config.get", _ -> {:ok, answer}
      "setup.get", _ -> {:ok, %{"needed" => true, "completed" => nil}}
    end
  end

  defp io(opts) do
    test = self()
    Process.put(:answers, Keyword.get(opts, :answers, []))

    daemon =
      Keyword.get(opts, :daemon, fn _, _ -> flunk("the daemon was not expected to be asked") end)

    %{
      interactive?: Keyword.get(opts, :interactive?, true),
      not_terminal: Keyword.get(opts, :not_terminal, []),
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
      local_file?: fn -> Keyword.get(opts, :local_file?, false) end,
      usable?: fn -> Keyword.get(opts, :usable?, false) end,
      troupe_daemon?: fn -> Keyword.get(opts, :troupe_daemon?, false) end,
      troupe_daemon: fn args ->
        send(test, {:troupe_daemon, args})
        0
      end,
      # The screen, played: how it ended (`Troupe.UI.Setup.outcome/0`); `setup_screen_test`
      # plays a person on the screen itself.
      screen: fn flow ->
        send(test, {:screen, flow})
        Keyword.get(opts, :screen, {:left, false})
      end,
      open: fn workspace, sid ->
        send(test, {:open, workspace, sid})
        Keyword.get(opts, :open, {:ok, sid})
      end
    }
  end

  defp position(text, part), do: text |> :binary.match(part) |> elem(0)

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
