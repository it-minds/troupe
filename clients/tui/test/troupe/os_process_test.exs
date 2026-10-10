defmodule Troupe.OS.ProcessTest do
  @moduledoc """
  How the TUI starts a program under the reaper (D109). On Windows the reaper hands the
  command line on as Erlang built it, and `System.find_executable/1` answers
  `c:/WINDOWS/system32/cmd.exe`: cmd.exe read the forward slashes in its own name as
  switches and answered "The syntax of the command is incorrect." to everything, which is
  why `/copy` and Ctrl-Y copied nothing there. The argument building is tested on every OS;
  the run itself on whichever this is.
  """

  # One test changes the VM's current directory.
  use ExUnit.Case, async: false

  alias Troupe.OS.Process, as: OSProcess

  @windows {:win32, :nt}
  @pathext ".COM;.EXE;.BAT;.CMD"

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-os-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "repo"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "the program the reaper is given" do
    test "on Windows, one found on PATH is spelled with backslashes, as cmd.exe needs", %{dir: dir} do
      bin = Path.join(dir, "bin")
      File.write!(Path.join(bin, "cmd.exe"), "")

      assert [cmd, "/c", "echo hi"] =
               OSProcess.argv("cmd.exe", ["/c", "echo hi"],
                 os: @windows,
                 path: bin,
                 pathext: @pathext
               )

      assert cmd == String.replace(Path.join(bin, "cmd.exe"), "/", "\\")
      refute cmd =~ "/"
    end

    # `System.find_executable/1` on Windows looks in the current directory first, and the
    # TUI's is the repository it was started in.
    test "on Windows, a bare name is looked up on PATH alone, never in the current directory", %{
      dir: dir
    } do
      bin = Path.join(dir, "bin")
      repo = Path.join(dir, "repo")
      File.write!(Path.join(repo, "clip.bat"), "")

      File.cd!(repo, fn ->
        assert OSProcess.executable("clip", os: @windows, path: bin, pathext: @pathext) == nil

        File.write!(Path.join(bin, "clip.exe"), "")
        path = Enum.join(["", "relative", bin], ";")
        found = OSProcess.executable("clip", os: @windows, path: path, pathext: @pathext)
        assert found == String.replace(Path.join(bin, "clip.exe"), "/", "\\")
      end)
    end

    test "on Windows, a path is taken as given, and only PATHEXT's extensions are tried", %{
      dir: dir
    } do
      assert OSProcess.executable("c:/WINDOWS/system32/cmd.exe", os: @windows, path: "") ==
               "c:\\WINDOWS\\system32\\cmd.exe"

      File.write!(Path.join([dir, "bin", "tool.ps1"]), "")

      assert OSProcess.executable("tool",
               os: @windows,
               path: Path.join(dir, "bin"),
               pathext: @pathext
             ) == nil
    end

    test "elsewhere, the program is found as System.find_executable/1 finds it" do
      assert [sh, "-c", "true"] = OSProcess.argv("sh", ["-c", "true"], os: {:unix, :linux})
      assert sh == (System.find_executable("sh") || "sh")
    end
  end

  test "runs the platform's own command interpreter and answers what it printed" do
    case :os.type() do
      {:win32, _} ->
        assert {:ok, out, 0} = OSProcess.run("cmd.exe", ["/c", "echo hi"])
        assert String.trim(out) == "hi"

      _ ->
        assert {:ok, "hi\n", 0} = OSProcess.run("sh", ["-c", "echo hi"])
    end
  end
end
