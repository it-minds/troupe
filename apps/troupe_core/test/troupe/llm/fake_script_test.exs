defmodule Troupe.LLM.FakeScriptTest do
  @moduledoc """
  A scripted model configured the way a machine configures it: `provider: fake` and a
  script file named in the workspace's own `.troupe/config.yaml`, with no fake process
  handed to the session. This is how a client that speaks only the protocol — the TUI's
  test suite, a smoke of a packaged daemon — gets deterministic answers without the
  daemon letting it choose a provider over the wire.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Fake

  test "a JSON script carries a shared list, or steps and per-agent routes" do
    assert Fake.normalize_script([%{"text" => "hi"}]) == [steps: [{:text, "hi"}], routes: %{}]

    assert Fake.normalize_script(%{
             "steps" => [%{"text" => "root"}],
             "routes" => %{
               "explore" => [
                 %{"text" => "found"},
                 %{"tools" => [%{"name" => "finish", "input" => %{"summary" => "ok"}}]}
               ]
             }
           }) ==
             [
               steps: [{:text, "root"}],
               routes: %{
                 "explore" => [{:text, "found"}, {:tools, [{"finish", %{"summary" => "ok"}}]}]
               }
             ]
  end

  test "a workspace config names the script, and a subagent answers from its own route",
       context do
    script = Path.join(context.base, "script.json")

    File.write!(
      script,
      Jason.encode!(%{
        "routes" => %{
          "root" => [
            %{
              "tools" => [
                %{"name" => "delegate", "input" => %{"agent" => "explore", "task" => "look"}}
              ]
            },
            %{
              "text" => "the explorer said its piece",
              "tools" => [%{"name" => "finish", "input" => %{"summary" => "done"}}]
            }
          ],
          "explore" => [
            %{
              "text" => "found it",
              "tools" => [%{"name" => "finish", "input" => %{"summary" => "found it"}}]
            }
          ]
        }
      })
    )

    File.mkdir_p!(Path.join(context.workspace, ".troupe"))

    File.write!(Path.join(context.workspace, ".troupe/config.yaml"), """
    provider: fake
    model: fake-model
    auto_approve: true
    fake_script: #{script}
    """)

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        config_overrides: [state_dir: context.state_dir]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    sid = session.id

    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 10_000

    texts =
      session.id
      |> Troupe.events()
      |> Enum.filter(&(&1.type == "llm_response"))
      |> Enum.map(fn event ->
        text =
          event.data["message"]["content"]
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join(& &1["text"])

        {event.agent, text}
      end)

    assert Enum.any?(texts, fn {agent, text} ->
             List.last(agent) =~ "explore" and text == "found it"
           end)

    assert Enum.any?(texts, fn {agent, text} ->
             agent == ["root"] and text == "the explorer said its piece"
           end)
  end
end
