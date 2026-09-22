defmodule Troupe.GitignoreTest do
  use ExUnit.Case, async: true

  alias Troupe.Gitignore

  @moduletag :tmp_dir

  test "reads the root file, nested files and .git/info/exclude", %{tmp_dir: root} do
    write(root, ".gitignore", "*.log\n")
    write(root, "lib/.gitignore", "generated/\n!keep.log\n")
    write(root, ".git/info/exclude", "scratch\n")

    ignore = Gitignore.load(root)

    assert Gitignore.ignored?(ignore, "a.log")
    assert Gitignore.ignored?(ignore, "lib/generated/x.ex")
    refute Gitignore.ignored?(ignore, "generated/x.ex")
    refute Gitignore.ignored?(ignore, "lib/keep.log")
    assert Gitignore.ignored?(ignore, "scratch")
    assert Gitignore.ignored?(ignore, ".git/config")
  end

  # Git does not read a .gitignore inside a directory it already ignores, and neither
  # does this: entering `node_modules` is what made a session start take minutes.
  test "does not enter an ignored directory or .git", %{tmp_dir: root} do
    write(root, ".gitignore", "node_modules/\n")
    write(root, "node_modules/pkg/.gitignore", "*.ex\n")
    write(root, ".git/.gitignore", "*.ex\n")
    # A repository vendored inside this one: its .git is as uninteresting as the root's.
    write(root, "vendor/repo/.git/.gitignore", "*.ex\n")

    ignore = Gitignore.load(root)

    assert length(ignore.rules) == 1
    refute Gitignore.ignored?(ignore, "lib/a.ex")
  end

  test "does not follow a symlinked directory", %{tmp_dir: root} do
    write(root, "real/.gitignore", "*.ex\n")

    case File.ln_s(Path.join(root, "real"), Path.join(root, "link")) do
      :ok ->
        ignore = Gitignore.load(root)
        assert Gitignore.ignored?(ignore, "real/a.ex")
        refute Gitignore.ignored?(ignore, "link/a.ex")

      {:error, _} ->
        # Windows without the symlink privilege. Nothing to test.
        :ok
    end
  end

  defp write(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
