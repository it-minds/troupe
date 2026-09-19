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
    if System.find_executable("sh") do
      dir = Path.join(System.tmp_dir!(), "troupe-daemon-cmd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      fake = Path.join(dir, "fake-daemon")
      File.write!(fake, "#!/bin/sh\necho \"fake-daemon got: $*\"\nexit 7\n")
      File.chmod!(fake, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      System.put_env("TROUPE_DAEMON_COMMAND", fake)
      assert Troupe.CLI.Daemon.command() == {:ok, fake}

      output = capture_io(fn -> assert Troupe.CLI.Daemon.run(["status", "--verbose"]) == 7 end)
      assert output =~ "fake-daemon got: status --verbose"
    end
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
end
