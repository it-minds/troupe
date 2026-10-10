defmodule Troupe.ReaperTest do
  @moduledoc """
  A reaper helper that is there and will not start (Decision 733): not executable, on a
  mount that forbids running it, a file an antivirus holds. `Reaper.open/3` returns the
  error rather than raising, and nothing that asks it for a process takes the agent down:
  the brief's `git` calls read the workspace as no repository, `shell` answers the model
  with why, `grep` searches without a process, `git_read` says git could not run.

  `async: false`: the helper's path is application config, which every session in the VM
  reads, and the one warning is asserted on a module level of the logger's.
  """

  use Troupe.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.{Instructions, Reaper}
  alias Troupe.MCP.Stdio
  alias Troupe.Session.Memory
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{GitRead, Grep, Shell}

  setup context do
    # Where the helper should be, a file no OS will run: not executable on Unix, not a
    # program on Windows.
    helper = Path.join(context.base, "reaper")
    File.write!(helper, "not a program\n")
    File.chmod!(helper, 0o644)
    Application.put_env(:troupe_core, :reaper, helper)
    Logger.put_module_level(Reaper, :warning)

    on_exit(fn ->
      Logger.delete_module_level(Reaper)
      Application.delete_env(:troupe_core, :reaper)
    end)

    %{helper: helper}
  end

  defp warnings(log), do: length(Regex.scan(~r/will not start/, log))

  defp path_separator, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  describe "the helper" do
    test "open and run return the error, and the log says so once", %{workspace: workspace} do
      log =
        capture_log(fn ->
          assert {:error, {:reaper_unstartable, :eacces} = reason} =
                   Reaper.open(workspace, ["git", "--version"])

          assert {:error, ^reason} = Reaper.run(workspace, ["git", "--version"])

          assert Reaper.explain(reason) =~
                   ~r/^the reaper helper .+ will not start \(eacces: permission denied\)$/
        end)

      assert warnings(log) == 1
      assert log =~ "not the shell tool, not git, not an MCP server"
    end

    test "a directory that is not there is named, not blamed on the helper", context do
      gone = Path.join(context.base, "gone")

      log =
        capture_log(fn ->
          assert {:error, {:no_directory, ^gone}} = Reaper.open(gone, ["git", "--version"])
        end)

      assert warnings(log) == 0
    end

    test "a helper that is not there is still :reaper_missing", context do
      Application.put_env(:troupe_core, :reaper, Path.join(context.base, "nowhere"))

      assert {:error, :reaper_missing} = Reaper.run(context.workspace, ["git", "--version"])
    end
  end

  describe "a session" do
    test "answers its turn: the git call before every model call does not crash the agent",
         context do
      %{session: session, fake: fake} = start_session(context, steps: [{:text, "hello there"}])
      sid = session.id
      :ok = Troupe.subscribe(sid)
      Troupe.send_input(sid, "hi")

      assert_receive {:troupe_event, ^sid,
                      %Event{type: "turn_ended", agent: ["root"], data: data}},
                     10_000

      assert Map.delete(data, "turn") == %{}
      assert Fake.call_count(fake) == 1
      assert events_of_type(sid, :agent_restarted) == []
    end

    test "a shell call is a tool error saying why, and the turn goes on", context do
      %{session: session, fake: fake} =
        start_session(context,
          steps: [
            {:tools, [{"shell", %{"command" => "echo hi"}}]},
            {:text, "the shell will not run here"}
          ]
        )

      sid = session.id
      :ok = Troupe.subscribe(sid)
      Troupe.send_input(sid, "run echo")

      assert_receive {:troupe_event, ^sid,
                      %Event{type: "tool_call_completed", data: %{"name" => "shell"} = completed}},
                     10_000

      assert completed["ok"] == false
      assert completed["content"] =~ "The shell tool is unavailable: the reaper helper"
      assert completed["content"] =~ "will not start (eacces"
      assert completed["content"] =~ "troupe doctor"

      assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 10_000
      assert Fake.call_count(fake) == 2
      assert events_of_type(sid, :agent_restarted) == []
    end
  end

  describe "the brief" do
    setup %{workspace: workspace} do
      # A repository whose brief is at its root, and a directory inside it to work in:
      # made with `git` directly, since the harness cannot run it now.
      {_, 0} = System.cmd("git", ["init", "-q", workspace])
      sub = Path.join(workspace, "sub")
      File.mkdir_p!(sub)
      File.mkdir_p!(Path.join(workspace, ".troupe"))
      File.write!(Path.join(workspace, ".troupe/memory.md"), "## Overview\nThe root's brief.\n")

      %{sub: sub}
    end

    test "reads the workspace as no repository, and says why once", %{sub: sub} do
      log =
        capture_log(fn ->
          assert Memory.path(sub) == Path.join([Path.expand(sub), ".troupe", "memory.md"])

          for _turn <- 1..3 do
            loaded = Instructions.load(sub, %Troupe.Config{})

            assert %{scope: :brief, status: :absent} =
                     Enum.find(loaded.files, &(&1.scope == :brief))
          end
        end)

      assert warnings(log) == 1
    end
  end

  describe "the tools" do
    setup %{workspace: workspace} do
      {:ok, ws} = Workspace.new(workspace)

      ctx = %Ctx{
        session_id: "s-#{System.unique_integer([:positive])}",
        agent_path: ["root"],
        workspace: ws,
        call_id: "call_1",
        agent_pid: self(),
        config: %Troupe.Config{}
      }

      %{ctx: ctx}
    end

    test "shell says the helper will not start, and where", %{ctx: ctx, helper: helper} do
      assert {:error, message} = Shell.run(%{"command" => "echo hi"}, ctx)

      assert message =~
               "The shell tool is unavailable: the reaper helper #{Troupe.Paths.display(helper)}"

      assert message =~ "so no command can run on this machine until it does"
    end

    test "shell without a helper at all still says to build one", %{ctx: ctx} = context do
      Application.put_env(:troupe_core, :reaper, Path.join(context.base, "nowhere"))

      assert {:error, message} = Shell.run(%{"command" => "echo hi"}, ctx)
      assert message =~ "was not built into this install. Run `mix compile.reaper`"
    end

    test "grep searches without a process", %{ctx: ctx} = context do
      # An `rg` on the PATH, so grep asks the reaper for it rather than going straight to
      # the built-in scan; nothing runs it.
      bin = Path.join(context.base, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "rg"), "#!/bin/sh\nexit 2\n")
      File.chmod!(Path.join(bin, "rg"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> path_separator() <> path)
      on_exit(fn -> System.put_env("PATH", path) end)

      write_file(context, "lib/a.txt", "one\nthe needle\n")

      assert {:ok, out} = Grep.run(%{"pattern" => "needle"}, ctx)
      assert out =~ "a.txt:2:"
      assert out =~ "the needle"
    end

    test "git_read says git could not run, and why", %{ctx: ctx} do
      assert {:error, message} = GitRead.run(%{"op" => "status"}, ctx)
      assert message =~ ~r/^git could not run: the reaper helper .+ will not start \(eacces/
    end

    # Windows starts an MCP server outside the reaper (Decision 654).
    test "an MCP server under it could not start, and says why", context do
      if match?({:unix, _}, :os.type()) do
        assert %{state: :error, error: error} =
                 Stdio.probe("local", %{"command" => "cat"}, context.workspace, 2_000)

        assert error =~ ~r/^could not start: the reaper helper .+ will not start \(eacces/
      end
    end
  end
end

defmodule Troupe.ReaperLastLineTest do
  @moduledoc """
  Output that does not end with a newline is read to its end (#536). In line mode the
  port holds a last line until its newline, and lets go of it only as it closes, after
  the exit status: a reader that stopped at `{:exit_status, _}` lost it, so `printf x`
  read as nothing and a file without a final newline lost its last line, through every
  caller of the reaper (git, ripgrep, the shell). Run with the host's shell, so on
  Windows with Git for Windows' bash.

  `async: false`: `Troupe.ReaperTest` points the whole VM at a helper that will not start.
  """

  use ExUnit.Case, async: false

  alias Troupe.Reaper
  alias Troupe.Tools.Shell

  @moduletag :tmp_dir

  defp sh(command) do
    {shell, flag} = Shell.shell()
    [shell, flag, command]
  end

  test "printf x is x", %{tmp_dir: dir} do
    assert {:ok, "x", 0} = Reaper.run(dir, sh("printf x"))
    assert {:ok, "one\ntwo", 0} = Reaper.run(dir, sh("printf 'one\\ntwo'"))
    assert {:ok, "x", 3} = Reaper.run(dir, sh("printf x; exit 3"))
  end

  test "cat reads a file without a final newline whole", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "notes.txt"), "one\ntwo\nthree")
    assert {:ok, "one\ntwo\nthree", 0} = Reaper.run(dir, sh("cat notes.txt"))
  end

  test "git shows a file without a final newline whole", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "notes.txt"), "one\ntwo\nthree")
    who = ~w(-c user.name=t -c user.email=t@example.test -c commit.gpgsign=false)

    for args <- [~w(init -q), ~w(add notes.txt), who ++ ~w(commit -q -m notes)],
        do: assert({:ok, _, 0} = Reaper.run(dir, ["git" | args]))

    assert {:ok, "one\ntwo\nthree", 0} = Reaper.run(dir, ~w(git show HEAD:notes.txt))
  end

  test "a last line longer than the port's line is whole", %{tmp_dir: dir} do
    long = String.duplicate("a", 70_000)
    File.write!(Path.join(dir, "long.txt"), "first\n" <> long)
    assert {:ok, output, 0} = Reaper.run(dir, sh("cat long.txt"))
    assert byte_size(output) == byte_size("first\n" <> long)
    assert output == "first\n" <> long
  end

  test "output that ends with a newline is unchanged", %{tmp_dir: dir} do
    assert {:ok, "one\ntwo\n", 0} = Reaper.run(dir, sh("printf 'one\\ntwo\\n'"))
    assert {:ok, "", 0} = Reaper.run(dir, sh("true"))
  end
end
