defmodule Troupe.UI.TUI.ProfilesPage do
  @moduledoc """
  `/profiles` and `/profile <name>`: what a profile the person may use gives a session,
  before they start one.

  `/profiles` lists them, one line each with its summary (`3 agents · severa, sursen ·
  reaches github.com · 2 of 8 sessions`); Enter on a row, or `/profile <name>`, opens the
  profile's page in a frame drawn as `/settings` draws its own, double-ruled and titled,
  in six groups in reading order: Agents (and those not here, with why), Tools (the rules,
  then each MCP server with whose access it runs as, and those not offered, dimmed), Model,
  Reach, Limits and Who. The words are `Troupe.UI.ProfileView`'s, which the command line
  prints too. The frame scrolls with ↑↓, PgUp/PgDn, Home/End and the wheel; Esc or `q`
  goes back to the list it was opened from, or closes.

  A profile the person may not use is said to be one, never drawn empty; a plane from
  before `profile.get`, Local only and no sign-in are each a sentence in the frame. It
  holds page state and answers keys; the server owns the process, as with the other pages.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.ProfileView
  alias Troupe.UI.TUI.Theme

  @type t :: %{
          origin: Client.origin() | nil,
          rows: [map()],
          error: String.t() | nil,
          cursor: non_neg_integer(),
          page: map() | nil,
          page_error: String.t() | nil,
          name: String.t() | nil,
          scroll: non_neg_integer(),
          from_list: boolean(),
          status: String.t() | nil
        }

  @doc """
  The page, read now: the list, or with a name that profile's page; `origin` is a plane,
  or nil for the one this machine is signed in to.
  """
  @spec open(Client.origin() | nil, String.t() | nil) :: t()
  def open(origin, name \\ nil) do
    page = %{
      origin: origin,
      rows: [],
      error: nil,
      cursor: 0,
      page: nil,
      page_error: nil,
      name: nil,
      scroll: 0,
      from_list: false,
      status: nil
    }

    if name in [nil, ""], do: load(page), else: show(page, name)
  end

  @doc "Reads the list again, the cursor kept on the profile it was on where it is still there."
  @spec load(t()) :: t()
  def load(page) do
    was = Enum.at(page.rows, page.cursor)

    case Client.offered_profiles(page.origin) do
      {:ok, rows} ->
        index = was && Enum.find_index(rows, &(&1["name"] == was["name"]))

        %{
          page
          | rows: rows,
            error: nil,
            cursor: index || min(page.cursor, max(length(rows) - 1, 0))
        }

      {:error, reason} ->
        %{page | rows: [], error: Client.profile_refusal(reason)}
    end
  end

  defp show(page, name) do
    case Client.profile_page(page.origin, name) do
      {:ok, answer} ->
        %{page | page: answer, page_error: nil, name: name, scroll: 0}

      {:error, reason} ->
        %{page | page: nil, page_error: Client.profile_refusal(reason, name), name: name, scroll: 0}
    end
  end

  defp open?(page), do: page.name != nil

  ## Keys

  @doc "Answers a key: `{:ok, page}`, or `:close` for Esc or `q` on what it was opened on."
  @spec key(t(), map()) :: {:ok, t()} | :close
  def key(page, %{code: code}) when code in ["esc", "q"] do
    if open?(page) and page.from_list,
      do: {:ok, %{page | page: nil, page_error: nil, name: nil, scroll: 0}},
      else: :close
  end

  def key(page, %{code: code} = key) do
    if open?(page), do: {:ok, scroll(page, step(code))}, else: list_key(page, key)
  end

  defp list_key(page, %{code: code}) when code in ["up", "k"], do: {:ok, move(page, -1)}
  defp list_key(page, %{code: code}) when code in ["down", "j"], do: {:ok, move(page, 1)}
  defp list_key(page, %{code: "r"}), do: {:ok, %{load(page) | status: "read again"}}

  defp list_key(page, %{code: "enter"}) do
    case Enum.at(page.rows, page.cursor) do
      %{"name" => name} -> {:ok, %{show(page, name) | from_list: true}}
      _ -> {:ok, page}
    end
  end

  defp list_key(page, _key), do: {:ok, page}

  defp move(page, step) do
    last = max(length(page.rows) - 1, 0)
    %{page | cursor: (page.cursor + step) |> max(0) |> min(last)}
  end

  @doc "Scrolls an open page by `step` rows, never above its top."
  @spec scroll(t(), integer()) :: t()
  def scroll(page, step), do: %{page | scroll: max(page.scroll + step, 0)}

  defp step(code) when code in ["up", "k"], do: -1
  defp step(code) when code in ["down", "j"], do: 1
  defp step("page_up"), do: -20
  defp step("page_down"), do: 20
  defp step("home"), do: -1_000_000
  defp step("end"), do: 1_000_000
  defp step(_code), do: 0

  ## Rendering

  @doc "The page in `rect`."
  @spec render(t(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(page, rect, _state) do
    [body_rect, status_rect] = Layout.split(rect, :vertical, [{:fill, 1}, {:length, 1}])

    [
      {body(page, body_rect), body_rect},
      {%Paragraph{text: page.status || "", style: Theme.style(:muted)}, status_rect}
    ]
  end

  @doc "The line under the page that says what the keys do."
  @spec footer(t()) :: String.t()
  def footer(%{name: name, from_list: true}) when is_binary(name),
    do: " profile — ↑↓ PgUp PgDn or the wheel scrolls · Esc or q back to the list "

  def footer(%{name: name}) when is_binary(name),
    do: " profile — ↑↓ PgUp PgDn or the wheel scrolls · Esc or q closes "

  def footer(_page),
    do: " profiles — ↑↓ move · Enter opens what it gives a session · r refresh · Esc or q back "

  defp body(%{name: name, page_error: error}, _rect) when is_binary(name) and is_binary(error) do
    %Paragraph{text: error, wrap: true, block: block(" profile — #{name} ")}
  end

  defp body(%{name: name, page: answer} = page, rect) when is_binary(name) do
    width = max(rect.width - 2, 1)
    lines = answer |> ProfileView.lines(width) |> Enum.flat_map(&fold(&1, width))
    top = min(page.scroll, max(length(lines) - max(rect.height - 2, 1), 0))

    # Folded here rather than by the widget, whose wrapping trims the indent that says
    # which group a line is in.
    %Paragraph{
      text: Enum.map(lines, &line/1),
      scroll: {top, 0},
      block: block(" profile — #{ProfileView.name(answer)} — what a session here is given ")
    }
  end

  defp body(%{error: error}, _rect) when is_binary(error),
    do: %Paragraph{text: error, wrap: true, block: block(" profiles ")}

  defp body(page, _rect) do
    items =
      case page.rows do
        [] -> [ProfileView.list_lines([]) |> hd() |> elem(1)]
        rows -> rows |> ProfileView.list_lines() |> ProfileView.plain()
      end

    %List{
      items: items,
      selected: if(page.rows == [], do: nil, else: page.cursor),
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold]),
      block: block(" profiles — the ones you may use ")
    }
  end

  defp block(title), do: %Block{title: title, borders: [:all], border_type: :double}

  # A line wider than the frame, folded at a space, its rows under the first indented as
  # the first is.
  defp fold({kind, text}, width) do
    if String.length(text) <= width do
      [{kind, text}]
    else
      indent = String.duplicate(" ", String.length(text) - String.length(String.trim_leading(text)))

      text
      |> String.split(" ")
      |> Enum.reduce([], fn
        word, [] ->
          [word]

        word, [row | rows] ->
          if String.length(row) + 1 + String.length(word) > width,
            do: [indent <> word, row | rows],
            else: [row <> " " <> word | rows]
      end)
      |> Enum.reverse()
      |> Enum.map(&{kind, &1})
    end
  end

  defp line({:group, text}), do: Line.new([Span.new(text, style: Theme.style(:accent, [:bold]))])
  defp line({:sub, text}), do: Line.new([Span.new(text, style: Theme.style(nil, [:bold]))])
  defp line({:muted, text}), do: Line.new([Span.new(text, style: Theme.style(:muted))])
  defp line({:dimmed, text}), do: Line.new([Span.new(text, style: Theme.style(:muted, [:dim]))])
  defp line({_kind, text}), do: Line.new([Span.new(text)])
end
