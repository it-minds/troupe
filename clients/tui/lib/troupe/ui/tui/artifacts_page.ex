defmodule Troupe.UI.TUI.ArtifactsPage do
  @moduledoc """
  `/artifacts` (root #62): the person's artifacts on the plane, by who can
  see them, in the desktop app's words and glyphs — All, ◉ Everyone at the organisation,
  ◎ Your teams (a team's and a profile's), ◐ Shared with you (through a link), ○ Only you —
  each row its title, kind, version, whose it is (`team finance` for a team's, which every
  member of the team owns; `you`; or who published it) and when, with *new* on a version
  the person has not opened on this machine.

  An artifact is shown where it can touch nothing of the person's: in the browser, through
  the plane's one-time address (`Enter`, `v` for another version). A Markdown one is also
  read here (`m`), rendered as the transcript renders a reply, in a frame; one past 500 lines
  is cut there, and its last line offers the browser. `p` publishes a file of the workspace
  as `/publish` does (a team's where a team is named, unless `me` follows), `l` copies a view
  link to one of the person's own, `/` filters, `r` reads the list again, Esc goes back.
  Under Local only nothing is asked, and the page says so.

  It holds page state and answers keys; the server owns the process and the frame, as with
  HQ. Everything it asks goes through `Troupe.Client`, to this computer's daemon.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.TUI.{Model, Theme, View}

  # A Markdown artifact longer than this is read in the browser; the frame shows this much.
  @frame_lines 500

  @tabs [:all, :organisation, :team, :shared, :private]

  @type t :: %{
          session_id: String.t(),
          workspace: String.t(),
          local_only: boolean(),
          tab: atom(),
          rows: [map()],
          organisation: String.t() | nil,
          error: String.t() | nil,
          cursor: non_neg_integer(),
          filter: String.t(),
          filtering: boolean(),
          versions: map() | nil,
          frame: map() | nil,
          prompt: String.t() | nil,
          status: String.t() | nil
        }

  @doc "The page, read now; `tab:` opens it on one audience (HQ's line opens Shared with you)."
  @spec open(String.t(), String.t(), keyword()) :: t()
  def open(session_id, workspace, opts \\ []) do
    %{
      session_id: session_id,
      workspace: workspace,
      local_only: Client.local_only?(),
      tab: Keyword.get(opts, :tab, :all),
      rows: [],
      organisation: nil,
      error: nil,
      cursor: 0,
      filter: "",
      filtering: false,
      versions: nil,
      frame: nil,
      prompt: nil,
      status: nil
    }
    |> load()
  end

  @doc "Reads the list again, keeping the cursor on the artifact it was on where it is still there."
  @spec load(t()) :: t()
  def load(%{local_only: true} = page), do: page

  def load(page) do
    was = selected(page)

    case Client.artifacts() do
      {:ok, answer} ->
        page = %{page | rows: answer.artifacts, organisation: answer.organisation, error: nil}
        index = was && Enum.find_index(visible(page), &(&1["id"] == was["id"]))
        %{page | cursor: index || min(page.cursor, max(length(visible(page)) - 1, 0))}

      {:error, reason} ->
        %{page | rows: [], error: reason}
    end
  end

  @doc "The rows the tab and the filter leave, newest first."
  @spec visible(t()) :: [map()]
  def visible(page) do
    query = String.downcase(page.filter)

    Enum.filter(page.rows, fn row ->
      (page.tab == :all or Client.audience_of(row) == page.tab) and
        (query == "" or String.contains?(String.downcase(haystack(row)), query))
    end)
  end

  defp haystack(row),
    do: Enum.join([row["title"], row["kind"], Client.artifact_owner(row), row["visibility"]], " ")

  defp selected(page), do: Enum.at(visible(page), page.cursor)

  ## Keys

  @doc "Answers a key: `{:ok, page}`, or `:close` for Esc on the list."
  @spec key(t(), map()) :: {:ok, t()} | :close
  def key(%{prompt: text} = page, key) when is_binary(text), do: prompt_key(page, key)
  def key(%{filtering: true} = page, key), do: filter_key(page, key)
  def key(%{frame: %{}} = page, key), do: frame_key(page, key)
  def key(%{versions: %{}} = page, key), do: versions_key(page, key)
  def key(_page, %{code: "esc"}), do: :close
  def key(%{local_only: true} = page, _key), do: {:ok, page}

  def key(page, %{code: "right"}), do: {:ok, tab(page, 1)}
  def key(page, %{code: "left"}), do: {:ok, tab(page, -1)}
  def key(page, %{code: "tab"}), do: {:ok, tab(page, 1)}

  def key(page, %{code: <<d>>, modifiers: []}) when d in ?1..?5,
    do: {:ok, %{page | tab: Enum.at(@tabs, d - ?1), cursor: 0, status: nil}}

  def key(page, %{code: code}) when code in ["up", "k"], do: {:ok, move(page, -1)}
  def key(page, %{code: code}) when code in ["down", "j"], do: {:ok, move(page, 1)}
  def key(page, %{code: "/"}), do: {:ok, %{page | filtering: true, status: nil}}
  def key(page, %{code: "r"}), do: {:ok, %{load(page) | status: "read again"}}
  def key(page, %{code: "p"}), do: {:ok, %{page | prompt: "", status: nil}}
  def key(page, %{code: "enter"}), do: {:ok, open_selected(page, nil)}
  def key(page, %{code: "v"}), do: {:ok, versions(page)}
  def key(page, %{code: "m"}), do: {:ok, markdown(page, selected(page), nil)}
  def key(page, %{code: "l"}), do: {:ok, link(page)}
  def key(page, _key), do: {:ok, page}

  defp tab(page, step) do
    index = Enum.find_index(@tabs, &(&1 == page.tab)) || 0

    %{
      page
      | tab: Enum.at(@tabs, rem(index + step + length(@tabs), length(@tabs))),
        cursor: 0,
        status: nil
    }
  end

  defp move(page, step) do
    last = max(length(visible(page)) - 1, 0)
    %{page | cursor: (page.cursor + step) |> max(0) |> min(last)}
  end

  defp filter_key(page, %{code: "esc"}),
    do: {:ok, %{page | filtering: false, filter: "", cursor: 0}}

  defp filter_key(page, %{code: "enter"}), do: {:ok, %{page | filtering: false}}

  defp filter_key(page, %{code: "backspace"}),
    do: {:ok, %{page | filter: String.slice(page.filter, 0..-2//1), cursor: 0}}

  defp filter_key(page, %{code: code, modifiers: mods}) when mods in [[], ["shift"]] do
    if String.length(code) == 1,
      do: {:ok, %{page | filter: page.filter <> code, cursor: 0}},
      else: {:ok, page}
  end

  defp filter_key(page, _key), do: {:ok, page}

  ## Opening, in the browser and here

  # The plane's one-time address, opened in the browser: the artifacts host signs the person
  # in from it and shows the artifact under its own policy, never in this terminal.
  defp open_selected(page, version) do
    case selected(page) do
      nil -> page
      row -> open_in_browser(page, row, version)
    end
  end

  defp open_in_browser(page, row, version) do
    case Client.open_artifact(row["id"], version) do
      {:ok, url} ->
        _ = Client.artifact_seen(row["id"], version || row["version"])

        rows =
          Enum.map(page.rows, &if(&1["id"] == row["id"], do: Map.put(&1, "new", false), else: &1))

        %{page | rows: rows, status: browsed(Client.open_url(url), row, version, url)}

      {:error, reason} ->
        %{page | status: "“#{row["title"]}” could not be opened: #{reason}"}
    end
  end

  defp browsed(:ok, row, version, _url),
    do: "opened “#{row["title"]}” #{v(version || row["current"] || row["version"])} in the browser"

  defp browsed({:error, why}, _row, _version, url),
    do: "the browser could not be started (#{why}); open this within a minute: #{url}"

  defp versions(page) do
    case selected(page) do
      nil ->
        page

      row ->
        case Client.artifact(row["id"]) do
          {:ok, artifact} ->
            rows = Enum.sort_by(Elixir.List.wrap(artifact["versions"]), &(-(&1["n"] || 0)))
            %{page | versions: %{row: row, rows: rows, cursor: 0}, status: nil}

          {:error, reason} ->
            %{page | status: "the versions of “#{row["title"]}” could not be read: #{reason}"}
        end
    end
  end

  defp versions_key(page, %{code: "esc"}), do: {:ok, %{page | versions: nil}}

  defp versions_key(%{versions: vs} = page, %{code: code}) when code in ["up", "k", "down", "j"] do
    step = if code in ["up", "k"], do: -1, else: 1

    {:ok,
     %{
       page
       | versions: %{vs | cursor: (vs.cursor + step) |> max(0) |> min(max(length(vs.rows) - 1, 0))}
     }}
  end

  defp versions_key(%{versions: vs} = page, %{code: "enter"}) do
    case Enum.at(vs.rows, vs.cursor) do
      nil -> {:ok, page}
      version -> {:ok, open_in_browser(%{page | versions: nil}, vs.row, version["n"])}
    end
  end

  defp versions_key(%{versions: vs} = page, %{code: "m"}) do
    case Enum.at(vs.rows, vs.cursor) do
      nil -> {:ok, page}
      version -> {:ok, markdown(%{page | versions: nil}, vs.row, version["n"])}
    end
  end

  defp versions_key(page, _key), do: {:ok, page}

  # A Markdown artifact's text, fetched through the daemon and drawn as the transcript draws a
  # reply, in a frame; any other kind is the browser's to show.
  defp markdown(page, nil, _version), do: page

  defp markdown(page, %{"kind" => "markdown"} = row, version) do
    case Client.read_artifact(row["id"], version) do
      {:ok, %{"text" => text} = read} ->
        source = String.split(text, "\n")
        shown = Enum.take(source, @frame_lines)
        lines = Model.frame(Model.markdown(Enum.join(shown, "\n")))

        more =
          if length(source) > @frame_lines,
            do: [
              {:muted,
               "… #{length(source) - @frame_lines} more lines: Enter opens the whole of it in the browser"}
            ],
            else: []

        _ = Client.artifact_seen(row["id"], read["version"] || row["version"])

        %{
          page
          | frame: %{row: row, version: read["version"], lines: lines ++ more, scroll: 0},
            status: nil
        }

      {:error, reason} ->
        %{page | status: "“#{row["title"]}” could not be read here: #{reason}"}
    end
  end

  defp markdown(page, row, _version),
    do: %{
      page
      | status:
          "“#{row["title"]}” is #{kind_words(row["kind"])}: Enter opens it in the browser; m reads Markdown here"
    }

  defp frame_key(page, %{code: "esc"}), do: {:ok, %{page | frame: nil}}

  defp frame_key(%{frame: f} = page, %{code: "enter"}),
    do: {:ok, open_in_browser(page, f.row, f.version)}

  defp frame_key(%{frame: f} = page, %{code: code}) do
    step =
      case code do
        c when c in ["up", "k"] -> -1
        c when c in ["down", "j"] -> 1
        "page_up" -> -20
        "page_down" -> 20
        "home" -> -1_000_000
        "end" -> 1_000_000
        _ -> 0
      end

    {:ok, %{page | frame: %{f | scroll: max(f.scroll + step, 0)}}}
  end

  ## Publishing and links

  # `p`: `/publish`'s line, typed on the page — a path in the workspace, who it is for,
  # Only you where nothing is named, and `me` where a team publication is to stay the
  # person's own rather than the team's.
  defp prompt_key(page, %{code: "esc"}), do: {:ok, %{page | prompt: nil}}

  defp prompt_key(page, %{code: "backspace"}),
    do: {:ok, %{page | prompt: String.slice(page.prompt, 0..-2//1)}}

  defp prompt_key(page, %{code: "enter"}) do
    case String.split(page.prompt, ~r/\s+/, trim: true) do
      [] ->
        {:ok, %{page | prompt: nil}}

      [path | rest] ->
        visibility = Elixir.List.first(rest) || "private"
        owner = Enum.at(rest, 1)
        local = Path.expand(path, page.workspace)

        status =
          case Client.publish_file(local, visibility, session_id: page.session_id, owner: owner) do
            {:ok, artifact} ->
              "published #{path} as #{artifact["id"]} version #{artifact["version"]}" <>
                if(artifact["owner_team"], do: " (team #{artifact["owner_team"]}'s)", else: "")

            {:error, reason} ->
              "#{path} not published: #{reason}"
          end

        {:ok, %{load(%{page | prompt: nil}) | status: status}}
    end
  end

  defp prompt_key(page, %{code: code, modifiers: mods}) when mods in [[], ["shift"]] do
    if String.length(code) == 1, do: {:ok, %{page | prompt: page.prompt <> code}}, else: {:ok, page}
  end

  defp prompt_key(page, _key), do: {:ok, page}

  # A view link is the owner's to make; it is copied where the person can paste it, and
  # shown whole whichever way, since a terminal may take the copy and say nothing.
  defp link(page) do
    case selected(page) do
      nil ->
        page

      %{"mine" => true} = row ->
        case Client.artifact_link(row["id"]) do
          {:ok, url} ->
            case Client.copy_link(url) do
              {:ok, how} ->
                %{page | status: "a view link to “#{row["title"]}”, copied by #{how}: #{url}"}

              {:error, why} ->
                %{page | status: "a view link to “#{row["title"]}” (not copied: #{why}): #{url}"}
            end

          {:error, reason} ->
            %{page | status: "no link to “#{row["title"]}”: #{reason}"}
        end

      row ->
        %{
          page
          | status:
              "“#{row["title"]}” is #{Client.artifact_owner(row)}'s: only its owner makes links to it"
        }
    end
  end

  ## Rendering

  @doc "The page in `rect`."
  @spec render(t(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(page, rect, _state) do
    [tabs_rect, body_rect, status_rect] =
      Layout.split(rect, :vertical, [{:length, 1}, {:fill, 1}, {:length, 2}])

    [
      {%Paragraph{text: tabs_line(page)}, tabs_rect},
      {body(page, body_rect), body_rect},
      {%Paragraph{text: status_text(page), wrap: true, style: Theme.style(:muted)}, status_rect}
    ]
  end

  @doc "The line under the page that says what the keys do."
  @spec footer(t()) :: String.t()
  def footer(%{local_only: true}), do: " artifacts — Local only: the plane is not asked · Esc back "

  def footer(%{prompt: text}) when is_binary(text),
    do:
      " publish — a path, who it is for, me to keep a team's yours · Enter publishes · Esc cancels "

  def footer(%{filtering: true}), do: " filter — type to narrow · Enter keeps it · Esc clears "
  def footer(%{frame: %{}}), do: " ↑↓ PgUp PgDn scroll · Enter opens it in the browser · Esc back "

  def footer(%{versions: %{}}),
    do: " ↑↓ a version · Enter opens it in the browser · m reads it here · Esc back "

  def footer(_page),
    do:
      " artifacts — ←/→ or 1–5 who for · ↑↓ · Enter opens in the browser · v version · m read here · " <>
        "p publish · l link · / filter · r refresh · Esc back "

  defp tabs_line(page) do
    spans =
      @tabs
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {tab, n} ->
        label = "#{n} #{tab_label(page, tab)} #{count(page, tab)}"
        style = if tab == page.tab, do: Theme.style(:accent, [:bold]), else: Theme.style(:muted)
        [Span.new(" " <> label <> " ", style: style), Span.new("·", style: Theme.style(:rail))]
      end)
      |> Enum.drop(-1)

    Line.new(spans)
  end

  defp tab_label(_page, :all), do: "All"

  defp tab_label(page, audience) do
    {glyph, name} = Client.artifact_audience(audience, page.organisation)
    glyph <> " " <> name
  end

  defp count(%{local_only: true}, _tab), do: ""
  defp count(page, :all), do: length(page.rows)
  defp count(page, tab), do: Enum.count(page.rows, &(Client.audience_of(&1) == tab))

  defp body(%{local_only: true}, _rect) do
    %Paragraph{
      text:
        "Local only: the plane is not asked.\n\nThis terminal's local_only setting is on, so nothing of " <>
          "yours on the plane is listed or opened from here. Turn it off in your user config to browse them.",
      wrap: true,
      block: %Block{title: " artifacts ", borders: [:all]}
    }
  end

  defp body(%{frame: %{} = f}, rect) do
    width = max(rect.width - 2, 1)
    height = max(rect.height - 2, 1)
    offset = min(f.scroll, max(Model.row_count(f.lines, width) - height, 0))

    %Paragraph{
      text: View.frame_rows(f.lines, width, offset, height),
      wrap: false,
      block: %Block{
        title: " #{Model.one_line(f.row["title"] || "")} · #{v(f.version)} — Esc back ",
        borders: [:all]
      }
    }
  end

  defp body(%{versions: %{} = vs}, _rect) do
    items =
      Enum.map(vs.rows, fn version ->
        who =
          get_in(version, ["published_by", "display_name"]) ||
            get_in(version, ["published_by", "subject"]) || ""

        note = if version["note"], do: " · " <> Model.one_line(version["note"]), else: ""
        "#{v(version["n"])}  #{who}  #{ago(version["published_at"])}#{note}"
      end)

    %List{
      items: if(items == [], do: ["(no versions)"], else: items),
      selected: if(items == [], do: nil, else: vs.cursor),
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold]),
      block: %Block{
        title: " versions of #{Model.one_line(vs.row["title"] || "")} ",
        borders: [:all]
      }
    }
  end

  defp body(page, rect) do
    rows = visible(page)
    title_w = rect.width |> Kernel.-(74) |> max(16) |> min(56)

    items =
      cond do
        is_binary(page.error) ->
          [page.error]

        rows == [] and page.filter != "" ->
          ["Nothing matches “#{page.filter}”: Esc on / clears it."]

        rows == [] ->
          [empty(page.tab)]

        true ->
          Enum.map(rows, &row_line(&1, title_w))
      end

    title =
      if page.filter == "",
        do: " artifacts — #{tab_label(page, page.tab)} ",
        else: " artifacts — #{tab_label(page, page.tab)} · “#{page.filter}” "

    %List{
      items: items,
      selected: if(rows == [], do: nil, else: page.cursor),
      highlight_symbol: "▸ ",
      highlight_style: Theme.style(:accent, [:bold]),
      block: %Block{title: title, borders: [:all], border_type: :double}
    }
  end

  defp empty(:shared),
    do: "Nothing shared with you yet: a link someone sends you lands here once you open it."

  defp empty(:private),
    do: "Nothing only yours yet: p publishes a file of this workspace for you alone."

  defp empty(_tab),
    do:
      "Nothing here yet. p publishes a file of this workspace; an agent publishes with publish_artifact."

  defp row_line(row, title_w) do
    {glyph, _name} = Client.artifact_audience(Client.audience_of(row))
    title = clip(Model.one_line(row["title"] || row["id"]), title_w)

    rest =
      String.pad_trailing(kind_word(row["kind"]), 9) <>
        String.pad_trailing(v(row["current"] || row["version"]), 5) <>
        String.pad_trailing(clip(Client.artifact_owner(row), 16), 17) <>
        String.pad_trailing(ago(row["published_at"]), 14) <> clip(where(row), 16)

    new =
      if row["new"],
        do: [Span.new(" new ", style: Theme.style(:accent, [:bold]))],
        else: [Span.new("     ")]

    Line.new(
      [Span.new(glyph <> " ")] ++
        new ++
        [
          Span.new(String.pad_trailing(title, title_w + 1)),
          Span.new(rest, style: Theme.style(:muted))
        ]
    )
  end

  defp where(%{"visibility" => "team:" <> team}), do: team
  defp where(%{"visibility" => "profile:" <> profile}), do: "profile " <> profile
  defp where(_row), do: ""

  defp status_text(%{prompt: text}) when is_binary(text),
    do:
      "publish: " <>
        text <>
        "▏  (a path, then private, organisation, team:<name> or profile:<name>; Only you when none; " <>
        "then me where a team's is to stay yours)"

  defp status_text(%{filtering: true} = page), do: "/" <> page.filter <> "▏"
  defp status_text(%{status: status}) when is_binary(status), do: status
  defp status_text(_page), do: ""

  defp kind_word("html"), do: "page"
  defp kind_word("markdown"), do: "markdown"
  defp kind_word(_file), do: "file"

  defp kind_words("html"), do: "a page"
  defp kind_words(_file), do: "a file"

  defp v(nil), do: "current"
  defp v(n), do: "v#{n}"

  defp clip(text, room) do
    if String.length(text) <= room, do: text, else: String.slice(text, 0, max(room - 1, 1)) <> "…"
  end

  @doc "When, as a person says it: `Troupe.Client.ago/1`."
  @spec ago(String.t() | nil) :: String.t()
  def ago(at), do: Client.ago(at)
end
