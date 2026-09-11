defmodule Troupe.UI.TUI do
  @moduledoc """
  Entry point for the terminal UI.

  Owns the terminal for the life of the command and returns an exit code when the
  user quits. The UI itself is `Troupe.UI.TUI.Server`, an `ExRatatui.App` that holds
  its own `Troupe.Protocol.Client` — it is a protocol client with no private access to
  anything, and quitting it leaves the session running in the daemon.
  """

  alias Troupe.UI.TUI.Server

  @doc """
  Run the TUI against a session in the daemon. Blocks until the user quits.

  `connect_opts` are passed to `Troupe.Protocol.Daemon.connect/1`; the view connects
  for itself, because events have to arrive at the process that draws them.
  """
  @spec run(String.t(), struct(), keyword()) :: non_neg_integer()
  def run(session_id, options, connect_opts \\ []) do
    opts = [
      session_id: session_id,
      connect: connect_opts,
      watch: Map.get(options, :watch) || false,
      owner: self(),
      # Unnamed so a second session in the same VM cannot collide with the first.
      name: nil
    ]

    case Server.start_link(opts) do
      {:ok, pid} -> await(pid)
      # A UI that declined to start (no terminal, for instance) is not a crash.
      :ignore -> fail(:no_terminal)
      {:error, reason} -> fail(reason)
    end
  end

  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:tui_exit, code} ->
        Process.demonitor(ref, [:flush])
        code

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        0

      {:DOWN, ^ref, :process, ^pid, reason} ->
        IO.puts(:stderr, "troupe: the TUI stopped: #{inspect(reason)}")
        1
    end
  end

  defp fail(reason) do
    IO.puts(:stderr, """
    troupe: could not start the terminal UI: #{describe(reason)}

    This needs a real terminal. For CI or a pipe, use:
        troupe run "your task" --headless
    """)

    1
  end

  defp describe(:no_terminal), do: "no usable terminal"
  defp describe(reason), do: inspect(reason)
end
