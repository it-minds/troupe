defmodule Troupe.CLIDaemonTest do
  @moduledoc """
  `troupe daemon` finds the daemon binary the way every client does and hands it the
  arguments untouched. The binary itself is another repository's; what is proven here is
  the seam.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI

  setup do
    previous = System.get_env("TROUPE_DAEMON_COMMAND")

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_DAEMON_COMMAND", previous),
        else: System.delete_env("TROUPE_DAEMON_COMMAND")
    end)

    :ok
  end

  test "everything after `daemon` is the daemon's" do
    assert {:ok, %{mode: :daemon, daemon_args: []}} = CLI.parse(["daemon"])
    assert {:ok, %{mode: :daemon, daemon_args: ["status"]}} = CLI.parse(["daemon", "status"])

    assert {:ok, %{mode: :daemon, daemon_args: ["models", "--refresh"]}} =
             CLI.parse(["daemon", "models", "--refresh"])

    assert CLI.usage() =~ "troupe daemon"
  end

  test "TROUPE_DAEMON_COMMAND wins, and the arguments and exit status pass through" do
    # The seam is a process spawn; without a shell to fake the binary there is nothing to run.
    # On Windows the fake is what the installers put there, a `.cmd`, in a directory with a
    # space in its name.
    fake =
      case :os.type() do
        {:win32, _} ->
          fake_daemon("troupe daemon cmd", "fake-daemon.cmd", """
          @echo off\r
          echo fake-daemon got: %*\r
          exit /b 7\r
          """)

        _ ->
          if System.find_executable("sh") do
            fake_daemon("troupe-daemon-cmd", "fake-daemon", """
            #!/bin/sh
            echo "fake-daemon got: $*"
            exit 7
            """)
          end
      end

    if fake do
      System.put_env("TROUPE_DAEMON_COMMAND", fake)
      assert Troupe.CLI.Daemon.command() == {:ok, fake}

      output = capture_io(fn -> assert Troupe.CLI.Daemon.run(["status", "--verbose"]) == 7 end)
      assert output =~ "fake-daemon got: status --verbose"
    end
  end

  test "a Windows batch file runs through cmd.exe, with its path and any spaced argument quoted" do
    path = "c:/Users/Jo Doe/Programs/troupe/troupe-daemon.cmd"
    win32 = {:win32, :nt}

    # `cmd /s /c` takes off the outer pair of quotes and leaves the rest alone.
    assert Troupe.CLI.Daemon.invocation(path, ["models", "--refresh"], win32) ==
             {:shell, ~S(""c:\Users\Jo Doe\Programs\troupe\troupe-daemon.cmd" models --refresh")}

    assert {:shell, line} = Troupe.CLI.Daemon.invocation(path, ["status", "a b"], win32)
    assert String.ends_with?(line, ~S(troupe-daemon.cmd" status "a b""))

    assert {:shell, _} = Troupe.CLI.Daemon.invocation("C:/troupe/TROUPE-DAEMON.BAT", [], win32)

    # Anything else is started as itself, and so is everything off Windows.
    exe = "C:/troupe/troupe-daemon.exe"
    assert Troupe.CLI.Daemon.invocation(exe, ["run"], win32) == {:exec, exe, ["run"]}
    assert Troupe.CLI.Daemon.invocation(path, ["run"], {:unix, :linux}) == {:exec, path, ["run"]}
  end

  test "with no binary anywhere the answer is how to install one, and exit 1" do
    System.put_env("TROUPE_DAEMON_COMMAND", "")
    previous_path = System.get_env("PATH")
    System.put_env("PATH", System.tmp_dir!())
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    assert Troupe.CLI.Daemon.command() == :error
    output = capture_io(:stderr, fn -> assert Troupe.CLI.Daemon.run(["run"]) == 1 end)
    assert output =~ "install.sh"
  end

  defp fake_daemon(dir_prefix, name, script) do
    dir = Path.join(System.tmp_dir!(), "#{dir_prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    fake = Path.join(dir, name)
    File.write!(fake, script)
    File.chmod!(fake, 0o755)
    fake
  end
end
