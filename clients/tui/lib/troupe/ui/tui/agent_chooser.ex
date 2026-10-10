defmodule Troupe.UI.TUI.AgentChooser do
  @moduledoc """
  A popup that chooses one of the primary agents (TUI Decision 156): each row is the agent
  with where it comes from and what it may do — its model, read-only or not, whether a
  session on it gets a worktree, why it cannot run here when it cannot — and beside the
  list the highlighted agent's description and as much of its instruction as fits, read
  through `agents.get` as the cursor reaches it.

  Tab in a window opens it to switch the agent that window runs (`profile.switch`, root
  Decision 841); it knows nothing of what the choice is for, so anything that asks a
  person for an agent can open it: `open/3` with `agents.list`'s rows, `key/3` for its
  keys, `render/3` for its widgets over whatever is behind it.
  """

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.TUI.{Agents, Model, Theme}

  @typedoc """
  The rows offered, the cursor, the agent in use now (`current`, marked and where the
  cursor starts), what each was read as whole (`details`), the popup's title, and `for`,
  what the caller wants the choice for (a window to switch, say), handed back with it.
  """
  @type t :: %{
          rows: [map()],
          cursor: non_neg_integer(),
          current: String.t() | nil,
          details: %{optional(String.t()) => map()},
          title: String.t(),
          for: term()
        }

  @doc """
  A chooser over the session's primary agents, the cursor on `current`. Options: `title`,
  `for`. `{:error, reason}` when the daemon lists none.
  """
  @spec open(String.t(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, String.t()}
  def open(sid, current, opts \\ []) do
    case Client.agents(sid, "agents.list") do
      {:ok, %{"agents" => [_ | _] = rows}} ->
        chooser = %{
          rows: rows,
          cursor: Enum.find_index(rows, &(&1["name"] == current)) || 0,
          current: current,
          details: %{},
          title: Keyword.get(opts, :title, " choose an agent "),
          for: Keyword.get(opts, :for)
        }

        {:ok, fetch(chooser, sid)}

      {:ok, _none} ->
        {:error, "the daemon lists no agents to choose from"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  One key: `{:ok, chooser}` stays open, `:close` closes it, `{:pick, name}` is the choice
  (an agent that cannot run here is not picked: its reason is on its row).
  """
  @spec key(t(), Key.t(), String.t()) :: {:ok, t()} | :close | {:pick, String.t()}
  def key(_chooser, %Key{code: "esc"}, _sid), do: :close

  def key(chooser, %Key{code: code}, sid) when code in ["up", "k", "backtab"],
    do: {:ok, move(chooser, -1, sid)}

  def key(chooser, %Key{code: code}, sid) when code in ["down", "j", "tab"],
    do: {:ok, move(chooser, 1, sid)}

  def key(chooser, %Key{code: "home"}, sid), do: {:ok, move(chooser, -1_000, sid)}
  def key(chooser, %Key{code: "end"}, sid), do: {:ok, move(chooser, 1_000, sid)}

  def key(chooser, %Key{code: "enter"}, _sid) do
    case Enum.at(chooser.rows, chooser.cursor) do
      %{"available" => false} -> {:ok, chooser}
      %{"name" => name} -> {:pick, name}
      nil -> :close
    end
  end

  def key(chooser, _key, _sid), do: {:ok, chooser}

  defp move(chooser, by, sid) do
    last = max(length(chooser.rows) - 1, 0)
    fetch(%{chooser | cursor: chooser.cursor |> Kernel.+(by) |> max(0) |> min(last)}, sid)
  end

  # The highlighted agent read whole once, for its instruction.
  defp fetch(chooser, sid) do
    case Enum.at(chooser.rows, chooser.cursor) do
      %{"name" => name} when not is_map_key(chooser.details, name) ->
        case Client.agents(sid, "agents.get", %{name: name}) do
          {:ok, whole} -> %{chooser | details: Map.put(chooser.details, name, whole)}
          {:error, _reason} -> chooser
        end

      _other ->
        chooser
    end
  end

  @doc "The popup's widgets, centred in `area` above `bottom` (the row where the command box starts)."
  @spec render(t(), Rect.t(), non_neg_integer()) :: [{term(), Rect.t()}]
  def render(chooser, area, bottom) do
    top_height = max(bottom - 1, 3)
    width = area.width |> Kernel.-(4) |> min(120) |> max(min(area.width, 24))
    height = top_height |> Kernel.-(2) |> min(28) |> max(min(top_height, 6))

    rect = %Rect{
      x: div(area.width - width, 2),
      y: max(div(top_height - height, 2), 0),
      width: width,
      height: height
    }

    [list_rect, detail_rect] =
      if width >= 90,
        do: Layout.split(rect, :horizontal, [{:fill, 1}, {:fill, 1}]),
        else: Layout.split(rect, :vertical, [{:fill, 1}, {:length, min(9, div(height, 2))}])

    name_w = chooser.rows |> Enum.map(&String.length(&1["name"])) |> Enum.max(fn -> 6 end)

    list = %ExRatatui.Widgets.List{
      items: Enum.map(chooser.rows, &row_line(&1, chooser.current, name_w)),
      selected: chooser.cursor,
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold]),
      block: %Block{title: chooser.title, borders: [:all], border_type: :double}
    }

    detail = %Paragraph{
      text: detail(chooser, detail_rect),
      wrap: true,
      block: %Block{title: " ↑↓ choose · Enter switches · Esc keeps it ", borders: [:all]}
    }

    [{%Clear{}, rect}, {list, list_rect}, {detail, detail_rect}]
  end

  # The agent in use is marked ahead of the rest of its row, where a narrow popup still
  # shows it.
  defp row_line(row, current, name_w) do
    style = if row["available"] == false, do: Theme.style(:muted), else: Theme.style(nil)
    now = if row["name"] == current, do: "● ", else: "  "

    Line.new([
      Span.new(String.pad_trailing(row["name"], name_w + 1),
        style: Map.put(style, :modifiers, [:bold])
      ),
      Span.new(now, style: Theme.style(:ok, [:bold])),
      Span.new(Agents.layer_word(row["layer"]), style: Agents.layer_style(row["layer"])),
      Span.new(" · " <> Enum.join(Agents.badges(row), " · "), style: style)
    ])
  end

  defp detail(chooser, rect) do
    case Enum.at(chooser.rows, chooser.cursor) do
      nil ->
        ""

      row ->
        whole = Map.get(chooser.details, row["name"], row)

        head = [
          String.trim(to_string(whole["description"] || "")),
          "",
          "may: " <> Agents.permission_words(whole["permissions"])
        ]

        head =
          if row["available"] == false,
            do: head ++ ["", "cannot run here: #{row["reason"]}"],
            else: head

        width = max(rect.width - 2, 1)

        used =
          head
          |> Enum.flat_map(&String.split(&1, "\n"))
          |> Enum.map(&Model.height(&1, width, :word))
          |> Enum.sum()

        room = max(rect.height - 2 - used - 2, 0)

        lines =
          whole["prompt"]
          |> to_string()
          |> Model.sanitize()
          |> String.split("\n")
          |> Enum.map(&("│ " <> &1))

        Enum.join(head ++ ["", "instruction:"] ++ Enum.take(lines, room), "\n")
    end
  end
end
