defmodule Troupe.WorkflowTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake
  alias Troupe.Workflow

  describe "Troupe.Workflow" do
    test "default_steps is an ordered, non-empty list of name/prompt steps" do
      steps = Workflow.default_steps()
      assert [_ | _] = steps
      assert Enum.all?(steps, &(is_binary(&1.name) and is_binary(&1.prompt)))
      # the canonical six
      assert Enum.map(steps, & &1.name) ==
               ["understand", "plan", "implement", "test", "document", "verify"]
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
      ws = tmp_workspace(%{
        ".troupe/workflows/custom.json" => ~s|[{"name":"a","prompt":"do a"}]|
      })

      assert Workflow.available(ws) == ["custom"]
      ws2 = tmp_workspace()
      assert Workflow.available(ws2) == []
    end

    test "load reads a named workflow (and rejects an invalid one, falling back to default)" do
      ws = tmp_workspace(%{
        ".troupe/workflows/custom.json" =>
          ~s|[{"name":"build","prompt":"build it"},{"name":"deploy","prompt":"ship it"}]|
      })

      assert Workflow.load(ws, "custom") == [
               %{name: "build", prompt: "build it"},
               %{name: "deploy", prompt: "ship it"}
             ]

      # missing and malformed fall back to default
      assert Workflow.load(ws, "nope") == Workflow.default_steps()
      ws_bad = tmp_workspace(%{".troupe/workflows/bad.json" => "not json"})
      assert Workflow.load(ws_bad, "bad") == Workflow.default_steps()
      # "default" is always the bundled pipeline
      assert Workflow.load(ws, "default") == Workflow.default_steps()
    end

    test "plan renders the task and numbered steps" do
      plan =
        Workflow.plan(
          [%{name: "understand", prompt: "read it"}, %{name: "verify", prompt: "run tests"}],
          "add a feature"
        )

      assert plan =~ "Task: add a feature"
      assert plan =~ "1. **understand: ** read it"
      assert plan =~ "2. **verify: ** run tests"
      assert plan =~ "call `finish`"
    end
  end

  describe "dispatching a workflow" do
    test "a bare /workflow runs the default pipeline in a worktree branch and auto-commits" do
      ws = tmp_workspace() |> git_init!()

      script = [{:finish, "implemented and verified"}]
      {sid, fake, _ws} = start_session!(workspace: ws, script: script, auto_approve: true)

      {:ok, path} = Troupe.dispatch(sid, "workflow", "fix the parse bug")
      assert path == "workflow-1"

      await_state(path, :done_unread)

      win = window(sid, path)
      # it runs in an isolated worktree
      assert win.isolation == :worktree
      assert win.worktree.managed == true
      # the plan (not the raw prompt) was sent as the input
      req = fake |> Fake.requests() |> hd()
      assert req.agent_path == path

      # worktree is mergeable once done
      assert {:ok, _} = Troupe.merge(sid, path)
      assert window(sid, path).worktree.merged == true
    end

    test "a named /workflow <name> task loads that file's steps" do
      ws = tmp_workspace() |> git_init!()

      File.mkdir_p!(Path.join(ws, ".troupe/workflows"))

      File.write!(
        Path.join(ws, ".troupe/workflows/elixir.json"),
        ~s|[{"name":"build","prompt":"mix compile"},{"name":"verify","prompt":"mix test"}]|
      )

      {sid, _, _} = start_session!(workspace: ws, auto_approve: true)
      {:ok, path} = Troupe.dispatch(sid, "workflow", "elixir release next version")
      await_state(path, :done_unread)

      # The dispatched prompt contains the named workflow's steps, not the defaults.
      events = events_of(sid, path, :input)
      assert [_ | _] = events
      prompt = List.first(events).data.content
      assert prompt =~ "mix compile"
      assert prompt =~ "mix test"
      refute prompt =~ "understand"
    end
  end
end
