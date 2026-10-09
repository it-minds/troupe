defmodule Troupe.Agent.WorkspacePermissionsTest do
  @moduledoc """
  A workspace's own agent files and what they may let run without asking (#511,
  Decision 825): a `permissions:` entry of `auto` in `.troupe/agents/*.md` applies only
  once the workspace is trusted (`trusted_workspaces`, Decision 686), and until then the
  tool keeps its own permission, so `shell` asks. The person's own agents and the
  built-ins are not the workspace's, and keep what they say.

  The suite trusts the system's temp directory (`test_helper.exs`), so an untrusted
  workspace here is one whose session is given an empty `trusted_workspaces`, which is
  how the session reads the list.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}

  @runner """
  ---
  description: runs things for this repository
  mode: primary
  permissions:
    shell: auto
    read_file: auto
    write_file: deny
  ---
  You run things.
  """

  defp run_shell(context, trusted) do
    write_file(context, ".troupe/agents/runner.md", @runner)

    %{session: session} =
      start_session(context,
        agent: "runner",
        steps: [{:tools, [{"shell", %{"command" => "echo ran-it"}}]}, {:text, "done"}],
        # Nobody to ask: an `ask` is answered `deny` at once, so the test sees the
        # question without waiting on a person.
        config_overrides: [
          auto_approve: false,
          approvals: :deny,
          trusted_workspaces: if(trusted, do: [context.workspace], else: [])
        ]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "run it")

    assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 10_000

    sid
  end

  defp shell_result(sid) do
    sid |> events_of_type(:tool_call_completed) |> Enum.find(&(&1.data["name"] == "shell"))
  end

  test "in a workspace that is not trusted, its agent's shell: auto asks", context do
    sid = run_shell(context, false)

    assert [asked] = events_of_type(sid, :approval_requested)
    assert asked.data["tool"] == "shell"
    refute shell_result(sid).data["ok"]
    refute shell_result(sid).data["content"] =~ "ran-it"
  end

  test "the same workspace trusted runs its agent's shell without asking", context do
    sid = run_shell(context, true)

    assert events_of_type(sid, :approval_requested) == []
    assert shell_result(sid).data["ok"]
    assert shell_result(sid).data["content"] =~ "ran-it"
  end

  describe "Definition.permission/3" do
    setup do
      {:ok, runner} = Definition.parse("runner", @runner, :project)
      %{runner: runner}
    end

    test "a workspace's auto is the tool's own permission until it is trusted", %{runner: runner} do
      held = Definition.trust(runner, false, "/repo")

      assert Definition.permission(held, "shell", :ask) == :ask
      # Narrowing is the file's to do whether or not anybody trusts it.
      assert Definition.permission(held, "write_file", :ask) == :deny
      # A tool that runs unasked anyway still does.
      assert Definition.permission(held, "read_file", :auto) == :auto

      trusted = Definition.trust(runner, true, "/repo")
      assert Definition.permission(trusted, "shell", :ask) == :auto
      assert trusted.notes == []
    end

    test "a workspace's definition nobody vouched for asks", %{runner: runner} do
      assert Definition.permission(runner, "shell", :ask) == :ask
    end

    test "the note says what is held back, why, and what trusts it", %{runner: runner} do
      held = Definition.trust(runner, false, "/repo")

      assert [%{key: "permissions", reason: reason}] = held.notes
      assert reason =~ "shell: auto applies once this workspace is trusted"
      assert reason =~ "until then shell asks"
      assert reason =~ "troupe config trust /repo"
      # read_file runs unasked whatever the file says, so nothing is held back for it.
      refute reason =~ "read_file"

      # Stamping twice says it once.
      assert Definition.trust(held, false, "/repo").notes == held.notes
    end

    test "the person's own agents and the built-ins keep their auto, trusted or not" do
      {:ok, mine} = Definition.parse("runner", @runner, :global)
      assert Definition.permission(Definition.trust(mine, false, "/repo"), "shell", :ask) == :auto
      assert Definition.trust(mine, false, "/repo").notes == []

      builtins = Definitions.load(System.tmp_dir!())

      for definition <- Definitions.all(builtins),
          definition.source == :builtin,
          {tool, :auto} <- definition.permissions do
        assert Definition.permission(Definition.trust(definition, false, "/repo"), tool, :ask) ==
                 :auto
      end
    end
  end
end
