defmodule Troupe.Editor do
  @moduledoc """
  Opens a file in the person's own editor and waits for it to close: `/agents`' edit
  (TUI Decision 156), which hands the definition to the daemon only once the person is
  done with it.

  The editor is `VISUAL`, then `EDITOR`, split as a shell would split it (`code --wait`
  is a program and a flag); with neither set, `notepad` on Windows and `vi` elsewhere.

  On Linux and macOS the editor gets the terminal the TUI is drawn in: it is started by
  `/bin/sh` with the terminal as its standard input and output (`:nouse_stdio`, so the port
  talks to it on descriptors 3 and 4 and leaves 0 to 2 alone), and the shell leaves the
  TUI's screen first — mouse reporting and bracketed paste off, the main screen back —
  and returns to it after, so `vi` or `nano` draw where the person is looking. The TUI
  is not reading the terminal meanwhile: it is waiting here. On Windows the editor is a
  program with a window of its own (Notepad, or `code --wait`), which needs nothing of
  the console the TUI holds; one that wants the console is not supported there.

  This is the one OS process the TUI starts outside `Troupe.OS.Process` and its reaper
  besides the file watcher (TUI Decision 19): the reaper takes the child's standard input
  and output for its own pipe, and an editor needs the terminal. The person's own editor
  on the person's own file is left open if the TUI goes, as a terminal editor would be.

  `config :troupe, :edit_file, fun` replaces it with a function of the path, which is how
  the suite edits a definition without a person at a keyboard.
  """

  # What crossterm turns on for the TUI's screen (mouse capture, SGR coordinates and
  # bracketed paste) is turned off for the editor and on again after it, around the main
  # screen and back. Only when standard output is a terminal: a test's is not.
  @leave "\\033[?1006l\\033[?1015l\\033[?1003l\\033[?1002l\\033[?1000l\\033[?2004l\\033[?1049l\\033[?25h"
  @mouse_on "\\033[?1000h\\033[?1002h\\033[?1003h\\033[?1015h\\033[?1006h"
  @back "\\033[?1049h\\033[?2004h\\033[?25l"

  @typedoc "How an edit ended: the editor closed, or why it did not run or failed."
  @type outcome :: :ok | {:error, String.t()}

  @doc """
  Opens `path` in the editor and returns once it has closed: `:ok`, or `{:error, why}`,
  wrapped as `{:terminal, outcome}` when the editor had the terminal, so the screen has to
  be drawn whole again. `mouse: true` turns mouse reporting on again after it, as the TUI
  had it.
  """
  @spec edit(String.t(), keyword()) :: outcome() | {:terminal, outcome()}
  def edit(path, opts \\ []) do
    case Application.get_env(:troupe, :edit_file) do
      fun when is_function(fun, 1) -> fun.(path)
      _ -> run(command(), path, opts)
    end
  end

  @doc """
  The editor this machine would use, as `{program, args}` with the program found on the
  PATH, or `{:missing, name}` when it is not there.
  """
  @spec command(map()) :: {String.t(), [String.t()]} | {:missing, String.t()}
  def command(env \\ System.get_env()) do
    words =
      [env["VISUAL"], env["EDITOR"]]
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
      |> case do
        nil -> [default()]
        line -> OptionParser.split(line)
      end

    [name | args] = words

    case System.find_executable(name) do
      nil -> {:missing, name}
      program -> {program, args}
    end
  end

  defp default do
    case :os.type() do
      {:win32, _} -> "notepad"
      _ -> "vi"
    end
  end

  defp run({:missing, name}, _path, _opts),
    do: {:error, "no editor: #{name} is not on the PATH; set EDITOR to one that is"}

  defp run({program, args}, path, opts) do
    case :os.type() do
      {:win32, _} ->
        Port.open({:spawn_executable, program}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args ++ [path]
        ])
        |> wait(Path.basename(program))

      _ ->
        back = if Keyword.get(opts, :mouse, false), do: @back <> @mouse_on, else: @back

        script =
          "if [ -t 1 ]; then printf '#{@leave}'; fi; \"$@\"; s=$?; " <>
            "if [ -t 1 ]; then printf '#{back}'; fi; exit $s"

        Port.open({:spawn_executable, "/bin/sh"}, [
          :nouse_stdio,
          :exit_status,
          args: ["-c", script, "troupe-editor", program | args] ++ [path]
        ])
        |> wait(Path.basename(program))
        |> then(&{:terminal, &1})
    end
  end

  # As long as it takes: the person is writing.
  defp wait(port, name) do
    receive do
      {^port, {:data, _output}} -> wait(port, name)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, "#{name} exited #{status}"}
    end
  end
end
