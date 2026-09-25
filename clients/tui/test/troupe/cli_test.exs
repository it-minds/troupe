defmodule Troupe.CLITest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.{CLI, Client}
  alias Troupe.CLI.Runner
  alias Troupe.UI.Headless.Printer

  test "parses the documented command lines" do
    assert {:ok, %{mode: :tui, watch: nil}} = CLI.parse([])
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
    # The umbrella's `VERSION`, which the TUI shares with everything it is released with.
    assert CLI.version() == "troupe " <> (File.read!("../../VERSION") |> String.trim())
  end

  # The config files' `auto_approve`, `watch` and `full_send` apply to a session `troupe`
  # starts unless the command line says otherwise; it used to send all three as false.
  test "a session is asked for only the switches the command line gave" do
    session_config = fn argv ->
      {:ok, args} = CLI.parse(argv)
      CLI.session_config(args)
    end

    assert session_config.([]) == %{}
    assert session_config.(["run", "x", "--headless"]) == %{}
    assert session_config.(["--watch"]) == %{watch: true}
    assert session_config.(["--full-send"]) == %{full_send: true}

    assert session_config.(["run", "x", "--auto-approve", "--no-watch"]) ==
             %{auto_approve: true, watch: false}
  end

  test "parses the config command lines" do
    assert {:ok, %{mode: :config}} = CLI.parse(["config"])

    assert {:ok, %{mode: :config_explain, key: nil, json: false}} =
             CLI.parse(["config", "--explain"])

    assert {:ok, %{mode: :config_explain, key: "max_turns"}} =
             CLI.parse(["config", "--explain", "max_turns"])

    assert {:ok, %{mode: :config_explain, key: nil, json: true}} = CLI.parse(["config", "--json"])

    assert {:ok, %{mode: :config_explain, key: "models", json: true}} =
             CLI.parse(["config", "--explain", "models", "--json"])

    assert {:ok, %{mode: :config_validate, path: nil}} = CLI.parse(["config", "validate"])

    assert {:ok, %{mode: :config_validate, path: "a.yaml"}} =
             CLI.parse(["config", "validate", "a.yaml"])

    assert {:ok, %{mode: :config_migrate, path: nil, write: false}} =
             CLI.parse(["config", "migrate"])

    assert {:ok, %{mode: :config_migrate, path: nil, write: true}} =
             CLI.parse(["config", "migrate", "--write"])

    assert {:ok, %{mode: :config_pull}} = CLI.parse(["config", "pull"])
    assert CLI.usage() =~ "troupe config --explain"
  end

  test "config --explain and validate answer from the files, with the exit status" do
    ws = tmp_workspace(%{".troupe/config.yaml" => "max_turns: 12\nmax_tokns: 1\n"})

    {text, 0} = Troupe.Config.explain(ws, "max_turns")
    assert text =~ "max_turns = 12"

    {text, 1} = Troupe.Config.validate(ws, Path.join(ws, ".troupe/config.yaml"))
    assert text =~ "did you mean max_tokens?"
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

  # A session starts working the moment it is created, before anything can subscribe to
  # it, so a quick run can rest before the printer exists. Found by CI's clean-container
  # check, where a slow runner let the smoke run finish first and `troupe run --headless`
  # then waited for a rest it had already missed, until the job's timeout.
  test "headless printer reports a rest that happened before it started, and prints it once" do
    ws = tmp_workspace()

    script = [
      {:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}},
      {:finish, "done before anyone looked"}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    say!(sid, "write early")
    await_done()

    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    assert_receive {:rest, 0}, 5_000
    {_, out} = StringIO.contents(io)
    assert out =~ "root> → write_file"
    assert [_once] = Regex.scan(~r/^root> < write early$/m, out)
  end

  # Nobody can press a key in headless mode: an approval the printer cannot answer is
  # denied, and the run still rests — with 3, because what the agent was refused may be
  # what the task needed.
  test "headless printer denies an approval it cannot ask about, and the session still rests" do
    ws = tmp_workspace()
    script = [{:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}}, {:finish, "tried"}]
    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: false)
    {io, _} = printer!(sid)

    say!(sid, "write")
    assert_receive {:rest, 3}, 15_000
    out = contents(io)
    assert out =~ "approval needed for write_file; headless mode denies it"
    assert out =~ "root> exit 3: an approval was refused, with nobody to ask (use --auto-approve)"
    refute File.exists?(Path.join(ws, "out.txt"))
  end

  # Issue #127: a real model usually ends its turn with prose and never calls `finish`,
  # and a headless run waited for a `finish` that never came, until something killed it.
  test "headless printer rests when the agent's turn ends without finish" do
    ws = tmp_workspace()

    script = [
      {:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}},
      {:text_and_tools, "Wrote out.txt. I am done.", []}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script)
    {io, _} = printer!(sid)

    say!(sid, "write it")
    assert_receive {:rest, 0}, 15_000
    out = contents(io)
    assert out =~ "root> Wrote out.txt. I am done."
    refute out =~ "exit "
    assert File.read!(Path.join(ws, "out.txt")) == "hi"
  end

  test "headless printer reports a turn that ended before it started" do
    {sid, _, _} = start_session!(script: [{:text_and_tools, "answered early", []}])
    say!(sid, "answer early")
    await_event("root", :assistant_message, 10_000)
    await_state("root", :idle, 10_000)

    {io, _} = printer!(sid)
    assert_receive {:rest, 0}, 5_000
    assert [_once] = Regex.scan(~r/^root> answered early$/m, contents(io))
  end

  test "headless printer rests without finish when an approval was refused, with 3" do
    ws = tmp_workspace()

    script = [
      {:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}},
      {:text_and_tools, "I was not allowed to write out.txt.", []}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: false)
    {io, _} = printer!(sid)

    say!(sid, "write")
    assert_receive {:rest, 3}, 15_000
    assert contents(io) =~ "root> I was not allowed to write out.txt."
    refute File.exists?(Path.join(ws, "out.txt"))
  end

  test "headless printer exits 1 when the model request fails, and says so" do
    {sid, _, _} = start_session!(script: [{:error, "the gateway is down"}])
    {io, _} = printer!(sid)

    say!(sid, "anything")
    assert_receive {:rest, 1}, 15_000
    out = contents(io)
    assert out =~ "root> model error: "
    assert out =~ "the gateway is down"
    assert out =~ "root> exit 1: the model request failed"
  end

  # A first run on a machine with no model settings: the default provider and no key.
  test "headless printer exits 1 on a provider with no key, and names the next step" do
    {sid, _, _} =
      start_session!(config: %{provider: "anthropic", models: %{"default" => "claude-sonnet-5"}})

    {io, _} = printer!(sid)

    say!(sid, "say hi")
    assert_receive {:rest, 1}, 15_000
    out = contents(io)
    assert out =~ "root> model error: no API key is configured for the provider"
    assert out =~ "root> run `troupe config` to set up a provider"
  end

  # troupe-remote Decision 687: a model that keeps calling the same failing tool is asked
  # about at the tenth failure, headless answers with the first option, `stop`, and the
  # run ends 1 rather than 0, because nothing was done.
  test "headless printer exits 1 when a tool kept failing and the turn was stopped" do
    script = List.duplicate({:tool, "read_file", %{"path" => "missing.txt"}}, 12)
    {sid, _, _} = start_session!(script: script)
    {io, _} = printer!(sid)

    say!(sid, "read it")
    assert_receive {:rest, 1}, 15_000
    out = contents(io)
    assert out =~ "root> question: read_file has failed 10 times in a row"
    assert out =~ ~s{(headless: answered "stop")}
    assert out =~ "root> exit 1: a tool kept failing, and the harness stopped the turn"
  end

  test "headless printer exits 1 when the agent ends short of finishing" do
    {sid, _, _} = start_session!(script: [%{"stop" => "refusal", "text" => "I will not."}])
    {io, _} = printer!(sid)

    say!(sid, "do the thing")
    assert_receive {:rest, 1}, 15_000
    assert contents(io) =~ "root> exit 1: the agent ended refused"
  end

  # A librarian on a repository with no brief is a branch of its own, window `librarian-1`,
  # and its events reach a printer beside root's: `troupe run` without `--headless` starts
  # one, and so does `/memory refresh` from anyone attached. It coming to rest is not the
  # run coming to rest.
  test "headless printer waits for root when the librarian's branch rests first" do
    {sid, _, _} =
      start_session!(
        workspace: git_init!(tmp_workspace()),
        script: [{:text_and_tools, "the answer", []}],
        config: %{memory_auto_refresh: true}
      )

    eventually(
      fn ->
        Enum.any?(
          Client.events(sid),
          &match?(%{agent_path: "librarian-1", type: :agent_state, data: %{to: :idle}}, &1)
        )
      end,
      10_000
    )

    {io, _} = printer!(sid)
    refute_receive {:rest, _}, 300

    say!(sid, "go")
    assert_receive {:rest, 0}, 15_000
    out = contents(io)
    assert out =~ "librarian-1> "
    assert out =~ "root> the answer"
  end

  # `troupe run "task" --headless` in a repository with no brief, whose config approves
  # writes: the config's `auto_approve` holds, where the run used to send `false` and the
  # printer refused the write (exit 3); no librarian starts beside the task; and the
  # session's window says it is the checkout's own, not "remote".
  test "a headless run takes the config's approvals, starts no librarian, and is local" do
    ws = git_init!(tmp_workspace())
    {:ok, args} = CLI.parse(["run", "write out.txt", "--headless", "--workspace", ws])

    {sid, _, _} =
      start_session!(
        workspace: ws,
        script: [
          {:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}},
          {:text_and_tools, "wrote it", []}
        ],
        config: %{memory_auto_refresh: true},
        params: Runner.run_params(args)
      )

    {io, _} = printer!(sid)
    assert_receive {:rest, 0}, 15_000
    assert File.read!(Path.join(ws, "out.txt")) == "hi"

    out = contents(io)
    assert out =~ ~r/root> spawned \/\w+ \(shared\)/
    refute out =~ "(remote)"
    refute Enum.any?(Client.events(sid), &(&1.agent_path == "librarian-1"))
  end

  defp printer!(sid) do
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, pid} =
      Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    {io, pid}
  end

  defp contents(io) do
    {_, out} = StringIO.contents(io)
    out
  end
end
