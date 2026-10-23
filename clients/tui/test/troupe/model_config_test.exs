defmodule Troupe.ModelConfigTest do
  @moduledoc """
  `troupe config pull`, and the status line when the model cannot be reached — the two
  things a machine with no key used to meet as an endless "starting".
  """

  use ExUnit.Case, async: true

  alias Troupe.CLI
  alias Troupe.CLI.ModelConfig
  alias Troupe.Event
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  test "config pull parses with and without a plane" do
    assert {:ok, %{mode: :config_pull, plane_url: nil}} = CLI.parse(["config", "pull"])

    assert {:ok, %{mode: :config_pull, plane_url: "https://plane.example"}} =
             CLI.parse(["config", "pull", "https://plane.example"])

    assert {:ok, %{mode: :config}} = CLI.parse(["config"])
    assert CLI.usage() =~ "troupe config pull"
  end

  # The plane's answer goes to the daemon's `config.organisation` as it came, and nothing
  # into the person's own file (root Decision 869; `org_settings_test.exs` has the rest).
  test "config pull hands the plane's answer to the daemon, as it came" do
    answer = %{
      "configured" => true,
      "provider" => "openai",
      "defaults" => %{"provider" => "openai"},
      "enforced" => %{}
    }

    test = self()

    call = fn method, params ->
      send(test, {:called, method, params})

      {:ok,
       %{
         "plane_url" => params["plane_url"],
         "defaults" => %{"provider" => "openai"},
         "enforced" => %{},
         "path" => "x"
       }}
    end

    assert ModelConfig.keep("https://plane.example", answer, fn _line -> :ok end, call) == 0
    assert_received {:called, "config.organisation", params}
    assert %{"plane_url" => "https://plane.example", "document" => ^answer} = params
    assert "c-" <> _ = params["command_id"]
    refute Map.has_key?(params, "api_key")
  end

  # Root issue #55: the organisation's memory comes with the pull, handed to the daemon's
  # `config.memory` as the plane signed it, and what this machine now reads said.
  test "config pull hands the plane's memory to the daemon, signature and all, and says what is kept" do
    answer = %{
      "documents" => [
        %{"scope" => "organisation", "name" => nil, "version" => 2, "text" => "Deploy on Tuesdays."}
      ],
      "signed" => %{"fingerprint" => "SHA256:abc"}
    }

    test = self()

    call = fn method, params ->
      send(test, {:called, method, params})

      {:ok,
       %{
         "plane_url" => params["plane_url"],
         "path" => "~/.local/state/troupe/memory.json",
         "documents" => [
           %{"scope" => "organisation", "name" => nil, "version" => 2},
           %{"scope" => "team", "name" => "design", "version" => 5}
         ],
         "changed" => [%{"scope" => "organisation", "name" => nil, "from" => 1, "to" => 2}]
       }}
    end

    say = fn line -> send(test, {:said, line}) end

    assert ModelConfig.keep_memory("https://plane.example", answer, say, call) == 0

    assert_received {:called, "config.memory",
                     %{"plane_url" => "https://plane.example", "document" => ^answer}}

    assert_received {:said,
                     "https://plane.example's memory for this machine's sessions, kept in ~/.local/state/troupe/memory.json:"}

    assert_received {:said, "  the organisation's memory, version 2"}
    assert_received {:said, "  the team design's memory, version 5"}
    assert_received {:said, "the sessions running here read it from their next turn"}

    refused = fn _method, _params -> {:error, "the plane's signature does not match"} end
    assert ModelConfig.keep_memory("https://plane.example", answer, say, refused) == 1

    assert_received {:said,
                     "could not keep the organisation's memory: the plane's signature does not match"}
  end

  describe "a model error" do
    test "arrives from the daemon as its own event, with the reason" do
      wire = %{
        "seq" => 6,
        "ts" => "2026-09-21T18:53:11.170Z",
        "agent" => ["root"],
        "type" => "llm_error",
        "v" => 1,
        "data" => %{"reason" => "no API key is configured for the provider"}
      }

      {events, _memory} =
        Translate.durable("s-1", wire, Translate.remember(Translate.memory(), "root"))

      assert [%{type: :llm_error, data: %{message: "no API key is configured for the provider"}}] =
               events
    end

    test "stops the status line saying starting, until the agent works again" do
      model =
        Model.rebuild("s-1", "/w", [
          event(:branch_spawned, %{name: "build", isolation: :shared}),
          event(:agent_state, %{to: :thinking}),
          event(:llm_error, %{message: "no API key is configured for the provider"}),
          event(:agent_state, %{to: :idle})
        ])

      [window] = Model.windows(model)

      assert Model.activity_line(window, "root", 0, 10) ==
               "model error: no API key is configured for the provider"

      model = Model.apply(model, event(:agent_state, %{to: :thinking}))
      [window] = Model.windows(model)
      assert Model.activity_line(window, "root", 0, 10) =~ "thinking"
    end

    # A first run's first turn, in the terminal UI: the error, and under it the one thing
    # to do, in the words the headless printer and `troupe-daemon config` use.
    test "puts the next step under the error in the transcript" do
      model =
        Model.rebuild("s-1", "/w", [
          event(:branch_spawned, %{name: "build", isolation: :shared}),
          event(:llm_error, %{message: "no API key is configured for the provider"})
        ])

      [window] = Model.windows(model)

      assert Enum.take(window.agents["root"].transcript, -2) == [
               {:system, "LLM error: no API key is configured for the provider"},
               {:system, "run `troupe config` to set up a provider"}
             ]

      other = Model.apply(model, event(:llm_error, %{message: "the gateway is down"}))
      [window] = Model.windows(other)

      assert List.last(window.agents["root"].transcript) ==
               {:system, "LLM error: the gateway is down"}
    end

    # A plane's worker asks the model with the plane's key, which `troupe config` on this
    # machine cannot change: the step under the error is the plane's administrator.
    test "from a plane's worker, says to ask the plane's administrator, not troupe config" do
      wire = %{
        "seq" => 6,
        "ts" => "2026-09-21T18:53:11.170Z",
        "agent" => ["root"],
        "type" => "llm_error",
        "v" => 1,
        "data" => %{"reason" => "no API key is configured for the provider"}
      }

      translated = fn isolation ->
        {[event], _memory} =
          Translate.durable("s-1", wire, Translate.remember(Translate.memory(isolation), "root"))

        event
      end

      plane = translated.(:remote)
      refute Map.has_key?(translated.(:shared).data, :next_step)

      model =
        Model.rebuild("s-1", "/w", [
          event(:branch_spawned, %{name: "build", isolation: :remote}),
          plane
        ])

      [window] = Model.windows(model)

      assert List.last(window.agents["root"].transcript) ==
               {:system,
                "the model's key is the plane's, not this machine's: ask the plane's administrator"}

      refute Enum.any?(
               window.agents["root"].transcript,
               &match?({:system, "run `troupe config`" <> _}, &1)
             )

      rejected = put_in(wire, ["data", "reason"], "the provider rejected the credentials (401)")

      {[event], _} =
        Translate.durable("s-1", rejected, Translate.remember(Translate.memory(:remote), "root"))

      assert event.data.next_step =~ "ask the plane's administrator"
    end

    # A root agent ends a text-only turn with an ephemeral `agent_state: idle` and no
    # durable marker, and idle was folded in with "nothing heard from this agent yet" —
    # so a session the user was happily chatting with spun on "starting" forever.
    test "an agent that has gone idle has no line, rather than spinning on starting" do
      model =
        Model.rebuild("s-1", "/w", [
          event(:branch_spawned, %{name: "build", isolation: :shared}),
          event(:agent_state, %{to: :thinking}),
          event(:agent_state, %{to: :idle})
        ])

      [window] = Model.windows(model)
      refute Model.activity_line(window, "root", 0, 10)
    end

    test "an agent nothing has been heard from yet is still starting" do
      opened = %{name: "build", isolation: :shared, prompt: "fix the test"}
      model = Model.rebuild("s-1", "/w", [event(:branch_spawned, opened)])

      [window] = Model.windows(model)

      assert Model.activity_line(window, "root", 0, 10) =~ "starting"
    end

    # A session's own window opens with no task: nothing asked of it, so nothing starting
    # (TUI Decision 155), where it used to read `running` from its first frame.
    test "a window nothing has been asked of is idle, and says nothing" do
      model =
        Model.rebuild("s-1", "/w", [event(:branch_spawned, %{name: "build", isolation: :shared})])

      assert %{state: :idle} = window = Model.session_window(model)
      assert Model.windows(model) == []
      refute Model.activity_line(window, "root", 0, 10)
    end

    # The live idle: a turn that ended, as the log says it, is a window at rest.
    test "a subagent still working is reported under an idle root" do
      model =
        Model.rebuild("s-1", "/w", [
          event(:branch_spawned, %{name: "build", isolation: :shared}),
          Event.transient("s-1", "root", :agent_state, %{to: :idle}),
          %Event{
            session_id: "s-1",
            agent_path: "root/librarian",
            type: :agent_state,
            data: %{to: :thinking},
            ts: 1
          }
        ])

      [window] = Model.windows(model)

      assert Model.activity_line(window, "root", 0, 10) == "librarian thinking"
    end
  end

  defp event(type, data),
    do: %Event{session_id: "s-1", agent_path: "root", type: type, data: data, ts: 1}
end
