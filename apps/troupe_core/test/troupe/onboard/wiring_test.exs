defmodule Troupe.Onboard.WiringTest do
  @moduledoc """
  `troupe onboard` asks the agents and commands source without being told to, and on a
  machine a worker runs on onboarding is one refusal, from `troupe onboard` and the
  onboarding tool alike (#516, Decisions 823, 824 and 826).

  Not async: the worker's mark is an environment variable.
  """

  use ExUnit.Case, async: false

  alias Troupe.Onboard
  alias Troupe.Onboard.AgentsAndCommands
  alias Troupe.Tools.OnboardWrite

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-onboard-wiring-#{System.unique_integer([:positive])}")

    dirs = Map.new(~w(workspace config home state), &{String.to_atom(&1), Path.join(base, &1)})
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(base) end)

    opts = [config_dir: dirs.config, home: dirs.home, state_dir: dirs.state]
    Map.put(dirs, :opts, opts)
  end

  test "the agents and commands source is registered", _ctx do
    assert AgentsAndCommands in Onboard.sources()
  end

  test "a Claude Code subagent is proposed with no source named", ctx do
    path = Path.join(ctx.workspace, ".claude/agents/reviewer.md")
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "---\nname: reviewer\ndescription: Reviews a change\ntools: Read\n---\nYou review.\n"
    )

    assert %{proposals: proposals, refused: []} = Onboard.plan(ctx.workspace, ctx.opts)
    assert Enum.any?(proposals, &(&1.proposal.path == "agents/reviewer.md"))
  end

  describe "on a machine a worker runs on" do
    setup do
      previous = System.get_env("TROUPE_WORKER_AUTOSTART")
      System.put_env("TROUPE_WORKER_AUTOSTART", "true")

      on_exit(fn ->
        if previous,
          do: System.put_env("TROUPE_WORKER_AUTOSTART", previous),
          else: System.delete_env("TROUPE_WORKER_AUTOSTART")
      end)
    end

    test "the plan is one refusal and no source is asked", ctx do
      assert %{proposals: [], sources: [], refused: [%{reason: reason}]} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert reason =~ "not on a pod"
    end

    test "the onboarding tool refuses before it reads anything", ctx do
      ctx_map = %{session_id: nil, bundle: nil, workspace: %{root_real: ctx.workspace}}

      args = %{
        "target" => "repo",
        "path" => "agents/x.md",
        "source" => "missing.md",
        "content" => "x"
      }

      assert {:error, reason} = OnboardWrite.run(args, ctx_map)
      assert reason =~ "not on a pod"
    end
  end
end
