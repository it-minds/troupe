defmodule Troupe.UI.Browser do
  @moduledoc """
  Open a URL in the person's browser: a sign-in to an MCP server that wants them
  (troupe-remote Decision 741), which the daemon on this machine runs and listens for.

  The platform's own opener, started without a shell so nothing in the URL is read as a
  command: `rundll32 url.dll,FileProtocolHandler` on Windows, `open` on macOS,
  `xdg-open` elsewhere. Not waited for. When there is none — a box reached over SSH,
  say — the caller shows the URL instead, and the person opens it on this machine.
  """

  @spec open(String.t()) :: :ok | {:error, String.t()}
  def open(url) do
    {program, args} = command(:os.type(), url)

    case System.find_executable(program) do
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
