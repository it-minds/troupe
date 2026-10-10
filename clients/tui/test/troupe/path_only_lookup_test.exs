defmodule Troupe.PathOnlyLookupTest do
  @moduledoc """
  The TUI finds a program it starts by name on `PATH` alone, through
  `Troupe.OS.Process.executable/2`, which is `Troupe.Executable` (#555, Decision 846): `troupe
  daemon`'s `troupe-daemon`, the browser opener and the reaper's commands are never a
  program the repository the TUI was started in carries. The repository here holds each of
  them, writing a marker, and `.` and a relative `rel` are all of `PATH`; on Windows
  `System.find_executable/1` would have looked in the current directory even without `.`.

  `async: false`: it moves the VM's current directory and sets `PATH`.
  """

  use ExUnit.Case, async: false

  alias Troupe.OS.Process, as: OSProcess

  @windows match?({:win32, _}, :os.type())
  @opener if @windows, do: "rundll32", else: "xdg-open"

  setup do
    tmp = Path.join(System.tmp_dir!(), "troupe-tui-path-only-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, "rel"))
    marker = Path.join(tmp, "planted-ran")

    for name <- ["troupe-daemon", @opener, "troupe-planted"],
        dir <- [repo, Path.join(repo, "rel")] do
      if @windows do
        File.write!(Path.join(dir, name <> ".bat"), "@echo #{name} >> \"#{marker}\"\r\n")
      else
        File.write!(Path.join(dir, name), "#!/bin/sh\necho #{name} >> '#{marker}'\n")
        File.chmod!(Path.join(dir, name), 0o755)
      end
    end

    path = System.get_env("PATH", "")
    System.put_env("PATH", Enum.join([".", "rel"], if(@windows, do: ";", else: ":")))

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(tmp)
    end)

    %{repo: repo, marker: marker}
  end

  test "troupe daemon finds no troupe-daemon in the repository", %{repo: repo, marker: marker} do
    File.cd!(repo, fn -> assert Troupe.CLI.Daemon.command() == :error end)
    refute File.exists?(marker)
  end

  test "the browser opener is not the repository's, and the URL is shown instead", %{
    repo: repo,
    marker: marker
  } do
    File.cd!(repo, fn ->
      assert Troupe.Client.open_url("https://example.test/sign-in") ==
               {:error, "#{@opener} is not on the PATH"}
    end)

    refute File.exists?(marker)
  end

  test "a command on no PATH is not started, and ends as command not found", %{
    repo: repo,
    marker: marker
  } do
    File.cd!(repo, fn ->
      assert OSProcess.executable("troupe-planted") == nil
      assert OSProcess.run("troupe-planted", []) == {:ok, "troupe-planted is not on the PATH", 127}
    end)

    refute File.exists?(marker)
  end

  test "on Windows only the extensions a process starts from are tried", %{repo: repo} do
    bin = Path.join(repo, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "tool.js"), "")
    File.write!(Path.join(bin, "tool.vbs"), "")

    windows = [os: {:win32, :nt}, path: bin, pathext: ".JS;.VBS;.COM;.EXE;.BAT;.CMD"]
    assert OSProcess.executable("tool", windows) == nil

    File.write!(Path.join(bin, "tool.cmd"), "")

    assert OSProcess.executable("tool", windows) ==
             String.replace(Path.join(bin, "tool.cmd"), "/", "\\")
  end
end
