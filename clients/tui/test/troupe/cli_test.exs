defmodule Troupe.CLITest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.CLI
  alias Troupe.UI.Headless.Printer

  test "parses the documented command lines" do
    assert {:ok, %{mode: :tui, watch: false}} = CLI.parse([])
    assert {:ok, %{mode: :tui, watch: true}} = CLI.parse(["--watch"])

    assert {:ok, %{mode: :run, agent: "code", task: "fix it", headless: true}} =
             CLI.parse(["run", "fix it", "--headless"])

    assert {:ok, %{mode: :run, agent: "plan", task: "x", worktree: true, auto_approve: true}} =
             CLI.parse(["run", "plan", "x", "--worktree", "--auto-approve"])

    assert {:ok, %{mode: :resume, session_id: "abc"}} = CLI.parse(["resume", "abc"])
    assert {:ok, %{mode: :resume, session_id: nil}} = CLI.parse(["resume"])
    assert {:ok, %{mode: :version}} = CLI.parse(["--version"])
    assert {:error, _} = CLI.parse(["--bogus"])
    assert {:error, _} = CLI.parse(["run"])
    assert CLI.version() =~ "troupe 0.1.0"
  end

  test "parses the remote command lines" do
    assert {:ok, %{mode: :login, plane_url: "https://plane.example"}} =
             CLI.parse(["login", "https://plane.example"])

    assert {:error, _} = CLI.parse(["login"])

    assert {:ok, %{mode: :logout, plane_url: nil, all: false}} = CLI.parse(["logout"])
    assert {:ok, %{mode: :logout, all: true}} = CLI.parse(["logout", "--all"])

    assert {:ok, %{mode: :logout, plane_url: "https://plane.example"}} =
             CLI.parse(["logout", "https://plane.example"])

    assert {:ok, %{mode: :whoami, plane_url: nil}} = CLI.parse(["whoami"])

    assert {:ok, %{mode: :whoami, plane_url: "https://plane.example"}} =
             CLI.parse(["whoami", "https://plane.example"])

    # `--remote` stays the TUI: HQ is a page, not a mode
    assert {:ok, %{mode: :tui, remote: true, plane_url: nil}} = CLI.parse(["--remote"])

    assert {:ok, %{mode: :tui, remote: true, plane_url: "https://plane.example"}} =
             CLI.parse(["--remote", "https://plane.example"])

    assert {:ok, %{mode: :tui, remote: false}} = CLI.parse([])
    assert CLI.usage() =~ "troupe login"
    assert CLI.usage() =~ "troupe --remote"
  end

  # nil, not false: no flag has to stay distinguishable from `--mouse`, because
  # only then can the `mouse` setting decide.
  test "the mouse flag is tri-state" do
    assert {:ok, %{mode: :tui, mouse: nil}} = CLI.parse([])
    assert {:ok, %{mode: :tui, mouse: false}} = CLI.parse(["--no-mouse"])
    assert {:ok, %{mode: :tui, mouse: true}} = CLI.parse(["--mouse"])
    assert {:ok, %{mode: :resume, mouse: false}} = CLI.parse(["resume", "--no-mouse"])
  end

  test "headless printer prints agent_path-prefixed lines and reports rest" do
    ws = tmp_workspace()

    script = [
      {:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}},
      {:tool, "shell", %{"command" => "cat out.txt"}},
      {:finish, "wrote and read"}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "code-1",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    {:ok, path} = Troupe.dispatch(sid, "code", "write then read")
    assert_receive {:rest, 0}, 10_000
    {_, out} = StringIO.contents(io)
    assert out =~ "#{path}> spawned /code (shared)"
    assert out =~ "#{path}> < write then read"
    assert out =~ "#{path}> → write_file"
    assert out =~ "#{path}> ✓ call_2: hi"
    assert out =~ "#{path}> [done_unread] wrote and read"
    assert Enum.all?(String.split(String.trim(out), "\n"), &String.starts_with?(&1, "code-1> "))
  end

  # Nobody can press a key in headless mode, so a budget question the printer does
  # not answer leaves the run blocked in `wait()` until the user kills it.
  test "headless printer stops a branch whose budget ran out instead of waiting forever" do
    ws = tmp_workspace(%{"f.txt" => "x"})
    script = List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 10)
    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "code-1",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    {:ok, path} = Troupe.dispatch(sid, "code", %{prompt: "loop", budget: %{max_turns: 1}})
    assert_receive {:rest, 0}, 10_000

    {_, out} = StringIO.contents(io)
    assert out =~ "#{path}> budget exhausted; headless mode stops here"
    assert window(sid, path).reason == :budget_exhausted
  end

  # With options offered the first is a better stand-in than boilerplate prose:
  # it is an answer the model can actually act on.
  test "headless printer answers a question with its first option when one is offered" do
    ws = tmp_workspace()

    script = [
      {:tool, "ask_user", %{"question" => "Which database?", "options" => ["postgres", "sqlite"]}},
      {:finish, "chose one"}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "code-1",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    {:ok, path} = Troupe.dispatch(sid, "code", "ask me")
    assert_receive {:rest, 0}, 10_000

    {_, out} = StringIO.contents(io)
    assert out =~ ~s|#{path}> question: Which database? (headless: answered "postgres")|

    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text == "postgres"
  end

  test "headless printer falls back to judgement prose when a question offers no options" do
    ws = tmp_workspace()
    script = [{:tool, "ask_user", %{"question" => "Anything?"}}, {:finish, "guessed"}]
    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "code-1",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    {:ok, _path} = Troupe.dispatch(sid, "code", "ask me")
    assert_receive {:rest, 0}, 10_000

    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text =~ "proceed with your best judgement"
  end
end
