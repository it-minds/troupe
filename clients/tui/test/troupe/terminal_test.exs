defmodule Troupe.TerminalTest do
  @moduledoc """
  Whether standard output is a terminal is asked of the process whose standard output the
  person sees (#231, TUI Decision 130).

  In the binary on Linux and macOS that is not the VM: Burrito's launcher gives the VM a
  pipe for standard output and copies it to its own. Asked of the VM, plain `troupe` in a
  terminal was refused as if it had been drawn into a file.
  """

  use ExUnit.Case, async: true

  alias Troupe.CLI.Terminal

  @linux match?({:unix, :linux}, :os.type())

  test "the VM's own terminal is enough, and the launcher is not asked" do
    # Asked, this launcher would say no.
    assert Terminal.stdout?(getopts: [stdout: true], piped: true, launcher_stdout: "pipe:[1]")
  end

  test "without Burrito's pipe, the VM's answer is the answer" do
    refute Terminal.stdout?(getopts: [stdout: false], piped: false)
  end

  test "behind Burrito's pipe, the launcher's standard output is asked" do
    # What `troupe` in a terminal has on Linux, on macOS, and on a Linux console.
    for terminal <- ["/dev/pts/4", "/dev/ttys003", "/dev/tty1", "/dev/console"] do
      assert Terminal.stdout?(getopts: [stdout: false], piped: true, launcher_stdout: terminal)
    end

    # What `troupe > out.txt`, `troupe | less` and `troupe > /dev/null` have.
    for other <- ["/home/me/out.txt", "pipe:[3431999]", "socket:[12]", "/dev/null"] do
      refute Terminal.stdout?(getopts: [stdout: false], piped: true, launcher_stdout: other)
    end

    # One that could not be read is not a reason to refuse.
    assert Terminal.stdout?(getopts: [stdout: false], piped: true, launcher_stdout: nil)
  end

  describe "another process's standard output" do
    setup do
      dir = Path.join(System.tmp_dir!(), "troupe-terminal-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      out = Path.join(dir, "out.txt")

      # A process whose standard output is a file, as the launcher's is under `> out.txt`.
      # `:exit_status`: the port stays open when the pipe it read is closed by the redirect.
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          args: ["-c", "exec sleep 30 > '#{out}'"]
        ])

      {:os_pid, pid} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)
        File.rm_rf(dir)
      end)

      # Until the shell has handed over to `sleep`, its standard output is the port's.
      assert eventually(fn -> Terminal.stdout_of(pid, {:unix, :linux}) == out end)
      %{pid: pid, out: out}
    end

    @tag skip: not @linux && "reads /proc"
    test "is read from /proc on Linux", %{pid: pid, out: out} do
      assert Terminal.stdout_of(pid, {:unix, :linux}) == out

      # A port's program is started by `erl_child_setup`, which this VM started.
      assert pid |> Terminal.parent({:unix, :linux}) |> Terminal.parent({:unix, :linux}) ==
               String.to_integer(System.pid())
    end

    # What macOS does, done here, where `lsof` and `ps` are the same programs.
    @tag skip: not (@linux and System.find_executable("lsof") != nil) && "needs lsof on Linux"
    test "is read with lsof and ps elsewhere", %{pid: pid, out: out} do
      assert Terminal.stdout_of(pid, {:unix, :darwin}) == out
      assert Terminal.parent(pid, {:unix, :darwin}) == Terminal.parent(pid, {:unix, :linux})
    end
  end

  defp eventually(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(check, tries - 1)
    end
  end
end
