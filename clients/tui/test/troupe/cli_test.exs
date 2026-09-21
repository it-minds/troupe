defmodule Troupe.CLITest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.CLI
  alias Troupe.UI.Headless.Printer

  test "parses the documented command lines" do
    assert {:ok, %{mode: :tui, watch: false}} = CLI.parse([])
    assert {:ok, %{mode: :tui, watch: true}} = CLI.parse(["--watch"])

    assert {:ok, %{mode: :run, agent: "build", task: "fix it", headless: true}} =
             CLI.parse(["run", "fix it", "--headless"])

    assert {:ok, %{mode: :run, agent: "plan", task: "x", worktree: true, auto_approve: true}} =
             CLI.parse(["run", "plan", "x", "--worktree", "--auto-approve"])

    assert {:ok, %{mode: :run, agent: "build", task: "x", full_send: true}} =
             CLI.parse(["run", "x", "--full-send"])

    assert {:ok, %{mode: :tui, full_send: true}} = CLI.parse(["--full-send"])

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
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    say!(sid, "write then read")
    assert_receive {:rest, 0}, 15_000
    {_, out} = StringIO.contents(io)
    assert out =~ "root> < write then read"
    assert out =~ "root> → write_file"
    assert out =~ "root> → shell"
    assert out =~ "hi"

    assert Enum.all?(
             String.split(String.trim(out), "
"),
             &String.starts_with?(&1, "root> ")
           )
  end

  # Nobody can press a key in headless mode: an approval the printer cannot answer is
  # denied, and the run still rests.
  test "headless printer denies an approval it cannot ask about, and the session still rests" do
    ws = tmp_workspace()
    script = [{:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}}, {:finish, "tried"}]
    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: false)
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    say!(sid, "write")
    assert_receive {:rest, 0}, 15_000
    {_, out} = StringIO.contents(io)
    assert out =~ "approval needed for write_file; headless mode denies it"
    refute File.exists?(Path.join(ws, "out.txt"))
  end
end
