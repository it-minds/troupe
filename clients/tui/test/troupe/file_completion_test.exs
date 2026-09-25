defmodule Troupe.FileCompletionTest do
  @moduledoc """
  Tab after `@` on the command line completes a path under the workspace, whatever the
  workspace is called and whatever has been typed.

  The completion is a glob of the workspace joined with what was typed. On Windows the
  workspace is written with backslashes, which a glob reads as escapes, and a `[` or a
  `{` in its name is read as a wildcard: either way nothing matched and Tab did nothing
  (#98). What was typed is a name, not a pattern, so a `{` in it no longer takes the
  command line down with it.
  """

  use ExUnit.Case, async: true

  alias Troupe.UI.TUI.Server

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-complete-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "a file completes to its path, and a directory to its path and a slash", %{base: base} do
    workspace(base)

    assert Server.complete_file("look at @li", base) == "look at @lib/"
    assert Server.complete_file("look at @lib/ma", base) == "look at @lib/main.ex"
    assert Server.complete_file("look at @nothing", base) == "look at @nothing"
  end

  for name <- ["ws[1]", "ws{a,b}"] do
    test "a workspace called #{name} and written with backslashes completes", %{base: base} do
      ws = Path.join(base, unquote(name))
      workspace(ws)

      # The workspace as Windows spells it. A glob reads a backslash as a separator on
      # every host, as the core does, so under Linux this is the same directory.
      windows = String.replace(ws, "/", "\\")

      assert Server.complete_file("look at @li", windows) == "look at @lib/"
      assert Server.complete_file("look at @lib/ma", windows) == "look at @lib/main.ex"
    end
  end

  test "what was typed is matched as a name, not as a pattern", %{base: base} do
    workspace(base)
    File.write!(Path.join(base, "notes[1].md"), "")
    File.write!(Path.join(base, "notes1.md"), "")
    File.write!(Path.join(base, "notes{draft}.md"), "")

    assert Server.complete_file("@notes[1]", base) == "@notes[1].md"
    assert Server.complete_file("@notes{", base) == "@notes{draft}.md"
  end

  defp workspace(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join([dir, "lib", "main.ex"]), "")
  end
end
