defmodule Troupe.Clipboard do
  @moduledoc """
  Copies text to the system clipboard with the platform's own clipboard
  command: `pbcopy` on macOS, `clip` on Windows, `wl-copy` under Wayland and
  `xclip`/`xsel` under X11.

  The text reaches the command through a temporary file rather than its stdin,
  because `Troupe.OS.Process` — the only way the harness starts a process —
  gives the reaper that pipe and points the child's stdin at `/dev/null`. The
  file lives for the length of one `pbcopy` and is removed either way.

  A machine can have no clipboard at all (a bare container, a host reached over
  ssh), so `copy/1` returns which commands it looked for instead of failing
  silently.

  `config :troupe, clipboard_command: "…"` replaces the guess with a command of
  your own — a tmux buffer or an OSC-52 helper over ssh — and is how the tests
  avoid clobbering the clipboard of whoever is running them. It is used as a
  shell command with the staged file redirected into it, so it needs a shell
  with `<`: on Windows without Git Bash the shell is PowerShell, and the command
  is refused with a sentence saying so (D115).
  """

  alias Troupe.OS

  @timeout_ms 5_000

  @doc """
  Copies `text`, returning the command that took it so the caller can say where
  the text went, or a message explaining why this machine has no clipboard.
  """
  @spec copy(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def copy(text) when is_binary(text) do
    case command() do
      nil -> {:error, missing_message()}
      name -> stage_and_run(name, text)
    end
  end

  @doc "The clipboard command this machine would use, or nil when it has none."
  @spec command() :: String.t() | nil
  def command do
    case Application.get_env(:troupe, :clipboard_command) do
      cmd when is_binary(cmd) -> cmd
      _ -> Enum.find(candidates(), &OS.Process.executable/1)
    end
  end

  # Wayland first when a compositor is up: wl-copy talks to the session the user
  # is looking at, while xclip on the same box talks to XWayland's.
  defp candidates do
    case :os.type() do
      {:win32, _} -> ["clip"]
      {:unix, :darwin} -> ["pbcopy"]
      _ -> wayland_first() ++ ["xclip", "xsel", "wl-copy"]
    end
  end

  defp wayland_first, do: if(System.get_env("WAYLAND_DISPLAY"), do: ["wl-copy"], else: [])

  defp argv("xclip"), do: "xclip -selection clipboard"
  defp argv("xsel"), do: "xsel --clipboard --input"
  defp argv(name), do: name

  defp stage_and_run(name, text) do
    path = Path.join(System.tmp_dir!(), "troupe-clip-#{:erlang.unique_integer([:positive])}")

    case File.write(path, staged(name, text)) do
      :ok ->
        result = run(name, path)
        File.rm(path)
        report(name, result)

      {:error, reason} ->
        {:error, "could not stage the text: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The bytes `name` is given for `text` on `os_type`. Windows' `clip` reads a file with no
  byte-order mark in the console's code page, so anything but ASCII could arrive garbled
  (D115); it is given UTF-16LE with the mark, which is how it is told the text is Unicode,
  whatever the code page. Every other command gets the text as it is, in UTF-8.
  """
  @spec staged(String.t(), String.t(), {atom(), atom()}) :: binary()
  def staged(name, text, os_type \\ :os.type())

  def staged("clip", text, {:win32, _}),
    do: <<0xFF, 0xFE>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

  def staged(_name, text, _os_type), do: text

  # Redirection, not a pipe, so nothing depends on the shell's job control. On
  # Windows the platform shell may be PowerShell, which has no `<` at all, so
  # `clip` is fed by cmd.exe rather than through `OS.Process.shell/2`.
  defp run("clip", path) do
    OS.Process.run("cmd.exe", windows_argv("clip", path),
      cd: Path.dirname(path),
      timeout_ms: @timeout_ms
    )
  end

  defp run(name, path) do
    {shell, _description} = OS.Process.shell_info()

    with {:ok, line} <- shell_line(argv(name), path, shell),
         do: OS.Process.shell(line, timeout_ms: @timeout_ms)
  end

  @doc """
  The line the platform shell `shell` (its program's name) is given to feed `command` the
  file at `path`, or why it cannot be: PowerShell, Windows' shell without Git Bash, has no
  `<`, and a `clipboard_command` failed there with its parser's error (D115).
  """
  @spec shell_line(String.t(), Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def shell_line(command, path, shell) do
    if String.starts_with?(String.downcase(shell), ["pwsh", "powershell"]) do
      {:error,
       "clipboard_command is given the text with `<`, which PowerShell, the shell here " <>
         "without Git Bash, does not have; install Git for Windows, or unset clipboard_command " <>
         "to copy with clip"}
    else
      {:ok, "#{command} < '#{path}'"}
    end
  end

  @doc """
  What cmd.exe is given to feed `name` the file at `path`, which it runs in the file's
  directory (D109): the command by its path on `PATH`, so cmd.exe does not look for it in
  a directory of its own choosing, and the file by its name, in arguments of their own.
  `clip < "<path>"` as one argument reached cmd.exe with its quotes escaped the way Erlang
  escapes them, which cmd.exe does not read: "The filename, directory name, or volume label
  syntax is incorrect." `opts` are `OS.Process.executable/2`'s.
  """
  @spec windows_argv(String.t(), Path.t(), keyword()) :: [String.t()]
  def windows_argv(name, path, opts \\ []),
    do: ["/c", OS.Process.executable(name, opts) || name, "<", Path.basename(path)]

  defp report(name, {:ok, _output, 0}), do: {:ok, name}

  defp report(name, {:ok, output, status}),
    do: {:error, "#{name} exited #{status}: #{first_line(output)}"}

  defp report(name, {:error, :timeout, _output}), do: {:error, "#{name} did not finish in time"}
  defp report(_name, {:error, sentence}) when is_binary(sentence), do: {:error, sentence}

  defp first_line(""), do: "no output"
  defp first_line(output), do: output |> String.split("\n") |> hd() |> String.trim()

  defp missing_message do
    case :os.type() do
      {:win32, _} -> "no clipboard command here (clip)"
      {:unix, :darwin} -> "no clipboard command here (pbcopy)"
      _ -> "no clipboard command here; install xclip, xsel or wl-clipboard"
    end
  end
end
