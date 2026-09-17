defmodule Troupe.DefinitionsTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake

  @explore_override """
  ---
  description: project explore
  mode: subagent
  model: cheap
  tools: [read_file, list_files, grep, finish]
  ---
  Project-specific explore prompt.
  """

  # Done item 20
  test "project definitions override built-ins; explore cannot write; depth is capped; delegate names model aliases" do
    ws = tmp_workspace(%{".troupe/agents/explore.md" => @explore_override})
    defs = Troupe.Agents.load(ws)
    assert defs["explore"].source == :project
    assert defs["explore"].prompt =~ "Project-specific"
    assert defs["code"].source == :builtin

    scripts = %{
      "code-1/explore-1" => [
        {:tool, "write_file", %{"path" => "nope.txt", "content" => "x"}},
        {:finish, "explore done"}
      ]
    }

    script = [
      {:tool, "delegate", %{"agent" => "explore", "prompt" => "look around"}},
      {:finish, "parent done"}
    ]

    {sid, fake, _} =
      start_session!(workspace: ws, script: script, scripts: scripts, auto_approve: true)

    {:ok, path} = Troupe.dispatch(sid, "code", "go")
    await_state(path, :done_unread)

    refute File.exists?(Path.join(ws, "nope.txt"))

    [denied] =
      events_of(sid, "code-1/explore-1", :tool_call_completed)
      |> Enum.filter(&(&1.data.ok == false))

    assert denied.data.content =~ "not available"
    child_req = fake |> Fake.requests() |> Enum.find(&(&1.agent_path == "code-1/explore-1"))
    assert child_req.system =~ "Project-specific"

    parent_req = fake |> Fake.requests() |> Enum.find(&(&1.agent_path == "code-1"))
    delegate = Enum.find(parent_req.tools, &(&1.name == "delegate"))
    assert delegate.description =~ "`explore` (model: cheap)"
    assert delegate.description =~ "`general` (model: default)"

    completed = events_of(sid, "code-1", :delegation_completed)
    assert [%{data: %{ok: true, content: "explore done"}}] = completed
  end

  test "delegation past the depth cap is an error tool_result" do
    ws = tmp_workspace()

    scripts = %{
      "code-1/general-1" => [
        {:tool, "delegate", %{"agent" => "explore", "prompt" => "deeper"}},
        {:finish, "child done"}
      ]
    }

    script = [
      {:tool, "delegate", %{"agent" => "general", "prompt" => "delegate again"}},
      {:finish, "ok"}
    ]

    {sid, _, _} =
      start_session!(
        workspace: ws,
        script: script,
        scripts: scripts,
        auto_approve: true,
        config: %{max_delegation_depth: 1}
      )

    {:ok, path} = Troupe.dispatch(sid, "code", "go")
    await_state(path, :done_unread)
    [err | _] = events_of(sid, "code-1/general-1", :tool_call_completed)
    assert err.data.ok == false
    assert err.data.content =~ "depth cap (1)"
    refute Troupe.agent_pid(sid, "code-1/general-1/explore-1")
  end

  # Done item 21
  test "plan rejects write_file and shell; Tab to code carries conversation, todo list and the code tool set" do
    ws = tmp_workspace()

    script = [
      {:tools,
       [
         {"write_file", %{"path" => "a", "content" => "b"}},
         {"shell", %{"command" => "echo hi"}},
         {"todo_write",
          %{"items" => [%{"id" => "1", "content" => "split billing", "status" => "pending"}]}}
       ]},
      {:finish, "plan written"},
      {:finish, "built"}
    ]

    {sid, fake, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "plan", "how should we split billing")
    await_state(path, :done_unread)
    refute File.exists?(Path.join(ws, "a"))

    completed = events_of(sid, path, :tool_call_completed)
    assert Enum.count(completed, &(&1.data.ok == false)) == 2
    assert Enum.any?(completed, &(&1.data.content =~ "not available to the plan agent"))
    plan_req = fake |> Fake.requests() |> hd()
    refute Enum.any?(plan_req.tools, &(&1.name == "write_file"))

    :ok = Troupe.switch_profile(sid, path, "code")
    :ok = Troupe.send_input(sid, path, "go")
    await_state(path, :running)
    await_state(path, :done_unread)

    req = fake |> Fake.requests() |> List.last()
    assert req.system =~ "profile code"
    assert volatile_text(req) =~ "split billing"
    assert Enum.any?(req.tools, &(&1.name == "write_file"))
    assert Enum.any?(req.tools, &(&1.name == "shell"))

    texts =
      req.messages
      |> Enum.flat_map(& &1.content)
      |> Enum.filter(&match?(%{type: :text}, &1))
      |> Enum.map(& &1.text)

    assert "how should we split billing" in texts
  end

  # Done item 22
  test "todo: two in_progress items is an error; a window cancel appears in the next request" do
    ws = tmp_workspace()

    script = [
      {:tool, "todo_write",
       %{
         "items" => [
           %{"id" => "1", "content" => "a", "status" => "in_progress"},
           %{"id" => "2", "content" => "b", "status" => "in_progress"}
         ]
       }},
      {:tool, "todo_write",
       %{
         "items" => [
           %{"id" => "1", "content" => "a", "status" => "in_progress"},
           %{"id" => "2", "content" => "b", "status" => "pending"}
         ]
       }},
      {:tool, "shell", %{"command" => "sleep 0.5"}},
      {:finish, "done"}
    ]

    {sid, fake, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "code", "todo")

    [first | _] =
      eventually(fn ->
        events_of(sid, path, :tool_call_completed) |> then(&if(&1 != [], do: &1))
      end)

    assert first.data.ok == false
    assert first.data.content =~ "at most one item may be in_progress"

    assert_receive {:troupe_event,
                    %{type: :tool_call_started, agent_path: ^path, data: %{name: "shell"}}},
                   5_000

    :ok = Troupe.edit_todo(sid, path, {:cancel, "2"})
    await_state(path, :done_unread)
    last = fake |> Fake.requests() |> List.last()
    assert volatile_text(last) =~ "[cancelled] 2: b"
    assert volatile_text(last) =~ "[in_progress] 1: a"
  end

  # Done item 23
  test "/ask uses the cheap model and its read_branch results appear in the Fake request" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "todo_write",
         %{"items" => [%{"id" => "1", "content" => "add limiter", "status" => "completed"}]}},
        {:finish, "added rate limiting"}
      ],
      "code-2" => [{:finish, "fixed the flaky auth test"}],
      "ask-1" => [
        {:tool, "read_branch", %{}},
        {:tools,
         [
           {"read_branch", %{"agent_path" => "code-1"}},
           {"read_branch", %{"agent_path" => "code-2"}}
         ]},
        {:finish, "both changed different things"}
      ]
    }

    {sid, fake, _} =
      start_session!(
        workspace: ws,
        scripts: scripts,
        config: %{models: %{cheap: "tiny-model", default: "big-model"}}
      )

    {:ok, p1} = Troupe.dispatch(sid, "code", "rate limiting")
    {:ok, p2} = Troupe.dispatch(sid, "code", "flaky test")
    await_state(p1, :done_unread)
    await_state(p2, :done_unread)
    {:ok, ask} = Troupe.dispatch(sid, "ask", "what changed?")
    await_state(ask, :done_unread)

    ask_reqs = fake |> Fake.requests() |> Enum.filter(&(&1.agent_path == ask))
    assert Enum.all?(ask_reqs, &(&1.model == "tiny-model"))
    code_req = fake |> Fake.requests() |> Enum.find(&(&1.agent_path == p1))
    assert code_req.model == "big-model"

    last = List.last(ask_reqs)

    results =
      last.messages
      |> Enum.flat_map(& &1.content)
      |> Enum.filter(&match?(%{type: :tool_result}, &1))
      |> Enum.map(& &1.content)

    assert Enum.any?(results, &(&1 =~ "code-1" and &1 =~ "code-2" and not (&1 =~ "added")))
    assert Enum.any?(results, &(&1 =~ "added rate limiting" and &1 =~ "[completed] add limiter"))
    assert Enum.any?(results, &(&1 =~ "fixed the flaky auth test"))
    assert window(sid, ask).summary == "both changed different things"
  end
end
