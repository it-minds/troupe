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

  describe "write_atomic/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "troupe-atomic-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "the file is written whole, its directory made first, and nothing is left beside it", %{dir: dir} do
      path = Path.join([dir, "state", "answers.json"])

      assert Paths.write_atomic(path, ["{", "}\n"]) == :ok
      assert File.read!(path) == "{}\n"
      assert File.ls!(Path.dirname(path)) == ["answers.json"]
    end

    test "a write that fails at the rename leaves the old file whole and no temporary file", %{dir: dir} do
      path = Path.join(dir, "answers.json")
      File.mkdir_p!(dir)
      File.write!(path, "old\n")

      failing = fn from, to ->
        # The temporary file is in the target's own directory, so the rename never
        # crosses a filesystem, and it holds the whole new content.
        assert Path.dirname(from) == Path.dirname(to)
        assert File.read!(from) == "new\n"
        {:error, :eacces}
      end

      assert Paths.write_atomic(path, "new\n", rename: failing) == {:error, :eacces}
      assert File.read!(path) == "old\n"
      assert File.ls!(dir) == ["answers.json"]
    end

    test "owner_only restricts the temporary file before the rename, and the file keeps it", %{dir: dir} do
      path = Path.join(dir, "tokens.json")
      me = self()

      rename = fn from, to ->
        send(me, {:restricted, Troupe.OwnerOnly.restricted?(from)})
        File.rename(from, to)
      end

      assert Paths.write_atomic(path, "secret\n", owner_only: true, rename: rename) == :ok
      assert_received {:restricted, true}
      assert Troupe.OwnerOnly.restricted?(path)
    end

    # A reader that opened the file before a save reads the file as it was, not a
    # truncated or half-written one: the save replaced it rather than rewriting it.
    # Unix only, since Windows refuses to rename over a file another handle holds open.
    test "the trust answers are replaced whole, never rewritten in place", %{dir: dir} do
      workspace = Path.join(dir, "repo")
      File.mkdir_p!(workspace)

      saves = [
        {Troupe.Commands.Trust, fn -> Troupe.Commands.Trust.approve(dir, workspace, %{name: "b", body: "B"}) end,
         fn -> Troupe.Commands.Trust.approve(dir, workspace, %{name: "a", body: "A"}) end},
        {Troupe.MCP.Trust, fn -> Troupe.MCP.Trust.approve(dir, workspace, [%{name: "b", fingerprint: "f"}]) end,
         fn -> Troupe.MCP.Trust.approve(dir, workspace, [%{name: "a", fingerprint: "f"}]) end}
      ]

      for {module, first, second} <- saves, not match?({:win32, _}, :os.type()) do
        assert first.() == :ok
        before = File.read!(module.path(dir))
        {:ok, reader} = File.open(module.path(dir), [:read])

        assert second.() == :ok
        assert IO.read(reader, :eof) == before
        File.close(reader)
        refute File.read!(module.path(dir)) == before
      end
    end
  end
end
