defmodule Troupe.CommandModeTest do
  @moduledoc """
  A session's screen is command mode (#502 parts A and 3, TUI Decision 155): the session's
  own agent is not a window to chat to, a plain line starts the default agent in the
  checkout, Ctrl-N chooses the agent (its instruction on screen) and a worktree, and the
  screen with no window activated collects every branch and worktree.

  On the chunk's tip a line typed with no window activated went to the session's own
  agent (`Client.send_input(sid, "root", …)`), a new session showed a `root` window that
  said `running` before anything ran, and a slash command typed into a window's box was
  sent to its agent as words.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers, only: [start_remote!: 1, connect!: 2, attach!: 2]
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.UI.TUI.Model

  @claude "# Rules\n\nRun the tests with `mix test` before you commit.\n"

  defp ready(pid) do
    eventually(fn -> user_state(pid).commands != [] end)
    eventually(fn -> Model.session_window(user_state(pid).model) != nil end)
  end

  defp notices(pid), do: user_state(pid).model.notices

  # A git repository whose fake's configuration is committed, so a branch in a worktree
  # of its own reads it there too.
  defp repo_with_fake!(script) do
    ws = git_init!(tmp_workspace())
    {sid, _, ^ws} = start_session!(workspace: ws, script: script)
    run_git!(ws, ["add", "-A"])
    run_git!(ws, ["commit", "-q", "-m", "fake model"])
    {sid, ws}
  end

  test "a new session opens in command mode: no window of its own, nothing running" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    ready(pid)

    model = user_state(pid).model
    assert Model.windows(model) == []
    assert Model.session_window(model).state == :idle
    assert Model.attention_summary(model) == "idle"

    text = screen_text(pid, session)
    assert text =~ "command mode"
    assert text =~ "Enter starts it on build in the checkout"
    assert text =~ "model fake-model"
    assert text =~ "watch off"
    refute text =~ "root"
    refute text =~ "starting"
    refute text =~ "need input"

    GenServer.stop(pid, :normal)
  end

  test "a plain line starts build in the checkout, said first, and never reaches the session's agent" do
    {sid, _, _} = start_session!(script: [{:text, "Found it in parse/1."}])
    {pid, session} = start_tui(sid)
    ready(pid)

    type(pid, "fix the failing test")
    press(pid, "enter")

    spawned = await_event("build-1", :branch_spawned)
    assert spawned.data.name == "build"
    assert spawned.data.isolation == :shared
    assert spawned.data.prompt == "fix the failing test"
    assert Enum.any?(notices(pid), &(&1 =~ "starting build in the checkout"))
    assert user_state(pid).cmd_text == ""

    await_state("build-1", :done, 10_000)
    assert events_of(sid, "root", :input) == []

    # Its row in the collection: the digit, the window, its agent, its state, the last
    # thing it said, and what its turn cost, as the turn's own line says it.
    eventually(fn ->
      text = screen_text(pid, session)

      case Model.windows(user_state(pid).model) do
        [%{path: "build-1", profile: "build"} = w] ->
          Model.cost(w) != "" and text =~ "1 build-1" and text =~ "Found it in parse/1." and
            text =~ Model.cost(w)

        _ ->
          false
      end
    end)

    GenServer.stop(pid, :normal)
  end

  test "the start's question is asked, and answered, before a plain line starts anything" do
    ws = git_init!(tmp_workspace(%{"CLAUDE.md" => @claude}))
    {sid, _, _} = start_session!(workspace: ws, script: [{:text, "on it"}])
    {pid, session} = start_tui(sid)
    ready(pid)

    eventually(fn -> Model.asking(user_state(pid).model) != nil end)
    eventually(fn -> screen_text(pid, session) =~ "Onboard 1 file from Claude Code" end)

    # Said once, first, and not again as the session's own activity.
    assert [_, _] = String.split(screen_text(pid, session), "waiting for you")

    type(pid, "fix the failing test")
    press(pid, "enter")
    assert user_state(pid).cmd_text == "fix the failing test"
    assert Enum.any?(notices(pid), &(&1 =~ "answer the start's question first"))
    refute Map.has_key?(user_state(pid).model.windows, "build-1")

    # The question's keys answer it once nothing is typed; then the line starts its branch.
    press(pid, "esc")
    press(pid, "n")
    eventually(fn -> Model.asking(user_state(pid).model) == nil end)

    type(pid, "fix the failing test")
    press(pid, "enter")
    assert %{data: %{name: "build"}} = await_event("build-1", :branch_spawned)

    GenServer.stop(pid, :normal)
  end

  test "Ctrl-N chooses the agent with its instruction on screen, then a worktree, and starts it there" do
    script = [
      {:tool, "write_file", %{"path" => "note.txt", "content" => "one\ntwo\n"}},
      {:text, "Wrote the note."}
    ]

    {sid, ws} = repo_with_fake!(script)
    {pid, session} = start_tui(sid)
    ready(pid)

    {:ok, agents} = Client.profiles({:local, ws})
    names = Enum.map(agents, & &1.name)
    assert "quick" in names

    type(pid, "write the note")
    press(pid, "n", ["ctrl"])
    assert user_state(pid).focus == :chooser

    # The default agent is the one selected, and what it is told is on screen: the
    # instruction `agents.get` serves, or on a daemon from before it the description.
    for _ <- 1..length(names), do: press(pid, "up")
    steps = Enum.find_index(names, &(&1 == "quick"))
    for _ <- 1..steps//1, do: press(pid, "down")

    assert %{name: "quick"} =
             Enum.at(user_state(pid).chooser.agents, user_state(pid).chooser.cursor)

    {:ok, quick} = Client.agent_definition(sid, "quick")
    said = (quick.prompt || quick.description) |> String.split("\n", trim: true) |> hd()
    text = screen_text(pid, session)
    assert text =~ "quick — its instruction"
    assert text =~ String.slice(said, 0, 40)

    press(pid, "enter")
    assert user_state(pid).chooser.step == :where
    assert screen_text(pid, session) =~ "a worktree of its own"
    press(pid, "w")

    spawned = await_event("quick-1", :branch_spawned)
    assert spawned.data.name == "quick"
    assert spawned.data.isolation == :worktree
    assert spawned.data.prompt == "write the note"
    assert user_state(pid).focus == :command
    created = await_event("quick-1", :worktree_created)
    await_state("quick-1", :done, 10_000)
    assert File.read!(Path.join(created.data.path, "note.txt")) == "one\ntwo\n"

    # The worktree's row: its branch, ahead of and behind the checkout's, the two lines
    # its new file would bring, dirty, and whose it is.
    eventually(
      fn ->
        text = screen_text(pid, session)

        text =~ "worktrees" and text =~ created.data.git_branch and text =~ "↑0 ↓0" and
          text =~ "+2 −0" and text =~ "dirty" and text =~ "quick-1 · alive" and
          text =~ "this session's checkout"
      end,
      10_000
    )

    GenServer.stop(pid, :normal)
  end

  test "an agent chosen with nothing typed waits on the command line for the task" do
    {sid, _, _} = start_session!(script: [{:text, "Planned."}])
    {pid, session} = start_tui(sid)
    ready(pid)

    press(pid, "n", ["ctrl"])
    assert user_state(pid).focus == :chooser
    press(pid, "enter")
    press(pid, "c")

    assert user_state(pid).focus == :command
    assert %{agent: "build", where: :checkout} = user_state(pid).choice
    assert screen_text(pid, session) =~ "build in the checkout: type the task"

    type(pid, "plan the release")
    press(pid, "enter")
    spawned = await_event("build-1", :branch_spawned)
    assert spawned.data.prompt == "plan the release"
    assert spawned.data.isolation == :shared
    assert user_state(pid).choice == nil

    GenServer.stop(pid, :normal)
  end

  # TUI Decision 155, amending Decision 763 in command mode: a command a file defines is
  # work like a plain line, so it starts a branch, on the agent its file names or the
  # default one, and the command runs there; the session's own agent hears nothing.
  test "a repository's command typed in command mode starts a branch on the agent its file names" do
    ws =
      tmp_workspace(%{
        ".troupe/commands/review.md" =>
          "---\ndescription: Review it\nagent: plan\n---\nReview $ARGUMENTS and say what you would change.\n",
        ".troupe/commands/standup.md" => "Say what changed since yesterday.\n"
      })

    {sid, _, _} = start_session!(workspace: ws, script: [{:text, "Reviewed."}, {:text, "Said."}])
    {pid, _session} = start_tui(sid)
    ready(pid)
    eventually(fn -> Enum.any?(user_state(pid).commands, &(&1["name"] == "review")) end)

    type(pid, "/review the parser")
    press(pid, "enter")

    assert %{data: %{name: "plan", isolation: :shared}} = await_event("plan-1", :branch_spawned)
    assert Enum.any?(notices(pid), &(&1 =~ "starting /review on plan in the checkout"))

    input = await_event("plan-1", :input, 10_000)
    assert input.data.content == "Review the parser and say what you would change."

    type(pid, "/standup")
    press(pid, "enter")
    assert %{data: %{name: "build"}} = await_event("build-1", :branch_spawned)
    assert %{data: %{content: "Say what changed since yesterday."}} = await_event("build-1", :input)

    assert events_of(sid, "root", :input) == []

    GenServer.stop(pid, :normal)
  end

  test "a slash command typed into a window's box runs as a command, and other words reach its agent" do
    {sid, _, _} = start_session!(script: [{:text, "done"}, {:text, "noted"}])
    {pid, _session} = start_tui(sid)
    ready(pid)

    type(pid, "look at the tests")
    press(pid, "enter")
    await_state("build-1", :done, 10_000)
    press(pid, "1")
    assert user_state(pid).focus == {:window, "build-1"}

    type(pid, "/goal ship the release")
    press(pid, "enter")
    eventually(fn -> Model.goal(user_state(pid).model) == "ship the release" end)
    refute Enum.any?(events_of(sid, "build-1", :input), &(&1.data.content =~ "/goal"))

    type(pid, "/usr/bin is missing")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(events_of(sid, "build-1", :input), &(&1.data.content == "/usr/bin is missing"))
    end)

    GenServer.stop(pid, :normal)
  end

  describe "a session on a plane" do
    @describetag :remote

    test "shows its agent among the work, and a plain line is said to it, since a pod starts no branches" do
      session =
        FakeRemote.session(
          id: "s-cm",
          profile: "code",
          title: "on the plane",
          events: [%{"type" => "message.completed", "data" => %{"text" => "first line"}}]
        )

      {remote, url} = start_remote!(sessions: [session])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-cm")

      {pid, screen} = start_tui(sid)
      eventually(fn -> user_state(pid).model.windows["code-1"] != nil end)

      eventually(fn ->
        text = screen_text(pid, screen)
        text =~ "command mode" and text =~ "1 code-1  code"
      end)

      assert screen_text(pid, screen) =~ "the session's agent · Enter sends"

      type(pid, "carry on")
      press(pid, "enter")

      eventually(fn ->
        Enum.any?(FakeRemote.calls(remote), &match?({"input.send", %{"text" => "carry on"}}, &1))
      end)

      press(pid, "n", ["ctrl"])
      assert user_state(pid).focus == :command
      assert Enum.any?(notices(pid), &(&1 =~ "runs one profile"))

      GenServer.stop(pid, :normal)
    end
  end
end
