defmodule Troupe.GitignoreTest do
  use ExUnit.Case, async: true

  alias Troupe.Gitignore

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-gitignore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  test "rules from the root, a nested file and .git/info/exclude all apply", %{root: root} do
    write(root, ".gitignore", "*.log\n")
    write(root, "lib/.gitignore", "generated.ex\n")
    write(root, ".git/info/exclude", "scratch/\n")

    ignore = Gitignore.load(root)

    assert Gitignore.ignored?(ignore, "a.log")
    assert Gitignore.ignored?(ignore, "lib/generated.ex")
    refute Gitignore.ignored?(ignore, "generated.ex")
    assert Gitignore.ignored?(ignore, "scratch/notes.md")
    refute Gitignore.ignored?(ignore, "lib/troupe.ex")
  end

  test "a deeper .gitignore wins over its parent's", %{root: root} do
    write(root, ".gitignore", "*.txt\n")
    write(root, "docs/.gitignore", "!keep.txt\n")

    ignore = Gitignore.load(root)

    assert Gitignore.ignored?(ignore, "notes.txt")
    refute Gitignore.ignored?(ignore, "docs/keep.txt")
  end

  # Git never re-includes a file under an excluded directory, so the walk does not enter
  # one: a `!` rule in there is not read, and neither is the rest of the directory.
  test "a .gitignore inside an ignored directory is not read", %{root: root} do
    write(root, ".gitignore", "deps/\n")
    write(root, "deps/jason/.gitignore", "!*\n")

    ignore = Gitignore.load(root)

    assert Gitignore.ignored?(ignore, "deps/jason/mix.exs")
    assert Enum.all?(ignore.rules, &(&1.base == ""))
  end

  test "a missing root loads as no rules", %{root: root} do
    assert Gitignore.load(Path.join(root, "absent")).rules == []
  end
end
