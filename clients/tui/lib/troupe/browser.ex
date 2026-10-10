defmodule Troupe.Browser do
  @moduledoc """
  Open a URL in the person's browser: a sign-in to an MCP server that wants them
  (troupe-remote Decision 741), which the daemon on this machine runs and listens for.

  The platform's own opener, started without a shell so nothing in the URL is read as a
  command: `rundll32 url.dll,FileProtocolHandler` on Windows, `open` on macOS,
  `xdg-open` elsewhere, each found on the `PATH` alone (`Troupe.OS.Process.executable/2`,
  Decision 846): a `rundll32.bat` in the repository the TUI was started in is not the
  opener. Not waited for. When there is none — a box reached over SSH, say — the caller
  shows the URL instead, and the person opens it on this machine.

  The UI reaches it through `Troupe.Client.open_url/1`, as it reaches the clipboard.
  """

  @spec open(String.t()) :: :ok | {:error, String.t()}
  def open(url) do
    {program, args} = command(:os.type(), url)

    case Troupe.OS.Process.executable(program) do
      nil ->
        {:error, "#{program} is not on the PATH"}

      path ->
        {:ok, _pid} =
          Task.start(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

        :ok
    end
  end

  defp command({:win32, _}, url), do: {"rundll32", ["url.dll,FileProtocolHandler", url]}
  defp command({:unix, :darwin}, url), do: {"open", [url]}
  defp command(_unix, url), do: {"xdg-open", [url]}
end
