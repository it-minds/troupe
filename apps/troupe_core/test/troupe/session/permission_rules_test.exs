defmodule Troupe.Session.PermissionRulesTest do
  @moduledoc """
  The harness applies the configuration's per-tool rules (#658) before the
  approval flow: a `deny` refuses the call naming the rule and where it came from, an
  `ask` asks even under `auto_approve` and says which rule asked, and an `allow` runs a
  call that would have asked.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Config.Permissions
  alias Troupe.Session.Approvals

  defp project_rules(context, yaml) do
    File.mkdir_p!(Path.join(context.workspace, ".troupe"))
    File.write!(Path.join(context.workspace, ".troupe/config.yaml"), "permissions:\n" <> yaml)
  end

  defp user_rules(set), do: Permissions.from(set, :user, "/home/me/.config/troupe/config.yaml")

  test "a deny refuses the call before it runs, naming the rule and its file", context do
    project_rules(context, "  deny: [\"shell(touch)\"]\n")

    %{session: session} =
      start_session(context,
        steps: [
          {:tools, [{"shell", %{"command" => "touch ran.txt"}}]},
          {:text, "done without it"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    await_state(session.id, [:idle], 10_000)

    [completed] = events_of_type(session.id, "tool_call_completed")
    refute completed.data["ok"]
    assert completed.data["content"] =~ "refused by the rule deny shell(touch)"
    assert completed.data["content"] =~ "this project's .troupe/config.yaml"
    refute File.exists?(Path.join(context.workspace, "ran.txt"))
    assert events_of_type(session.id, "approval_requested") == []
  end

  test "a deny refuses a tool that runs inside the agent too", context do
    project_rules(context, "  deny: [todo_write]\n")

    %{session: session} =
      start_session(context,
        steps: [
          {:tools, [{"todo_write", %{"items" => [%{"content" => "a"}]}}]},
          {:text, "done"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    await_state(session.id, [:idle], 10_000)

    [completed] = events_of_type(session.id, "tool_call_completed")
    assert completed.data["content"] =~ "refused by the rule deny todo_write"
    assert events_of_type(session.id, "todo_updated") == []
  end

  test "an ask asks even under auto_approve, and the request names the rule", context do
    project_rules(context, "  ask: [needs_approval]\n")

    %{session: session} =
      start_session(context,
        config_overrides: [auto_approve: true],
        steps: [{:tools, [{"needs_approval", %{"n" => 1}}]}, {:text, "done"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    await_event(session.id, :approval_requested)

    [requested] = events_of_type(session.id, "approval_requested")

    assert %{"action" => "ask", "rule" => "needs_approval", "scope" => "project"} =
             requested.data["rule"]

    assert [pending] = Approvals.pending(session.id)
    assert pending.rule["rule"] == "needs_approval"
  end

  test "an ask is not covered by an earlier allow for the session", context do
    %{session: session} =
      start_session(context,
        config_overrides: [
          auto_approve: false,
          permissions: user_rules(%{"ask" => ["needs_approval"]})
        ],
        steps: [
          {:tools, [{"needs_approval", %{"n" => 1}}]},
          {:tools, [{"needs_approval", %{"n" => 2}}]},
          {:text, "done"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    await_event(session.id, :approval_requested)
    [first] = Approvals.pending(session.id)
    Approvals.decide(session.id, first.call_id, :allow_session, nil)

    eventually(fn -> length(events_of_type(session.id, "approval_requested")) == 2 end)
  end

  test "an allow runs a call that would have asked, unattended or not", context do
    for approvals <- [:wait, :deny] do
      %{session: session} =
        start_session(context,
          config_overrides: [
            auto_approve: false,
            approvals: approvals,
            permissions: user_rules(%{"allow" => ["needs_approval"]})
          ],
          steps: [{:tools, [{"needs_approval", %{}}]}, {:text, "done"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "go")
      await_state(session.id, [:idle], 10_000)

      assert events_of_type(session.id, "approval_requested") == []
      [completed] = events_of_type(session.id, "tool_call_completed")
      assert completed.data["ok"], inspect(approvals)
      Troupe.stop_session(session.id)
    end
  end

  test "a branch a saved comment started holds every allow", context do
    {:ok, opts} =
      Troupe.Session.build_opts(
        workspace: context.workspace,
        hold_auto: true,
        config_overrides: [
          provider: "fake",
          state_dir: context.state_dir,
          permissions: user_rules(%{"allow" => ["shell"], "deny" => ["web_fetch"]})
        ]
      )

    assert Enum.map(opts[:config].permissions, &{&1.action, &1.text}) == [{:deny, "web_fetch"}]
  end

  defp eventually(check, deadline \\ 5_000) do
    cond do
      check.() ->
        :ok

      deadline <= 0 ->
        flunk("it did not happen")

      true ->
        Process.sleep(50)
        eventually(check, deadline - 50)
    end
  end
end
