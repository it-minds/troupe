defmodule Troupe.SandboxTest do
  @moduledoc """
  What a shell command can reach, checked by running one.

  The Forbidden list says path checks may not be the only enforcement for `shell`, so
  every assertion here is about what the *kernel* does: a read-only team volume that
  fails a write with a read-only filesystem error, another team's volume that is not
  there at all, and another session's workspace that does not exist.

  Skipped loudly where bubblewrap is not installed, because a suite that quietly stopped
  checking this would be worse than one that failed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Troupe.Agent.ACPAgent
  alias Troupe.{Mounts, Reaper, Sandbox, Workspace}
  alias Troupe.Tools.Shell

  @moduletag timeout: 60_000

  setup_all do
    if Sandbox.available?() do
      :ok
    else
      IO.puts(:stderr, "\nSKIPPED: bubblewrap is not installed; `shell` confinement is unchecked.\n")
      {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip], do: flunk("no bubblewrap; see the message from setup_all")

    base = Path.join(System.tmp_dir!(), "troupe-sandbox-#{System.unique_integer([:positive])}")

    session = Path.join(base, "session")
    acme = Path.join(base, "acme")
    other_team = Path.join(base, "other-team")
    other_session = Path.join(base, "other-session")

    for dir <- [session, acme, other_team, other_session], do: File.mkdir_p!(dir)
    File.write!(Path.join(session, "mine.txt"), "mine")
    File.write!(Path.join(acme, "shared.md"), "shared")
    File.write!(Path.join(other_team, "secrets.md"), "the-other-teams-secret")
    File.write!(Path.join(other_session, "theirs.txt"), "the-other-sessions-work")

    on_exit(fn -> File.rm_rf!(base) end)

    mounts =
      Mounts.new([
        %{name: "session", kind: :session, root: session, mode: :rw},
        %{name: "acme", kind: :team, root: acme, mode: :ro}
      ])

    Map.merge(context, %{
      base: base,
      session: session,
      acme: acme,
      other_team: other_team,
      other_session: other_session,
      mounts: mounts
    })
  end

  test "the session's own workspace is writable", context do
    assert {output, 0} = run(context, "echo written > new.txt && cat new.txt")
    assert output =~ "written"
    assert File.read!(Path.join(context.session, "new.txt")) == "written\n"
  end

  test "a read-only team volume fails a write with a read-only filesystem error", context do
    # Readable, which is the point of mounting it at all.
    assert {output, 0} = run(context, "cat #{context.acme}/shared.md")
    assert output =~ "shared"

    {output, status} = run(context, "echo nope > #{context.acme}/shared.md")

    assert status != 0
    assert output =~ "Read-only file system"
    assert File.read!(Path.join(context.acme, "shared.md")) == "shared"
  end

  test "another team's volume does not exist inside the sandbox", context do
    {output, status} = run(context, "cat #{context.other_team}/secrets.md")

    assert status != 0
    assert output =~ "No such file or directory"
    refute output =~ "the-other-teams-secret"
  end

  test "another session's workspace does not exist inside the sandbox", context do
    {output, status} = run(context, "cat #{context.other_session}/theirs.txt")

    assert status != 0
    assert output =~ "No such file or directory"
    refute output =~ "the-other-sessions-work"
  end

  test "the parent directory holding every volume is not browsable", context do
    {output, _status} = run(context, "ls #{context.base} 2>&1 || true")

    refute output =~ "other-team"
    refute output =~ "other-session"
  end

  test "/tmp is private", context do
    marker = "troupe-sandbox-marker-#{System.unique_integer([:positive])}"
    File.write!(Path.join(System.tmp_dir!(), marker), "outside")

    on_exit(fn -> File.rm(Path.join(System.tmp_dir!(), marker)) end)

    {output, status} = run(context, "cat /tmp/#{marker}")
    assert status != 0
    assert output =~ "No such file"

    # And what the command leaves in /tmp does not leak out.
    assert {_output, 0} = run(context, "echo inside > /tmp/#{marker}")
    assert File.read!(Path.join(System.tmp_dir!(), marker)) == "outside"
  end

  test "the process table is the sandbox's own", context do
    {output, 0} = run(context, "ls /proc | grep -c '^[0-9]*$'")

    # A handful, not the host's hundreds: the namespace has its own PID space.
    assert output |> String.trim() |> String.to_integer() < 20
  end

  test "host names resolve and the user has a name", context do
    # What every command on a worker now runs in (Decision 832): without the files in
    # `/etc` that name resolution and user lookup read, it resolved nothing.
    assert {output, 0} = run(context, "getent hosts localhost && id -un")
    assert output =~ "localhost"
    refute output =~ "cannot find name"
  end

  describe "on a worker, `:always` (Decision 832)" do
    setup context do
      Application.put_env(:troupe_core, :sandbox, :always)
      on_exit(fn -> Application.delete_env(:troupe_core, :sandbox) end)

      theirs = Path.join(context.other_session, "theirs.txt")
      %{theirs: theirs}
    end

    test "a session with only its own workspace is sandboxed", context do
      local = Mounts.local(context.session)

      assert Sandbox.enabled?(local) == true
      assert Sandbox.check() == :ok
      assert [bwrap | _] = Sandbox.wrap(["/bin/sh", "-c", "true"], local, cwd: context.session)
      assert bwrap == Sandbox.executable()
    end

    test "a command the reaper starts with no table runs over its own directory alone",
         context do
      # git and ripgrep, as the tools start them: `$HOME` the private /tmp, so a file the
      # repository carries is never their configuration.
      assert {:ok, output, _status} =
               Reaper.run(context.session, [
                 "/bin/sh",
                 "-c",
                 "cat #{context.theirs}; echo home=$HOME; cat mine.txt; echo"
               ])

      assert output =~ "No such file or directory"
      refute output =~ "the-other-sessions-work"
      assert output =~ "home=/tmp"
      assert output =~ "mine"
    end

    test "a last line without a newline comes out of the sandbox too (#536)", context do
      # `mine.txt` is "mine", with no newline after it.
      assert {:ok, "mine", 0} = Reaper.run(context.session, ["/bin/sh", "-c", "cat mine.txt"])

      {:ok, workspace} = Workspace.new(context.session)
      assert {:ok, "mine", 0} = Shell.execute("cat mine.txt", workspace, timeout_ms: 10_000)
    end

    test "`shell` runs over the session's table even with no mount besides its own", context do
      {:ok, workspace} = Workspace.new(context.session)

      assert {:ok, output, _status} =
               Shell.execute("cat #{context.theirs}; cat mine.txt; echo", workspace,
                 timeout_ms: 10_000
               )

      assert output =~ "No such file or directory"
      refute output =~ "the-other-sessions-work"
      assert output =~ "mine"
    end

    test "an MCP server's process starts in it too", context do
      assert {:ok, port} =
               Reaper.open_stdio(context.session, [
                 "/bin/sh",
                 "-c",
                 "cat #{context.theirs} 2>&1; echo done"
               ])

      output = read_port(port, "")
      assert output =~ "No such file or directory"
      refute output =~ "the-other-sessions-work"
    end

    test "an ACP agent's program runs in it, over the session's mounts", context do
      # An agent that, asked for anything, says what it read for itself next door.
      agent = Path.join(context.session, "agent.sh")

      File.write!(agent, """
      #!/bin/sh
      read line; echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
      read line; echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"acp-1"}}'
      read line
      seen=$(cat "$1" 2>/dev/null || echo nothing)
      echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"acp-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"saw '"$seen"'"}}}}'
      echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
      """)

      ref = make_ref()

      {:ok, _pid} =
        ACPAgent.start_link(
          session_id: "s-acp",
          agent_path: ["root", "agent#1"],
          workspace: %{Workspace.new!(context.session) | mounts: context.mounts},
          entry: %{name: "agent", command: "/bin/sh", args: [agent, context.theirs], hash: nil},
          task: "look next door",
          parent: self(),
          parent_ref: ref
        )

      assert_receive {:child_result, ^ref, {:ok, said, _usage}}, 20_000
      assert said =~ "saw nothing"
      refute said =~ "the-other-sessions-work"
    end

    test "a bubblewrap the kernel refuses is refused, with what it said, logged once",
         context do
      refused = Path.join(context.base, "bwrap")

      File.write!(refused, """
      #!/bin/sh
      echo 'bwrap: No permissions to create a new namespace' >&2
      exit 1
      """)

      File.chmod!(refused, 0o755)
      Application.put_env(:troupe_core, :bwrap, refused)
      on_exit(fn -> Application.delete_env(:troupe_core, :bwrap) end)

      # The suite logs nothing below critical; this line is the one under test.
      Logger.put_module_level(Sandbox, :error)
      on_exit(fn -> Logger.delete_module_level(Sandbox) end)

      log =
        capture_log(fn ->
          for _ <- 1..2 do
            assert {:error, why} = Sandbox.check()

            assert why =~
                     "could not start one here (bwrap: No permissions to create a new namespace)"

            assert {:error, {:sandbox, ^why}} =
                     Reaper.run(context.session, ["/bin/sh", "-c", "touch ran-it"])
          end
        end)

      refute File.exists?(Path.join(context.session, "ran-it"))
      assert length(Regex.scan(~r/could not start one/, log)) == 1
    end
  end

  describe "when it is off" do
    test "the command is returned unchanged, so there is one code path", context do
      argv = ["/bin/sh", "-c", "true"]
      assert Sandbox.wrap(argv, context.mounts, enabled?: false) == argv
      assert Sandbox.wrap(argv, nil) == argv
    end

    test "a session with only its own workspace is not sandboxed by default", context do
      local = Mounts.local(context.session)
      assert Sandbox.enabled?(local) == false
      assert Sandbox.enabled?(context.mounts) == true
    end

    test "`:always` and bubblewrap missing is an error, not a quiet unconfined run" do
      Application.put_env(:troupe_core, :sandbox, :always)
      Application.put_env(:troupe_core, :bwrap, "/nonexistent/bwrap")
      on_exit(fn -> Application.delete_env(:troupe_core, :bwrap) end)
      on_exit(fn -> Application.delete_env(:troupe_core, :sandbox) end)

      assert {:error, message} = Sandbox.check()
      assert message =~ "bubblewrap is not installed"
    end
  end

  defp run(context, command) do
    argv = Sandbox.wrap(["/bin/sh", "-c", command], context.mounts, enabled?: true, cwd: context.session)
    [executable | args] = argv
    System.cmd(executable, args, cd: context.session, stderr_to_stdout: true)
  end

  defp read_port(port, acc) do
    receive do
      {^port, {:data, {_eol, line}}} -> read_port(port, acc <> line <> "\n")
      {^port, {:exit_status, _status}} -> acc
    after
      10_000 -> flunk("the command never finished: #{acc}")
    end
  end
end
