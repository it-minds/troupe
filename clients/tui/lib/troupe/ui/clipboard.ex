defmodule Troupe.UI.Clipboard do
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
  shell command with the staged file redirected into it.
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
      _ -> Enum.find(candidates(), &System.find_executable/1)
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

    case File.write(path, text) do
      :ok ->
        result = run(name, path)
        File.rm(path)
        report(name, result)

      {:error, reason} ->
        {:error, "could not stage the text: #{:file.format_error(reason)}"}
    end
  end

  # Redirection, not a pipe, so nothing depends on the shell's job control. On
  # Windows the platform shell may be PowerShell, which has no `<` at all, so
  # `clip` is fed by cmd.exe rather than through `OS.Process.shell/2`.
  defp run("clip", path),
    do: OS.Process.run("cmd.exe", ["/c", "clip < \"#{path}\""], timeout_ms: @timeout_ms)

  defp run(name, path),
    do: OS.Process.shell("#{argv(name)} < '#{path}'", timeout_ms: @timeout_ms)

  defp report(name, {:ok, _output, 0}), do: {:ok, name}

  defp report(name, {:ok, output, status}),
    do: {:error, "#{name} exited #{status}: #{first_line(output)}"}

  defp report(name, {:error, :timeout, _output}), do: {:error, "#{name} did not finish in time"}

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
