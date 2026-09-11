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

  alias Troupe.{Mounts, Sandbox}

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
end
