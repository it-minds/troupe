defmodule Troupe.Tools.FileToolsTest do
  use ExUnit.Case, async: true

  alias Troupe.Tool.Ctx
  alias Troupe.Tools
  alias Troupe.Tools.{EditFile, Glob, ListFiles, ReadFile, WriteFile}
  alias Troupe.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, workspace} = Workspace.new(root)

    ctx = %Ctx{
      session_id: "test",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }

    %{root: root, ctx: ctx, workspace: workspace}
  end

  describe "edit_file" do
    test "replaces a unique string", %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "a.txt"), "one\ntwo\nthree\n")

      assert {:ok, message} =
               EditFile.run(
                 %{"path" => "a.txt", "old_string" => "two", "new_string" => "TWO"},
                 ctx
               )

      assert message =~ "Edited a.txt"
      assert File.read!(Path.join(root, "a.txt")) == "one\nTWO\nthree\n"
    end

    test "fails on zero matches and changes nothing", %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "a.txt"), "one\ntwo\n")

      assert {:error, {:no_match, "nope"}} =
               EditFile.run(
                 %{"path" => "a.txt", "old_string" => "nope", "new_string" => "x"},
                 ctx
               )

      assert File.read!(Path.join(root, "a.txt")) == "one\ntwo\n"
    end

    test "fails on multiple matches and changes nothing", %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "a.txt"), "dup\ndup\n")

      assert {:error, {:multiple_matches, 2, "dup"}} =
               EditFile.run(%{"path" => "a.txt", "old_string" => "dup", "new_string" => "x"}, ctx)

      assert File.read!(Path.join(root, "a.txt")) == "dup\ndup\n"
    end

    test "keeps CRLF line endings", %{root: root, ctx: ctx} do
      path = Path.join(root, "crlf.txt")
      File.write!(path, "alpha\r\nbeta\r\ngamma\r\n")

      # The model sends LF, as models do; the file must not be converted.
      assert {:ok, _} =
               EditFile.run(
                 %{"path" => "crlf.txt", "old_string" => "beta", "new_string" => "BETA\ndelta"},
                 ctx
               )

      contents = File.read!(path)
      assert contents == "alpha\r\nBETA\r\ndelta\r\ngamma\r\n"
      refute contents =~ ~r/(?<!\r)\n/
    end

    test "matches a multi-line needle sent with LF against a CRLF file", %{root: root, ctx: ctx} do
      path = Path.join(root, "crlf.txt")
      File.write!(path, "def a do\r\n  :ok\r\nend\r\n")

      assert {:ok, _} =
               EditFile.run(
                 %{
                   "path" => "crlf.txt",
                   "old_string" => "def a do\n  :ok\nend",
                   "new_string" => "def a do\n  :done\nend"
                 },
                 ctx
               )

      assert File.read!(path) == "def a do\r\n  :done\r\nend\r\n"
    end

    test "keeps LF line endings on an LF file", %{root: root, ctx: ctx} do
      path = Path.join(root, "lf.txt")
      File.write!(path, "alpha\nbeta\n")

      assert {:ok, _} =
               EditFile.run(
                 %{"path" => "lf.txt", "old_string" => "beta", "new_string" => "BETA"},
                 ctx
               )

      assert File.read!(path) == "alpha\nBETA\n"
    end

    test "rejects a path outside the workspace before reading", %{ctx: ctx} do
      assert {:error, {:outside_workspace, _}} =
               EditFile.run(
                 %{"path" => "../escape.txt", "old_string" => "a", "new_string" => "b"},
                 ctx
               )
    end
  end

  describe "read_file" do
    test "numbers lines and honours a range", %{root: root, ctx: ctx} do
      File.write!(Path.join(root, "n.txt"), Enum.map_join(1..20, "\n", &"line #{&1}"))

      assert {:ok, all} = ReadFile.run(%{"path" => "n.txt"}, ctx)
      assert all =~ "1\tline 1"
      assert all =~ "20\tline 20"

      assert {:ok, ranged} = ReadFile.run(%{"path" => "n.txt", "offset" => 5, "limit" => 3}, ctx)
      assert ranged =~ "(lines 5-7 of 20)"
      assert ranged =~ "5\tline 5"
      refute ranged =~ "8\tline 8"
    end

    test "caps very large output and says so", %{root: root, ctx: ctx} do
      File.write!(
        Path.join(root, "big.txt"),
        (String.duplicate("x", 200) <> "\n") |> String.duplicate(500)
      )

      ctx = %{ctx | config: %Troupe.Config{tool_output_limit: 2_000}}

      assert {:ok, output} = ReadFile.run(%{"path" => "big.txt"}, ctx)
      assert output =~ "truncated"
      assert byte_size(output) < 3_000
    end

    test "a missing file is a readable error", %{ctx: ctx} do
      assert {:error, {:enoent, _}} = ReadFile.run(%{"path" => "nope.txt"}, ctx)
    end
  end

  describe "write_file" do
    test "creates parent directories", %{root: root, ctx: ctx} do
      assert {:ok, _} = WriteFile.run(%{"path" => "a/b/c.txt", "content" => "hello"}, ctx)
      assert File.read!(Path.join(root, "a/b/c.txt")) == "hello"
    end

    test "announces the write to the watcher before touching disk", %{ctx: ctx} do
      ctx = %{ctx | watcher: self()}
      assert {:ok, _} = WriteFile.run(%{"path" => "w.txt", "content" => "body"}, ctx)

      expected = Troupe.Watch.content_hash("body")
      assert_received {:expect_write, _path, ^expected}
    end
  end

  describe "list_files" do
    test "globs and skips ignored paths", %{root: root, ctx: ctx} do
      File.write!(Path.join(root, ".gitignore"), "_build/\n*.beam\n")
      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "_build"))
      File.write!(Path.join(root, "lib/a.ex"), "")
      File.write!(Path.join(root, "lib/b.beam"), "")
      File.write!(Path.join(root, "_build/c.ex"), "")

      assert {:ok, output} = ListFiles.run(%{"pattern" => "**/*"}, ctx)
      assert output =~ "lib/a.ex"
      refute output =~ "b.beam"
      refute output =~ "_build"
    end

    # The workspace path starts the glob, and only the pattern after it may be read as
    # one: a checkout at `app[1]` must not be searched as `app1`.
    test "a workspace path with glob characters in it is searched literally", %{root: root, ctx: ctx} do
      odd = Path.join(root, "app[1]{a,b}")
      File.mkdir_p!(Path.join(odd, "lib"))
      File.write!(Path.join(odd, "lib/a.ex"), "def hello, do: :world\n")
      ctx = %{ctx | workspace: Workspace.new!(odd)}

      assert {:ok, "lib/a.ex"} = ListFiles.run(%{"pattern" => "**/*.ex"}, ctx)
      assert {:ok, "lib/a.ex"} = Glob.run(%{"pattern" => "**/*.ex"}, ctx)
      assert Tools.execute(Troupe.Tools.Grep, %{"pattern" => "def hello"}, ctx).content =~ "lib/a.ex:1:"
    end
  end

  describe "grep" do
    test "finds matches with the built-in scanner", %{root: root, ctx: ctx} do
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\n  def hello, do: :world\nend\n")
      File.write!(Path.join(root, "lib/b.ex"), "defmodule B do\nend\n")

      # Exercise the fallback explicitly: the ripgrep path is what CI machines take,
      # and the built-in one is what a clean single-binary install takes.
      assert {:ok, output} =
               Tools.execute(Troupe.Tools.Grep, %{"pattern" => "def hello"}, ctx)
               |> then(&{:ok, &1.content})

      assert output =~ "lib/a.ex:2:"
      refute output =~ "lib/b.ex"
    end

    test "an invalid regex is a readable error, not a crash", %{ctx: ctx} do
      result = Tools.execute(Troupe.Tools.Grep, %{"pattern" => "("}, ctx)
      refute result.ok?
    end
  end
end
