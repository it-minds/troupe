defmodule Troupe.EditorTest do
  @moduledoc """
  The person's editor (TUI Decision 156): which one, from `VISUAL` and `EDITOR` split as a
  shell splits them, and a run of it that returns when it closes, with what it wrote.
  """

  use ExUnit.Case, async: false

  alias Troupe.Editor

  test "VISUAL wins over EDITOR, and a line is split as a shell would split it" do
    sh = System.find_executable("sh")

    assert {^sh, ["-c", "exit 0", "the editor"]} =
             Editor.command(%{"VISUAL" => "sh -c 'exit 0' \"the editor\"", "EDITOR" => "vi"})

    assert {^sh, []} = Editor.command(%{"VISUAL" => "  ", "EDITOR" => "sh"})
    assert {:missing, "no-such-editor-y26"} = Editor.command(%{"EDITOR" => "no-such-editor-y26"})
  end

  test "an editor that is not there says so rather than failing quietly" do
    previous = System.get_env("EDITOR")
    System.put_env("EDITOR", "no-such-editor-y26")
    System.delete_env("VISUAL")

    on_exit(fn ->
      if previous, do: System.put_env("EDITOR", previous), else: System.delete_env("EDITOR")
    end)

    assert {:error, "no editor: no-such-editor-y26 is not on the PATH" <> _} =
             Editor.edit(Path.join(System.tmp_dir!(), "nothing.md"))
  end

  # On Windows a console program is started hidden, which a program with a window must
  # not be: the executable's header says which it is.
  test "a Windows executable's header says whether it has a window of its own" do
    dir = Path.join(System.tmp_dir!(), "troupe-pe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    pe = fn subsystem ->
      offset = 128
      dos = "MZ" <> :binary.copy(<<0>>, 58) <> <<offset::little-32>>
      padding = :binary.copy(<<0>>, offset - byte_size(dos))
      dos <> padding <> "PE" <> <<0, 0>> <> :binary.copy(<<0>>, 20 + 68) <> <<subsystem::little-16>>
    end

    for {name, bytes, gui?} <- [
          {"notepad.exe", pe.(2), true},
          {"powershell.exe", pe.(3), false},
          {"code.cmd", "@echo off\r\n", false},
          {"short.exe", "MZ", false}
        ] do
      path = Path.join(dir, name)
      File.write!(path, bytes)
      assert Editor.windows_gui?(path) == gui?, name
    end

    refute Editor.windows_gui?(Path.join(dir, "missing.exe"))
  end

  # The suite runs on Linux and macOS, where the editor is given the terminal.
  test "the editor runs on the file, has the terminal, and is waited for" do
    path = Path.join(System.tmp_dir!(), "troupe-editor-#{System.unique_integer([:positive])}.md")
    File.write!(path, "before\n")
    on_exit(fn -> File.rm(path) end)

    previous = System.get_env("VISUAL")
    System.put_env("VISUAL", ~s(sh -c 'sleep 0.2; printf "after\\n" > "$1"' editor))

    on_exit(fn ->
      if previous, do: System.put_env("VISUAL", previous), else: System.delete_env("VISUAL")
    end)

    assert {:terminal, :ok} = Editor.edit(path)
    assert File.read!(path) == "after\n"

    System.put_env("VISUAL", "sh -c 'exit 3' editor")
    assert {:terminal, {:error, "sh exited 3"}} = Editor.edit(path)
  end
end
