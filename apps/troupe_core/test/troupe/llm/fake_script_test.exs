defmodule Troupe.LLM.FakeScriptTest do
  @moduledoc """
  A scripted model configured the way a machine configures it: `provider: fake` and a
  script file named in the workspace's own `.troupe/config.yaml`, with no fake process
  handed to the session. This is how a client that speaks only the protocol — the TUI's
  test suite, a smoke of a packaged daemon — gets deterministic answers without the
  daemon letting it choose a provider over the wire. A strict one refuses what a real
  provider refuses of tool blocks.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Fake, Message, Request, ToolResult, ToolUse}

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

  # A gateway streaming a response says nothing about its cost, which is what a smoke of
  # `models.prices` against a packaged daemon has to reproduce (#160).
  test "a script may say what the imaginary gateway charges, nothing included" do
    assert Fake.normalize_script(%{"steps" => [], "cost_micros" => nil}) == [
             steps: [],
             routes: %{},
             cost_micros: nil
           ]

    assert Fake.normalize_script(%{"steps" => [], "cost_micros" => 50}) == [
             steps: [],
             routes: %{},
             cost_micros: 50
           ]

    assert Fake.normalize_script(%{"steps" => []}) == [steps: [], routes: %{}]
  end

  # The stand-in for what Anthropic's and OpenAI's APIs refuse (Decision 774), which a
  # compaction test runs against.
  test "a strict model refuses a tool result without its call, and a call without its result" do
    fake = start_supervised!({Fake, steps: [{:text, "answered"}], strict_pairs: true})
    call = Message.assistant([%ToolUse{id: "call_1", name: "todo_read", input: %{}}])
    result = Message.tool_results([%ToolResult{tool_use_id: "call_1", content: "[]"}])
    request = &%Request{model: "fake-model", messages: &1}

    assert {:error,
            {:http_status, 400, "messages.1: tool_result for call_1 has no tool_use" <> _}} =
             Fake.next(fake, request.([Message.user("summary"), result]))

    assert {:error, {:http_status, 400, "messages.1: tool_use call_1 has no tool_result" <> _}} =
             Fake.next(fake, request.([Message.user("go"), call, Message.user("summarise")]))

    # Refused requests took no step: the paired one gets the first.
    assert {:ok, %{content: [%{text: "answered"}]}, _delay} =
             Fake.next(fake, request.([Message.user("go"), call, result]))
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
    models: {default: fake-model}
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
