defmodule Troupe.NativeToolsTest do
  @moduledoc """
  The tools added to displace read-only shell usage: `git_read` (20% of
  read-only shell), multi-path `read_file` (the batching 43% reached for) and
  `glob` (what `find` was doing inside batched calls).
  """
  use ExUnit.Case, async: true

  import Troupe.TestHelpers, only: [run_git!: 2]

  alias Troupe.Tool.Context
  alias Troupe.Tools.{GitRead, Glob, ReadFile}

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-native-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: Path.expand(dir), ctx: %Context{workspace: Path.expand(dir), session_id: "s1"}}
  end

  defp repo!(dir) do
    run_git!(dir, ["init", "--quiet"])
    run_git!(dir, ["config", "user.email", "t@example.com"])
    run_git!(dir, ["config", "user.name", "T"])
    File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\nend\n")
    run_git!(dir, ["add", "."])
    run_git!(dir, ["commit", "--quiet", "-m", "first commit"])
    :ok
  end

  describe "git_read" do
    test "status reports a modified file", %{dir: dir, ctx: ctx} do
      repo!(dir)
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\n  def x, do: 1\nend\n")

      assert {:ok, out} = GitRead.run(%{"op" => "status"}, ctx)
      assert out =~ "lib/a.ex"
    end

    test "diff shows the change, and staged shows nothing until staged", %{dir: dir, ctx: ctx} do
      repo!(dir)
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\n  def x, do: 1\nend\n")

      assert {:ok, out} = GitRead.run(%{"op" => "diff"}, ctx)
      assert out =~ "def x, do: 1"

      assert {:ok, staged} = GitRead.run(%{"op" => "diff", "staged" => true}, ctx)
      assert staged == "(no output)"

      run_git!(dir, ["add", "."])
      assert {:ok, staged} = GitRead.run(%{"op" => "diff", "staged" => true}, ctx)
      assert staged =~ "def x, do: 1"
    end

    test "log lists commits and honours limit", %{dir: dir, ctx: ctx} do
      repo!(dir)
      File.write!(Path.join(dir, "lib/b.ex"), "defmodule B do\nend\n")
      run_git!(dir, ["add", "."])
      run_git!(dir, ["commit", "--quiet", "-m", "second commit"])

      assert {:ok, out} = GitRead.run(%{"op" => "log"}, ctx)
      assert out =~ "first commit"
      assert out =~ "second commit"

      assert {:ok, one} = GitRead.run(%{"op" => "log", "limit" => 1}, ctx)
      assert one =~ "second commit"
      refute one =~ "first commit"
    end

    test "show and branch work", %{dir: dir, ctx: ctx} do
      repo!(dir)

      assert {:ok, show} = GitRead.run(%{"op" => "show"}, ctx)
      assert show =~ "first commit"

      assert {:ok, branch} = GitRead.run(%{"op" => "branch"}, ctx)
      assert branch =~ ~r/\bma(in|ster)\b/
    end

    test "path narrows the read", %{dir: dir, ctx: ctx} do
      repo!(dir)
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\n  def x, do: 1\nend\n")
      File.write!(Path.join(dir, "lib/b.ex"), "defmodule B do\nend\n")

      assert {:ok, out} = GitRead.run(%{"op" => "diff", "path" => "lib/a.ex"}, ctx)
      assert out =~ "lib/a.ex"
      refute out =~ "lib/b.ex"
    end

    # An argument list is only injection-proof while a value cannot become a flag.
    test "a ref or path that looks like a flag is refused", %{dir: dir, ctx: ctx} do
      repo!(dir)

      assert {:error, msg} =
               GitRead.run(%{"op" => "show", "ref" => "--upload-pack=touch /tmp/x"}, ctx)

      assert msg =~ "may not start with"

      assert {:error, msg} = GitRead.run(%{"op" => "diff", "path" => "--output=/tmp/x"}, ctx)
      assert msg =~ "may not start with"
    end

    test "an unknown op is refused rather than passed to git", %{dir: dir, ctx: ctx} do
      repo!(dir)
      assert {:error, msg} = GitRead.run(%{"op" => "push"}, ctx)
      assert msg =~ "unknown op"
    end

    test "is registered as a read-only tool" do
      assert {:ok, GitRead} = Troupe.Tools.fetch("git_read")
      assert "git_read" in Troupe.Tools.read_only()
      assert GitRead.default_permission() == :auto
    end
  end

  describe "read_file with several paths" do
    test "reads them all under headers in one call", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\nend\n")
      File.write!(Path.join(dir, "lib/b.ex"), "defmodule B do\nend\n")

      assert {:ok, out} = ReadFile.run(%{"paths" => ["lib/a.ex", "lib/b.ex"]}, ctx)
      assert out =~ "===== lib/a.ex ====="
      assert out =~ "defmodule A"
      assert out =~ "===== lib/b.ex ====="
      assert out =~ "defmodule B"
    end

    test "a missing file is reported in place, the others still read", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\nend\n")

      assert {:ok, out} = ReadFile.run(%{"paths" => ["lib/a.ex", "lib/gone.ex"]}, ctx)
      assert out =~ "defmodule A"
      assert out =~ "cannot read lib/gone.ex"
    end

    test "an empty or non-list paths is refused", %{ctx: ctx} do
      assert {:error, msg} = ReadFile.run(%{"paths" => []}, ctx)
      assert msg =~ "non-empty list"
      assert {:error, _} = ReadFile.run(%{"paths" => "lib/a.ex"}, ctx)
    end

    test "single path still works unchanged", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\nend\n")

      assert {:ok, out} = ReadFile.run(%{"path" => "lib/a.ex"}, ctx)
      assert out =~ "defmodule A"
      refute out =~ "====="
    end
  end

  describe "glob" do
    test "matches a pattern and excludes directories", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "lib/a.ex"), "")
      File.write!(Path.join(dir, "lib/b.exs"), "")

      assert {:ok, out} = Glob.run(%{"pattern" => "lib/**/*.ex"}, ctx)
      assert out =~ "lib/a.ex"
      refute out =~ "b.exs"
    end

    test "sorts most recently modified first", %{dir: dir, ctx: ctx} do
      old = Path.join(dir, "lib/old.ex")
      new = Path.join(dir, "lib/new.ex")
      File.write!(old, "")
      File.write!(new, "")
      File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})

      assert {:ok, out} = Glob.run(%{"pattern" => "lib/*.ex"}, ctx)
      lines = String.split(out, "\n", trim: true)
      assert Enum.find_index(lines, &(&1 =~ "new.ex")) < Enum.find_index(lines, &(&1 =~ "old.ex"))
    end

    test "says so when nothing matches", %{ctx: ctx} do
      assert {:ok, "no files match " <> _} = Glob.run(%{"pattern" => "**/*.nope"}, ctx)
    end

    test "is registered as a read-only tool" do
      assert {:ok, Glob} = Troupe.Tools.fetch("glob")
      assert "glob" in Troupe.Tools.read_only()
    end
  end
end
