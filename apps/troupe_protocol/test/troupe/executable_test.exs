defmodule Troupe.ExecutableTest do
  @moduledoc """
  A program started by name is found on `PATH` alone (#555, Decision 846): never in the
  current directory, which `System.find_executable/1` looks in first on Windows and which
  for the daemon is often a repository, and never in a relative entry of `PATH`, which is
  the current directory by another name. The lookup is played with Windows as the OS on
  every host; the planted program in the current directory is the host's own.

  `async: false`: one test changes the VM's current directory and `PATH`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Executable

  @windows {:win32, :nt}
  @unix {:unix, :linux}
  @pathext ".COM;.EXE;.BAT;.CMD;.VBS;.JS"

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-executable-#{System.unique_integer([:positive])}")
    for sub <- ["bin", "repo", "repo/rel"], do: File.mkdir_p!(Path.join(dir, sub))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, bin: Path.join(dir, "bin"), repo: Path.join(dir, "repo")}
  end

  defp windows(path), do: String.replace(path, "/", "\\")

  describe "on Windows" do
    test "a name is found on PATH alone: not in the current directory, not in a relative entry",
         %{bin: bin, repo: repo} do
      File.write!(Path.join(repo, "rg.bat"), "")
      File.write!(Path.join([repo, "rel", "rg.bat"]), "")

      File.cd!(repo, fn ->
        path = Enum.join([".", "rel", "", bin], ";")
        assert Executable.find("rg", os: @windows, path: path, pathext: @pathext) == nil

        File.write!(Path.join(bin, "rg.exe"), "")

        assert Executable.find("rg", os: @windows, path: path, pathext: @pathext) ==
                 windows(Path.join(bin, "rg.exe"))
      end)
    end

    test "PATHEXT's extensions a process starts from, in its order; a name with one is taken as it is",
         %{bin: bin} do
      File.write!(Path.join(bin, "tool.js"), "")
      File.write!(Path.join(bin, "tool.cmd"), "")
      File.write!(Path.join(bin, "tool.bat"), "")

      # `.js` is in PATHEXT, but nothing starts it as a process.
      assert Executable.find("tool", os: @windows, path: bin, pathext: @pathext) ==
               windows(Path.join(bin, "tool.bat"))

      assert Executable.find("tool.cmd", os: @windows, path: bin, pathext: @pathext) ==
               windows(Path.join(bin, "tool.cmd"))

      assert Executable.find("tool.js", os: @windows, path: bin, pathext: @pathext) == nil

      # A dot that is no extension of PATHEXT's is part of the name.
      File.write!(Path.join(bin, "python3.12.exe"), "")

      assert Executable.find("python3.12", os: @windows, path: bin, pathext: @pathext) ==
               windows(Path.join(bin, "python3.12.exe"))
    end

    test "a quoted entry is read; the answer has backslashes, as cmd.exe needs", %{bin: bin} do
      File.write!(Path.join(bin, "cmd.exe"), "")
      found = Executable.find("cmd", os: @windows, path: ~s("#{bin}"), pathext: "")
      assert found == windows(Path.join(bin, "cmd.exe"))
      refute found =~ "/"
    end

    test "a path is not looked up: as written when absolute, from the base when relative" do
      assert Executable.find("c:/tools/rg.exe", os: @windows, path: "") == nil
      assert Executable.find("bin\\rg", os: @windows, path: "") == nil

      assert Executable.resolve("c:/tools/rg.exe", nil, os: @windows) ==
               {:ok, "c:\\tools\\rg.exe"}

      assert {:ok, found} = Executable.resolve("bin/server", "/srv/ws", os: @windows)
      assert found == windows(Path.expand("bin/server", "/srv/ws"))

      assert Executable.resolve(".\\bin\\server", nil, os: @windows) ==
               {:error, {:relative_command, ".\\bin\\server"}}
    end

    test "PATH's entries: absolute ones, a drive's or a share's, in order" do
      assert Executable.dirs(
               ~s(.;rel\\bin;\\on-this-drive;C:\\A;"D:/B";\\\\server\\share),
               @windows
             ) ==
               ["C:\\A", "D:/B", "\\\\server\\share"]
    end
  end

  describe "elsewhere" do
    # Unix paths and modes, which a Windows host reads otherwise.
    @describetag skip: match?({:win32, _}, :os.type()) && "Unix paths and file modes"

    test "an executable file on PATH, never in a relative or empty entry", %{bin: bin, repo: repo} do
      for dir <- [repo, Path.join(repo, "rel"), bin] do
        File.write!(Path.join(dir, "tool"), "#!/bin/sh\n")
      end

      File.chmod!(Path.join(repo, "tool"), 0o755)
      File.chmod!(Path.join([repo, "rel", "tool"]), 0o755)

      File.cd!(repo, fn ->
        path = Enum.join([".", "", "rel", bin], ":")
        # The one on PATH is not executable yet.
        assert Executable.find("tool", os: @unix, path: path) == nil

        File.chmod!(Path.join(bin, "tool"), 0o755)
        assert Executable.find("tool", os: @unix, path: path) == Path.join(bin, "tool")
      end)
    end

    test "a path is not looked up; a relative one needs a base" do
      assert Executable.find("./tool", os: @unix, path: "/usr/bin") == nil
      assert Executable.resolve("/usr/bin/env", nil, os: @unix) == {:ok, "/usr/bin/env"}
      assert Executable.resolve("bin/server", "/srv/ws", os: @unix) == {:ok, "/srv/ws/bin/server"}

      assert {:error, {:relative_command, "./tool"} = reason} =
               Executable.resolve("./tool", nil, os: @unix)

      assert Executable.explain(reason) =~ "is a relative path"
    end

    test "a name on no PATH is refused, and says so" do
      assert {:error, {:not_on_path, "troupe-no-such-program"} = reason} =
               Executable.resolve("troupe-no-such-program", "/srv/ws", path: "")

      assert Executable.explain(reason) == "`troupe-no-such-program` is not on the PATH"
    end
  end

  # On this machine, as the daemon looks: a program planted in the current directory and in
  # a relative entry of `PATH` is never the answer, whatever the OS.
  test "this host's own lookup passes over the current directory", %{repo: repo} do
    {name, planted} =
      case :os.type() do
        {:win32, _} -> {"troupe-planted", "troupe-planted.bat"}
        _ -> {"troupe-planted", "troupe-planted"}
      end

    for dir <- [repo, Path.join(repo, "rel")] do
      File.write!(Path.join(dir, planted), "#!/bin/sh\n")
      File.chmod!(Path.join(dir, planted), 0o755)
    end

    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"
    path = System.get_env("PATH", "")
    System.put_env("PATH", Enum.join([".", "rel", path], separator))
    on_exit(fn -> System.put_env("PATH", path) end)

    File.cd!(repo, fn ->
      # What `System.find_executable/1` does with the same PATH, for the record: on Windows
      # it answers the planted one even without `.` on PATH.
      assert System.find_executable(name) != nil
      assert Executable.find(name) == nil
      assert Executable.resolve(name, repo) == {:error, {:not_on_path, name}}
    end)
  end
end
