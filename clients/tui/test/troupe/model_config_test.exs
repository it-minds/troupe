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

  describe "the config.set a plane's defaults become" do
    test "carries what the plane says, and no key" do
      params =
        ModelConfig.params(%{
          "configured" => true,
          "provider" => "openai",
          "base_url" => "https://llm-gw.example/v1",
          "auth" => "bearer",
          "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b", "expensive" => nil}
        })

      assert %{
               "provider" => "openai",
               "base_url" => "https://llm-gw.example/v1",
               "auth" => "bearer",
               "models" => %{"default" => "glm-5.2", "cheap" => "qwen3.6-35b"}
             } = params

      assert "c-" <> _ = params["command_id"]
      # Absent, not empty: an empty key would remove the one already saved.
      refute Map.has_key?(params, "api_key")
    end

    test "a role the plane leaves empty keeps this machine's choice" do
      params =
        ModelConfig.params(%{
          "provider" => "anthropic",
          "base_url" => nil,
          "models" => %{"default" => ""}
        })

      refute Map.has_key?(params, "models")
      refute Map.has_key?(params, "auth")
    end
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
      model =
        Model.rebuild("s-1", "/w", [event(:branch_spawned, %{name: "build", isolation: :shared})])

      [window] = Model.windows(model)

      assert Model.activity_line(window, "root", 0, 10) =~ "starting"
    end

    test "a subagent still working is reported under an idle root" do
      model =
        Model.rebuild("s-1", "/w", [
          event(:branch_spawned, %{name: "build", isolation: :shared}),
          event(:agent_state, %{to: :idle}),
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
