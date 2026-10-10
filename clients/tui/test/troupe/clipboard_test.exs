defmodule Troupe.ClipboardTest do
  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Clipboard

  describe "Clipboard.copy/1" do
    test "hands the text to the configured command, byte for byte" do
      path = clipboard_path()

      text = "first\nsecond\twith a tab\nüñïçodé and a 'quote'"
      assert {:ok, _cmd} = Clipboard.copy(text)
      assert File.read!(path) == text
    end

    test "leaves no temp file behind" do
      before = staged_files()
      assert {:ok, _} = Clipboard.copy("x")
      assert staged_files() == before
    end

    test "reports a command that fails instead of claiming success" do
      previous = Application.get_env(:troupe, :clipboard_command)
      Application.put_env(:troupe, :clipboard_command, "exit 3")
      on_exit(fn -> Application.put_env(:troupe, :clipboard_command, previous) end)

      assert {:error, msg} = Clipboard.copy("x")
      assert msg =~ "exited 3"
    end

    test "says what it looked for when the machine has no clipboard" do
      previous = Application.get_env(:troupe, :clipboard_command)
      Application.delete_env(:troupe, :clipboard_command)
      on_exit(fn -> Application.put_env(:troupe, :clipboard_command, previous) end)

      # Whether this machine has a clipboard is not the point; both answers must
      # be something the notice line can show.
      case Clipboard.command() do
        nil ->
          assert {:error, msg} = Clipboard.copy("x")
          assert msg =~ "no clipboard command here"

        cmd ->
          assert is_binary(cmd)
      end
    end
  end

  # D109: on every OS, what cmd.exe is given on Windows. `clip < "<path>"` as one argument
  # reached cmd.exe with Erlang's escaped quotes, which it cannot read.
  test "on Windows, cmd.exe is given clip by its path on PATH and the staged file by its name" do
    bin = Path.join(System.tmp_dir!(), "troupe-clipboard-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "clip.exe"), "")
    on_exit(fn -> File.rm_rf!(bin) end)

    staged = Path.join(System.tmp_dir!(), "troupe-clip-7")
    opts = [os: {:win32, :nt}, path: bin, pathext: ".COM;.EXE"]

    assert ["/c", clip, "<", "troupe-clip-7"] = Clipboard.windows_argv("clip", staged, opts)
    assert clip == String.replace(Path.join(bin, "clip.exe"), "/", "\\")
  end

  defp staged_files,
    do: System.tmp_dir!() |> Path.join("troupe-clip-*") |> Path.wildcard() |> length()

  describe "copying a transcript" do
    test "Ctrl-Y copies the activated pane, and /copy <n> copies without activating" do
      path = clipboard_path()

      ws = tmp_workspace()

      {sid, _, _} =
        start_session!(workspace: ws, script: [{:text, "the reply worth keeping"}, {:finish, "ok"}])

      say!(sid, "do the thing")
      await_done()

      {pid, session} = start_tui(sid)

      # Ctrl-Y in the activated window.
      press(pid, "1")
      press(pid, "y", ["ctrl"])
      assert screen_text(pid, session) =~ "copied"
      copied = File.read!(path)
      assert copied =~ "do the thing"
      assert copied =~ "the reply worth keeping"

      # y alone is an approval answer, not a copy: it must not have written again.
      File.rm!(path)
      press(pid, "y")
      refute File.exists?(path)

      # /copy from the command line, naming the tile.
      press(pid, "esc")
      type(pid, "/copy 1")
      press(pid, "enter")
      assert File.read!(path) =~ "the reply worth keeping"
      assert screen_text(pid, session) =~ "copied"
    end

    test "/copy with nothing activated and no argument says so" do
      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws)
      {pid, session} = start_tui(sid)

      # The palette's Space puts the command on the line, where Enter runs it.
      type(pid, "/copy ")
      press(pid, "enter")
      assert screen_text(pid, session) =~ "no window given"
    end
  end
end
