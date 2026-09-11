defmodule Troupe.UI.TUI do
  @moduledoc """
  Entry point for the terminal UI.

  Owns the terminal for the life of the session and returns an exit code when the
  user quits. The UI itself is `Troupe.UI.TUI.Server`, an `ExRatatui.App` subscribed
  to `Troupe.Events` — it is only a subscriber, so it can crash and restart without
  the session noticing.
  """

  alias Troupe.UI.TUI.Server

  @doc "Run the TUI against a session. Blocks until the user quits."
  @spec run(map(), struct()) :: non_neg_integer()
  def run(session, options) do
    case Troupe.UI.Supervisor.attach({Server, session_opts(session, options)}) do
      {:ok, pid} -> await(pid)
      # A UI that declined to start (no terminal, for instance) is not a crash.
      :ignore -> fail(:no_terminal)
      {:error, reason} -> fail(reason)
    end
  end

  defp session_opts(session, options) do
    [
      session_id: session.id,
      workspace: session.workspace,
      watch: options.watch || false,
      owner: self(),
      # Unnamed so a second session in the same VM cannot collide with the first.
      name: nil
    ]
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
