defmodule Troupe.WorkflowTest do
  @moduledoc """
  The workflow module is pure: it loads step lists and renders the plan the `workflow`
  agent starts from. The agents it names have to exist, with the shape the plan assumes.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definitions
  alias Troupe.Workflow

  setup do
    ws = Path.join(System.tmp_dir!(), "troupe-wf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws}
  end

  defp write!(ws, rel, content) do
    path = Path.join(ws, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "default_steps is the six-step pipeline, each step with an owner" do
    steps = Workflow.default_steps()

    assert Enum.map(steps, & &1.name) ==
             ["understand", "plan", "implement", "test", "document", "verify"]

    assert Enum.map(steps, & &1.agent) ==
             ["explore", nil, "implementer", "implementer", "implementer", "reviewer"]

    assert Enum.all?(steps, &(is_binary(&1.prompt) and is_boolean(&1.parallel)))
  end

  test "the agents the default workflow delegates to are built-in subagents, and the orchestrator cannot write",
       %{ws: ws} do
    defs = Definitions.load(ws)

    for %{agent: agent} <- Workflow.default_steps(), agent != nil do
      assert {:ok, %{mode: :subagent}} = Definitions.fetch(defs, agent)
    end

    {:ok, workflow} = Definitions.fetch(defs, "workflow")
    assert workflow.mode == :primary
    assert workflow.model == "expensive"
    names = Enum.map(Troupe.Tools.for_definition(workflow), &Troupe.Tool.name/1)
    assert "delegate" in names
    assert "read_branch" in names
    refute "write_file" in names
    refute "edit_file" in names
    refute "shell" in names
  end

  test "available lists default first, then the workflows on disk", %{ws: ws} do
    assert Workflow.available(ws) == ["default"]
    write!(ws, ".troupe/workflows/release.json", ~s|[{"name":"a","prompt":"p"}]|)
    write!(ws, ".troupe/workflows/audit.json", ~s|[{"name":"a","prompt":"p"}]|)
    assert Workflow.available(ws) == ["default", "audit", "release"]
  end

  test "load reads a named workflow's owners and parallel flags", %{ws: ws} do
    write!(ws, ".troupe/workflows/custom.json", """
    [{"name":"build","agent":"implementer","prompt":"build it"},
     {"name":"docs","agent":"implementer","prompt":"write docs","parallel":true},
     {"name":"decide","prompt":"ship or not"}]
    """)

    assert Workflow.load(ws, "custom") == [
             %{name: "build", agent: "implementer", prompt: "build it", parallel: false},
             %{name: "docs", agent: "implementer", prompt: "write docs", parallel: true},
             %{name: "decide", agent: nil, prompt: "ship or not", parallel: false}
           ]
  end

  test "load falls back to the default for a missing, malformed or blank-agent file",
       %{ws: ws} do
    assert Workflow.load(ws, "nope") == Workflow.default_steps()
    assert Workflow.load(ws, "default") == Workflow.default_steps()
    write!(ws, ".troupe/workflows/bad.json", "not json")
    assert Workflow.load(ws, "bad") == Workflow.default_steps()
    write!(ws, ".troupe/workflows/b.json", ~s|[{"name":"a","agent":"","prompt":"p"}]|)
    assert [%{agent: nil}] = Workflow.load(ws, "b")
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

  test "plan without parallel steps leaves out the concurrency rule, and an empty list is the default" do
    plan = Workflow.plan([Workflow.step("only", "implementer", "do it")], "t")
    refute plan =~ "run concurrently"
    assert plan =~ "Every delegate prompt must stand alone"
    assert Workflow.plan([], "t") == Workflow.plan(Workflow.default_steps(), "t")
  end
end
