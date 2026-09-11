defmodule Troupe.TUIHelpers do
  @moduledoc "Starts the TUI on a headless CellSession and reads the screen back as text."

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias Troupe.UI.TUI

  @width 220
  @height 40

  def tui_opts(sid, extra \\ []) do
    session = CellSession.new(@width, @height)

    opts =
      Keyword.merge(
        [
          mod: TUI.Server,
          session_id: sid,
          transport: {:cell_session, session, fn _ -> :ok end},
          name: nil,
          on_quit: fn -> :ok end
        ],
        extra
      )

    {session, opts}
  end

  def start_tui(sid, extra \\ []) do
    {session, opts} = tui_opts(sid, extra)
    {:ok, pid} = ExRatatui.Server.start_link(opts)
    {pid, session}
  end

  @doc "Forces a render and returns the screen as a list of row strings."
  def screen(pid, session) do
    send(pid, :force_render)
    _ = :sys.get_state(pid)
    snap = CellSession.take_cells(session)

    snap.cells
    |> Enum.group_by(& &1.row)
    |> Enum.sort()
    |> Enum.map(fn {_row, cells} ->
      cells |> Enum.sort_by(& &1.col) |> Enum.map_join("", & &1.symbol) |> String.trim_trailing()
    end)
  end

  def screen_text(pid, session), do: pid |> screen(session) |> Enum.join("\n")

  def press(pid, code, mods \\ []) do
    :ok = ExRatatui.Runtime.inject_event(pid, %Key{code: code, kind: "press", modifiers: mods})
  end

  def type(pid, text), do: text |> String.graphemes() |> Enum.each(&press(pid, &1))

  def user_state(pid), do: :sys.get_state(pid).user_state
end
