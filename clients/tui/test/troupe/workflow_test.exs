defmodule Troupe.WorkflowTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake
  alias Troupe.Workflow

  describe "Troupe.Workflow" do
    test "default_steps is an ordered, non-empty list of steps, each with an owner" do
      steps = Workflow.default_steps()
      assert [_ | _] = steps
      assert Enum.all?(steps, &(is_binary(&1.name) and is_binary(&1.prompt)))
      assert Enum.all?(steps, &is_boolean(&1.parallel))
      # the canonical six
      assert Enum.map(steps, & &1.name) ==
               ["understand", "plan", "implement", "test", "document", "verify"]

      # every step is owned by a subagent, bar `plan`, which the orchestrator does itself
      assert Enum.map(steps, & &1.agent) ==
               ["explore", nil, "implementer", "implementer", "implementer", "reviewer"]
    end

    test "the agents the default workflow delegates to exist and are subagents" do
      defs = Troupe.Agents.load(tmp_workspace())

      for %{agent: agent} <- Workflow.default_steps(), agent != nil do
        assert %{mode: :subagent} = Map.fetch!(defs, agent)
      end

      # and the orchestrator itself may not write: it delegates or it does nothing
      workflow = Map.fetch!(defs, "workflow")
      assert workflow.mode == :primary
      assert workflow.model == "expensive"
      assert workflow.isolation == :worktree
      assert "delegate" in Troupe.Tools.allowed(workflow)
      refute "write_file" in Troupe.Tools.allowed(workflow)
      refute "edit_file" in Troupe.Tools.allowed(workflow)
      refute "shell" in Troupe.Tools.allowed(workflow)
    end

    test "split parses <name> <task> and name: task, defaulting to a bare task" do
      ws = tmp_workspace(%{".troupe/workflows/elixir.json" => ~s|[{"name":"a","prompt":"p"}]|})

      assert Troupe.Workflow.split(ws, "elixir release a new version") ==
               {"elixir", "release a new version"}

      assert Troupe.Workflow.split(ws, "elixir: release a new version") ==
               {"elixir", "release a new version"}

      # a leading word with no matching file is just part of the task
      assert Troupe.Workflow.split(ws, "just a plain task") == {"default", "just a plain task"}
      assert Troupe.Workflow.split(ws, "") == {"default", ""}
    end

    test "available lists on-disk workflows, default when none" do
      ws =
        tmp_workspace(%{
          ".troupe/workflows/custom.json" => ~s|[{"name":"a","prompt":"do a"}]|
        })

      assert Workflow.available(ws) == ["custom"]
      ws2 = tmp_workspace()
      assert Workflow.available(ws2) == []
    end

    test "load reads a named workflow's owners and parallel flags" do
      ws =
        tmp_workspace(%{
          ".troupe/workflows/custom.json" => """
          [{"name":"build","agent":"implementer","prompt":"build it"},
           {"name":"docs","agent":"implementer","prompt":"write docs","parallel":true},
           {"name":"decide","prompt":"ship or not"}]
          """
        })

      assert Workflow.load(ws, "custom") == [
               %{name: "build", agent: "implementer", prompt: "build it", parallel: false},
               %{name: "docs", agent: "implementer", prompt: "write docs", parallel: true},
               %{name: "decide", agent: nil, prompt: "ship or not", parallel: false}
             ]
    end

    test "load falls back to the default for a missing, malformed or blank-agent file" do
      ws = tmp_workspace()
      assert Workflow.load(ws, "nope") == Workflow.default_steps()
      ws_bad = tmp_workspace(%{".troupe/workflows/bad.json" => "not json"})
      assert Workflow.load(ws_bad, "bad") == Workflow.default_steps()
      # "default" is always the bundled pipeline
      assert Workflow.load(ws, "default") == Workflow.default_steps()

      # an empty or non-string agent is the orchestrator's own step, not a crash
      ws_blank =
        tmp_workspace(%{".troupe/workflows/b.json" => ~s|[{"name":"a","agent":"","prompt":"p"}]|})

      assert [%{agent: nil}] = Workflow.load(ws_blank, "b")
    end

    test "plan renders the task, the owner of each step and the delegation rules" do
      plan =
        Workflow.plan(
          [
            Workflow.step("understand", "explore", "read it"),
            Workflow.step("decide", nil, "pick one"),
            Workflow.step("verify", "reviewer", "run tests", true)
          ],
          "add a feature"
        )

      assert plan =~ "Task: add a feature"
      assert plan =~ "1. [`explore`] **understand:** read it"
      assert plan =~ "2. [you] **decide:** pick one"
      assert plan =~ "3. [`reviewer`] `parallel` **verify:** run tests"
      assert plan =~ "delegate that step to that agent"
      assert plan =~ "run concurrently"
      assert plan =~ "call `finish`"
    end

    test "plan without parallel steps leaves out the concurrency rule" do
      plan = Workflow.plan([Workflow.step("only", "implementer", "do it")], "t")
      refute plan =~ "run concurrently"
      assert plan =~ "Every delegate prompt must stand alone"
    end

    test "plan falls back to the default steps for an empty list" do
      assert Workflow.plan([], "t") == Workflow.plan(Workflow.default_steps(), "t")
    end
  end

  describe "dispatching a workflow" do
    test "the orchestrator delegates its steps and auto-commits the worktree" do
      ws = tmp_workspace() |> git_init!()

      scripts = %{
        "workflow-1/implementer-1" => [
          {:tool, "write_file", %{"path" => "feature.txt", "content" => "done\n"}},
          {:finish, "wrote feature.txt"}
        ]
      }

      script = [
        {:tool, "delegate", %{"agent" => "implementer", "prompt" => "implement step 3"}},
        {:finish, "implemented and verified"}
      ]

      {sid, fake, _ws} =
        start_session!(workspace: ws, script: script, scripts: scripts, auto_approve: true)

      {:ok, path} = Troupe.dispatch(sid, "workflow", "fix the parse bug")
      assert path == "workflow-1"

      await_state(path, :done_unread)

      win = window(sid, path)
      # it runs in an isolated worktree
      assert win.isolation == :worktree
      assert win.worktree.managed == true
      # the plan's own "Task:" line must not be read as a worktree name
      assert win.branch_id == "workflow-1"
      assert Path.basename(win.worktree.path) == "workflow-1"

      # the plan — not the raw prompt — was sent, and it names the step owners
      req = fake |> Fake.requests() |> Enum.find(&(&1.agent_path == path))
      assert req.agent_path == path
      [input | _] = events_of(sid, path, :input)
      assert input.data.content =~ "Task: fix the parse bug"
      assert input.data.content =~ "[`implementer`] **implement:**"
      assert input.data.content =~ "[`reviewer`] **verify:**"

      # the step really ran as a child, in the orchestrator's worktree
      assert [%{data: %{ok: true, content: "wrote feature.txt"}}] =
               events_of(sid, path, :delegation_completed)

      assert File.exists?(Path.join(win.worktree.path, "feature.txt"))
      refute File.exists?(Path.join(ws, "feature.txt"))

      # worktree is mergeable once done
      assert {:ok, _} = Troupe.merge(sid, path)
      assert window(sid, path).worktree.merged == true
      assert File.exists?(Path.join(ws, "feature.txt"))
    end

    test "the orchestrator cannot edit the repository itself" do
      ws = tmp_workspace() |> git_init!()

      script = [
        {:tool, "write_file", %{"path" => "sneaky.txt", "content" => "x"}},
        {:finish, "done"}
      ]

      {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
      {:ok, path} = Troupe.dispatch(sid, "workflow", "do it yourself")
      await_state(path, :done_unread)

      [denied] =
        sid
        |> events_of(path, :tool_call_completed)
        |> Enum.filter(&(&1.data.ok == false))

      assert denied.data.content =~ "not available"
      refute File.exists?(Path.join(window(sid, path).worktree.path, "sneaky.txt"))
    end

    test "a named /workflow <name> task loads that file's steps and owners" do
      ws = tmp_workspace() |> git_init!()

      File.mkdir_p!(Path.join(ws, ".troupe/workflows"))

      File.write!(
        Path.join(ws, ".troupe/workflows/elixir.json"),
        ~s|[{"name":"build","agent":"implementer","prompt":"mix compile"},| <>
          ~s|{"name":"verify","agent":"reviewer","prompt":"mix test"}]|
      )

      {sid, _, _} = start_session!(workspace: ws, auto_approve: true)
      {:ok, path} = Troupe.dispatch(sid, "workflow", "elixir release next version")
      await_state(path, :done_unread)

      # The dispatched prompt contains the named workflow's steps, not the defaults.
      events = events_of(sid, path, :input)
      assert [_ | _] = events
      prompt = List.first(events).data.content
      assert prompt =~ "[`implementer`] **build:** mix compile"
      assert prompt =~ "[`reviewer`] **verify:** mix test"
      refute prompt =~ "understand"
    end
  end
end
