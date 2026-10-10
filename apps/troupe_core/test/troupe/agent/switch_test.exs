defmodule Troupe.Agent.SwitchTest do
  @moduledoc """
  A branch's agent changes (#503, Decision 841). A branch is a session with a `parent`
  (Decision 646), so its agent is its root's, and `Troupe.switch_profile/3` changes it:
  the conversation stays, the definition applies from the next turn, read from its file
  as it is at the switch, so an agent written after the branch started can be switched
  to; the tools it no longer holds are gone from that turn, its permissions are the new
  definition's, and `profile_switched` says what changed and who changed it. A workspace's
  `auto` still waits for trust (Decision 825). An unknown name, or a subagent, is refused
  with nothing written.
  """

  use Troupe.SessionCase, async: true

  @reviewer """
  ---
  description: Reviews without writing.
  mode: primary
  tools:
    - read_file
    - grep
    - finish
  permissions:
    write_file: deny
    edit_file: deny
    shell: deny
  ---
  You review the work and change nothing.
  """

  defp branch(context, opts \\ []) do
    %{session: parent} = start_session(context, steps: [{:text, "parent"}])

    start_session(
      context,
      [parent: parent.id, agent: "build"] ++
        Keyword.put_new(opts, :steps, [{:text, "built"}, {:text, "reviewed"}])
    )
  end

  test "a branch switches to an agent written after it started, and keeps its conversation",
       context do
    %{session: branch, fake: fake} = branch(context)
    sid = branch.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "build it")
    await_state(sid, [:idle])

    write_file(context, ".troupe/agents/reviewer-two.md", @reviewer)

    assert {:ok, %{name: "reviewer-two"}} =
             Troupe.switch_profile(sid, "reviewer-two", command_id: "c-switch")

    switched = await_event(sid, :profile_switched)
    assert switched.agent == ["root"]
    assert switched.data["from"] == "build"
    assert switched.data["to"] == "reviewer-two"
    assert switched.data["layer"] == "project"
    assert switched.data["command_id"] == "c-switch"
    assert "shell" in switched.data["tools_removed"]
    assert "write_file" in switched.data["tools_removed"]
    assert switched.data["tools_added"] == []

    Troupe.send_input(sid, "now review it")
    await_state(sid, [:idle])

    request = fake |> Fake.requests() |> List.last()
    tools = Enum.map(request.tools, & &1.name)
    refute "shell" in tools
    refute "write_file" in tools
    assert "read_file" in tools
    assert request.system =~ "You review the work and change nothing."
    # The first turn's input and answer are still there, before this turn's input.
    assert length(request.messages) >= 3

    # The listing saying the same is `Troupe.Gateway.AgentsApiTest`'s, over the wire.
    assert Troupe.snapshot(sid).profile == "reviewer-two"
  end

  test "a tool the new definition denies is refused when the model asks for it anyway",
       context do
    %{session: branch} =
      branch(context,
        steps: [
          {:text, "built"},
          {:tools, [{"shell", %{"command" => "echo should-not-run"}}]},
          {:text, "reviewed"}
        ]
      )

    sid = branch.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "build it")
    await_state(sid, [:idle])

    write_file(context, ".troupe/agents/reviewer-two.md", @reviewer)
    assert {:ok, _} = Troupe.switch_profile(sid, "reviewer-two")
    await_event(sid, :profile_switched)

    Troupe.send_input(sid, "review it")
    await_state(sid, [:idle])

    shell =
      sid |> events_of_type(:tool_call_completed) |> Enum.find(&(&1.data["name"] == "shell"))

    refute shell.data["ok"]
    refute shell.data["content"] =~ "should-not-run"
  end

  test "an unknown agent and a subagent are refused, and nothing is written", context do
    %{session: branch} = branch(context)
    sid = branch.id

    assert {:error, {:unknown_agent, "nobody"}} = Troupe.switch_profile(sid, "nobody")
    assert {:error, {:not_primary, "explore"}} = Troupe.switch_profile(sid, "explore")
    assert events_of_type(sid, :profile_switched) == []
    assert Troupe.snapshot(sid).profile == "build"
  end

  test "a branch that finished switches, and the next input runs on the new agent", context do
    %{session: branch, fake: fake} =
      branch(context,
        steps: [{:tools, [{"finish", %{"summary" => "built it"}}]}, {:text, "reviewed"}]
      )

    sid = branch.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "build it")
    await_state(sid, [:done])

    write_file(context, ".troupe/agents/reviewer-two.md", @reviewer)
    assert {:ok, _} = Troupe.switch_profile(sid, "reviewer-two")
    await_event(sid, :profile_switched)

    Troupe.send_input(sid, "review it")
    await_state(sid, [:idle, :done])

    assert (fake |> Fake.requests() |> List.last()).system =~ "You review the work"
  end

  test "a restarted agent comes back on the agent it was switched to", context do
    %{session: branch} = branch(context)
    sid = branch.id
    Troupe.subscribe(sid)

    # Written after the session started, so the snapshot it was started with has no such
    # agent: the replay reads it again, as the switch did.
    write_file(context, ".troupe/agents/reviewer-two.md", @reviewer)
    assert {:ok, _} = Troupe.switch_profile(sid, "reviewer-two")
    await_event(sid, :profile_switched)

    agent = Registry.agent_pid(sid, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
    await_event(sid, :agent_restarted)

    assert Troupe.snapshot(sid).profile == "reviewer-two"
  end

  test "a workspace's auto still asks after a switch until the workspace is trusted",
       context do
    write_file(context, ".troupe/agents/runner.md", """
    ---
    description: Runs things for this repository.
    mode: primary
    permissions:
      shell: auto
    ---
    You run things.
    """)

    %{session: branch} =
      branch(context,
        steps: [
          {:text, "built"},
          {:tools, [{"shell", %{"command" => "echo ran-it"}}]},
          {:text, "done"}
        ],
        config_overrides: [auto_approve: false, approvals: :deny, trusted_workspaces: []]
      )

    sid = branch.id
    Troupe.subscribe(sid)
    Troupe.send_input(sid, "build it")
    await_state(sid, [:idle])

    assert {:ok, _} = Troupe.switch_profile(sid, "runner")
    await_event(sid, :profile_switched)

    Troupe.send_input(sid, "run it")
    await_state(sid, [:idle])

    assert [asked] = events_of_type(sid, :approval_requested)
    assert asked.data["tool"] == "shell"

    shell =
      sid |> events_of_type(:tool_call_completed) |> Enum.find(&(&1.data["name"] == "shell"))

    refute shell.data["ok"]
  end
end
