defmodule Troupe.PathsTest do
  use ExUnit.Case, async: true

  alias Troupe.Paths

  describe "glob_escape/1" do
    test "a Windows directory is written with forward slashes, which is how a glob separates" do
      assert Paths.glob_escape("C:\\Users\\me\\AppData\\Local\\troupe") == "C:/Users/me/AppData/Local/troupe"
    end

    test "every character that starts a wildcard is escaped" do
      assert Paths.glob_escape("/src/app[1]/{a,b}/*?") == "/src/app\\[1]/\\{a,b}/\\*\\?"
      assert Paths.glob_escape("C:\\src\\app[1]") == "C:/src/app\\[1]"
    end

    test "the escaped directory matches itself and not the directories its name would match as a glob" do
      base = Path.join(System.tmp_dir!(), "troupe-paths-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)

      for dir <- ["app[1]", "app1", "app{a,b}", "appa"] do
        File.mkdir_p!(Path.join(base, dir))
        File.write!(Path.join([base, dir, "x.json"]), "{}")
      end

      for dir <- ["app[1]", "app{a,b}"] do
        assert [match] = base |> Path.join(dir) |> Paths.glob_escape() |> Path.join("*.json") |> Path.wildcard()
        assert match |> Path.dirname() |> Path.basename() == dir
      end
    end
  end

  describe "display/2" do
    # What `Path.join/2` makes of `%APPDATA%` and a file name on Windows.
    test "on Windows, a path joined onto %APPDATA% prints with one kind of separator" do
      joined = "C:\\Users\\me\\AppData\\Roaming\\troupe/config.yaml"
      assert Paths.display(joined, {:win32, :nt}) == "C:\\Users\\me\\AppData\\Roaming\\troupe\\config.yaml"
    end

    # What `File.cwd!/0` answers on Windows, and so every workspace a command defaults to.
    test "on Windows, the current directory prints with the drive letter Windows shows" do
      assert Paths.display("c:/Users/me/my repo", {:win32, :nt}) == "C:\\Users\\me\\my repo"
      assert Paths.display("TROUPE_MODEL", {:win32, :nt}) == "TROUPE_MODEL"
    end

    test "anywhere else a path is shown as it is" do
      assert Paths.display("/home/me/.config/troupe/config.yaml", {:unix, :linux}) ==
               "/home/me/.config/troupe/config.yaml"
    end
  end
end
