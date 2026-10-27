defmodule Troupe.UI.TUI.MemoryPage do
  @moduledoc """
  `/memory` (root #55): what the troupe remembers for the person, as
  entries — each `## Topic` of a level's document — in the desktop app's words. Tabs: *In
  effect* (what a new session in one of their teams starts knowing: the closest level's entry
  on each topic, and what it replaces), ◉ *Everyone at* the organisation, ◎ each of their
  teams, ○ *Only you*; a level they cannot change here says `· read`.

  On *Only you*: `a` adds an entry (its topic on the page, then its words in `$EDITOR`, or in
  a box here when no editor is set), `e` edits one, `f` forgets one after a confirm line; a
  topic the level has already is refused and one a lower level has is said to replace it;
  `h` lists the versions, two side by side, `r` rolls back to one; `b` shows who wrote each
  line; `s` where this machine's copy stands. A save names the version it was made on, and
  one saved elsewhere first is shown beside the person's own, `l` reloading it. Under Local
  only every level is read from this machine's copy and nothing is changed.

  Page state and keys; the server owns the process, the frame and the editor's hand-off.
  Everything it asks goes through `Troupe.Client`, to this computer's daemon.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.TUI.{ArtifactsPage, Model, Theme, View}

  @type t :: map()

  @doc "The page, read now."
  @spec open() :: t()
  def open do
    %{
      local_only: Client.local_only?(),
      levels: [],
      effect: [],
      organisation: nil,
      plane_url: nil,
      error: nil,
      tab: 0,
      team: nil,
      cursor: 0,
      mode: :list,
      status: nil
    }
    |> load()
  end

  @doc "Reads every level again: a save here or elsewhere, or an agent's entry, is on it."
  @spec load(t()) :: t()
  # Under Local only, from this machine's copy, what is in effect as the sessions here read it.
  def load(%{local_only: true} = page) do
    case Client.memory_status() do
      {:ok, %{held: held, in_effect: effect}} -> loaded(page, held, nil, {:copy, effect})
      {:error, reason} -> %{page | error: reason}
    end
  end

  def load(page) do
    case Client.own_memory() do
      {:ok, own} ->
        documents =
          Enum.reject(Elixir.List.wrap(own["documents"]), &(&1["scope"] == "user")) ++
            [
              %{"scope" => "user"}
              |> Map.merge(Map.take(own, ~w(version text changed_by changed_at entries)))
            ]

        page = %{page | organisation: get_in(own, ["organisation", "name"])}
        loaded(page, documents, own["plane_url"], :ask)

      {:error, reason} ->
        %{page | levels: [], error: reason}
    end
  end

  defp loaded(page, documents, url, effect) do
    levels = Client.memory_levels(documents)
    teams = Enum.filter(levels, &(&1.rank == 1))

    team =
      if Enum.any?(teams, &(&1.id == page.team)),
        do: page.team,
        else: teams |> Elixir.List.first() |> then(&(&1 && &1.id))

    page = %{page | levels: levels, plane_url: url, error: nil, team: team}
    page = in_effect(page, effect)
    %{page | cursor: min(page.cursor, max(length(rows(page)) - 1, 0))}
  end

  # What is in effect, as the plane works it out for the team chosen, or as the copy here has it.
  defp in_effect(page, {:copy, effect}), do: %{page | effect: Client.memory_effect_rows(effect, page.levels)}

  defp in_effect(page, _ask) do
    case Client.memory_in_effect(page.levels, page.team) do
      {:ok, rows} -> %{page | effect: rows}
      {:error, reason} -> %{page | effect: [], status: "what is in effect could not be read: #{reason}"}
    end
  end

  @doc "What the tab shows, as rows: an entry of a level, or a topic in effect."
  @spec rows(t()) :: [map()]
  def rows(%{tab: 0} = page), do: page.effect

  def rows(page) do
    case level(page) do
      nil -> []
      level -> Enum.map(level.entries, &%{entry: &1, from: level, replaces: []})
    end
  end

  defp level(%{tab: 0}), do: nil
  defp level(page), do: Enum.at(page.levels, page.tab - 1)

  # Only the person's own is changed here, and never under Local only.
  defp editable?(%{local_only: true}, _level), do: false
  defp editable?(_page, %{scope: "user"}), do: true
  defp editable?(_page, _level), do: false

  defp own(page), do: Enum.find(page.levels, &(&1.scope == "user"))

  ## Keys

  @doc """
  Answers a key: `{:ok, page}`, `{:edit, page, request}` for the server to open the editor
  on `request.text`, or `:close`.
  """
  @spec key(t(), map()) :: {:ok, t()} | {:edit, t(), map()} | :close
  def key(%{mode: :list}, %{code: "esc"}), do: :close
  def key(%{mode: :list} = page, key), do: list_key(page, key)
  def key(%{mode: {:topic, _}} = page, key), do: topic_key(page, key)
  def key(%{mode: {:box, _}} = page, key), do: box_key(page, key)
  def key(%{mode: {:forget, row}} = page, %{code: "y"}), do: {:ok, forget(page, row)}
  def key(%{mode: {:forget, _}} = page, _key), do: {:ok, %{page | mode: :list, status: "kept"}}

  def key(%{mode: {:conflict, c}} = page, %{code: "l"}),
    do:
      {:ok,
       %{
         load(page)
         | mode: :list,
           status: "reloaded version #{c.theirs["version"]}; your edit was not saved"
       }}

  def key(%{mode: {:history, _}} = page, key), do: history_key(page, key)
  def key(page, %{code: "esc"}), do: {:ok, %{page | mode: :list}}
  def key(%{mode: :blame} = page, %{code: "b"}), do: {:ok, %{page | mode: :list}}
  def key(page, _key), do: {:ok, page}

  defp list_key(page, %{code: code}) when code in ["right", "tab"], do: {:ok, tab(page, 1)}
  defp list_key(page, %{code: "left"}), do: {:ok, tab(page, -1)}

  defp list_key(page, %{code: <<d>>, modifiers: []}) when d in ?1..?9 do
    if d - ?1 <= length(page.levels),
      do: {:ok, %{page | tab: d - ?1, cursor: 0, status: nil}},
      else: {:ok, page}
  end

  defp list_key(page, %{code: code}) when code in ["up", "k"], do: {:ok, move(page, -1)}
  defp list_key(page, %{code: code}) when code in ["down", "j"], do: {:ok, move(page, 1)}

  defp list_key(%{tab: 0} = page, %{code: "t"}) do
    teams = page.levels |> Enum.filter(&(&1.rank == 1)) |> Enum.map(& &1.id)
    index = Enum.find_index(teams, &(&1 == page.team)) || -1
    page = %{page | team: Enum.at(teams, rem(index + 1, max(length(teams), 1))), cursor: 0}
    # The copy here reads every team at once; the plane is asked for the team chosen.
    {:ok, if(page.local_only, do: page, else: in_effect(page, :ask))}
  end

  defp list_key(page, %{code: "enter"}) do
    case Enum.at(rows(page), page.cursor) do
      nil -> {:ok, page}
      row -> {:ok, %{page | mode: {:entry, row}}}
    end
  end

  defp list_key(page, %{code: "s"}) do
    case Client.memory_status() do
      {:ok, %{lines: lines}} -> {:ok, %{page | mode: {:status, lines}}}
      {:error, reason} -> {:ok, %{page | status: "could not ask this machine's daemon: #{reason}"}}
    end
  end

  defp list_key(page, %{code: code} = key) when code in ["a", "e", "f", "h", "b", "r"] do
    level = level(page) || own(page)

    cond do
      page.local_only ->
        {:ok,
         %{page | status: "Local only: the plane is not asked, so your memory is read-only here"}}

      page.tab == 0 and code in ["a", "e", "f"] ->
        {:ok,
         %{
           page
           | status: "a, e and f change Only you's entries: #{length(page.levels) + 1} opens it"
         }}

      code in ["h", "b", "r"] and page.tab != length(page.levels) ->
        {:ok,
         %{
           page
           | status: "h, b and r are Only you's: its versions, who wrote each line, a roll back"
         }}

      not editable?(page, level) and code in ["a", "e", "f"] ->
        {:ok, %{page | status: "#{title(page, level)} is read here: #{lock(level)}"}}

      true ->
        own_key(page, key)
    end
  end

  defp list_key(page, _key), do: {:ok, page}

  defp own_key(page, %{code: "a"}), do: {:ok, %{page | mode: {:topic, ""}, status: nil}}

  defp own_key(page, %{code: "e"}) do
    case Enum.at(rows(page), page.cursor) do
      nil -> {:ok, page}
      %{entry: entry} -> body(page, entry.topic || "", entry.body, entry.topic)
    end
  end

  defp own_key(page, %{code: "f"}) do
    case Enum.at(rows(page), page.cursor) do
      %{entry: %{topic: topic}} = row when is_binary(topic) -> {:ok, %{page | mode: {:forget, row}}}
      _none -> {:ok, page}
    end
  end

  defp own_key(page, %{code: "h"}) do
    case Client.memory_history() do
      {:ok, own} ->
        {:ok,
         %{
           page
           | mode:
               {:history,
                %{versions: Elixir.List.wrap(own["versions"]), cursor: 0, mark: nil, compare: nil}}
         }}

      {:error, reason} ->
        {:ok, %{page | status: "the versions could not be read: #{reason}"}}
    end
  end

  defp own_key(page, %{code: "b"}) do
    case Client.own_memory(blame: true) do
      {:ok, %{"lines" => [_ | _] = lines}} -> {:ok, %{page | mode: {:blame, lines}}}
      {:ok, _own} -> {:ok, %{page | status: "the plane says nothing of who wrote each line"}}
      {:error, reason} -> {:ok, %{page | status: "who wrote it could not be read: #{reason}"}}
    end
  end

  defp own_key(page, %{code: "r"}), do: own_key(page, %{code: "h"})

  defp tab(page, step) do
    count = length(page.levels) + 1
    %{page | tab: rem(page.tab + step + count, count), cursor: 0, status: nil, mode: :list}
  end

  defp move(page, step),
    do: %{page | cursor: (page.cursor + step) |> max(0) |> min(max(length(rows(page)) - 1, 0))}

  # `a`: the topic first, typed here, checked against the level and the ones under it.
  defp topic_key(page, %{code: "esc"}), do: {:ok, %{page | mode: :list}}

  defp topic_key(%{mode: {:topic, t}} = page, %{code: "backspace"}),
    do: {:ok, %{page | mode: {:topic, String.slice(t, 0..-2//1)}}}

  defp topic_key(%{mode: {:topic, t}} = page, %{code: "enter"}) do
    level = own(page)

    case Client.memory_clash(page.levels, level, t) do
      _ when t == "" ->
        {:ok, page}

      {:here, _level} ->
        {:ok,
         %{
           page
           | status:
               "Only you already has a memory called “#{String.trim(t)}”. Edit that one instead, or pick another topic."
         }}

      {:lower, lower} ->
        body(
          %{
            page
            | status: "This will replace #{title(page, lower)}’s “#{String.trim(t)}” for you."
          },
          String.trim(t),
          "",
          nil
        )

      nil ->
        body(page, String.trim(t), "", nil)
    end
  end

  defp topic_key(%{mode: {:topic, t}} = page, %{code: code, modifiers: mods})
       when mods in [[], ["shift"]] do
    if String.length(code) == 1, do: {:ok, %{page | mode: {:topic, t <> code}}}, else: {:ok, page}
  end

  defp topic_key(page, _key), do: {:ok, page}

  # The entry's words: in the person's own editor, or in a box here when they have none.
  defp body(page, topic, text, was) do
    request = %{topic: topic, was: was, text: text}

    if Client.editor?(),
      do: {:edit, %{page | mode: :list}, request},
      else: {:ok, %{page | mode: {:box, Map.put(request, :draft, text)}}}
  end

  @doc "The editor closed on `request`: its words saved as the entry, or why not."
  @spec edited(t(), map(), {:ok, String.t()} | {:error, String.t()}) :: t()
  def edited(page, request, {:ok, text}) do
    words = text |> String.replace("\r\n", "\n") |> String.trim()

    cond do
      words == String.trim(request.text) ->
        %{page | status: "nothing changed; nothing was saved"}

      words == "" and request.was == nil ->
        %{page | status: "an entry needs words; nothing was saved"}

      true ->
        save_entry(page, request.topic, words, request.was)
    end
  end

  def edited(page, _request, {:error, why}), do: %{page | status: "not edited: " <> why}

  defp box_key(page, %{code: "esc"}), do: {:ok, %{page | mode: :list, status: "not saved"}}

  defp box_key(%{mode: {:box, box}} = page, %{code: "s", modifiers: ["ctrl"]}),
    do: {:ok, edited(%{page | mode: :list}, box, {:ok, box.draft})}

  defp box_key(%{mode: {:box, box}} = page, %{code: "enter"}),
    do: {:ok, %{page | mode: {:box, %{box | draft: box.draft <> "\n"}}}}

  defp box_key(%{mode: {:box, box}} = page, %{code: "backspace"}),
    do: {:ok, %{page | mode: {:box, %{box | draft: String.slice(box.draft, 0..-2//1)}}}}

  defp box_key(%{mode: {:box, box}} = page, %{code: code, modifiers: mods})
       when mods in [[], ["shift"]] do
    if String.length(code) == 1,
      do: {:ok, %{page | mode: {:box, %{box | draft: box.draft <> code}}}},
      else: {:ok, page}
  end

  defp box_key(page, _key), do: {:ok, page}

  @doc "Text pasted into the box."
  @spec paste(t(), String.t()) :: t()
  def paste(%{mode: {:box, box}} = page, text),
    do: %{page | mode: {:box, %{box | draft: box.draft <> text}}}

  def paste(%{mode: {:topic, t}} = page, text),
    do: %{page | mode: {:topic, t <> Model.one_line(text)}}

  def paste(page, _text), do: page

  defp save_entry(page, topic, words, was) do
    level = own(page)
    save(page, Client.memory_put_entry(level.entries, topic, words, was), "Saved “#{topic}”.")
  end

  defp forget(page, %{entry: entry}) do
    level = own(page)

    save(
      %{page | mode: :list},
      Client.memory_forget_entry(level.entries, entry.topic),
      "Forgotten. New sessions will not start with “#{entry.topic}”."
    )
  end

  # A save sends the level's entries over the version it was read at, which the plane writes
  # as sections; one saved elsewhere first is shown beside the text these would have been.
  defp save(page, entries, said),
    do: saved(page, Client.save_own_memory_entries(entries, own(page).version), said, Client.memory_text(entries))

  # A rollback carries no text of the person's: its conflict shows the version saved since.
  defp saved(page, result, said, text) do
    case result do
      {:ok, %{"changed" => false}} ->
        %{page | mode: :list, status: "it was as it is; nothing was saved"}

      {:ok, now} ->
        %{
          load(%{page | mode: :list})
          | status:
              "#{said} Version #{now["version"]}: your new sessions start with it, and the sessions running here read it from their next turn."
        }

      {:conflict, theirs} ->
        mine = text || "(a roll back, not saved)"
        %{page | mode: {:conflict, %{mine: mine, theirs: theirs}}, status: nil}

      {:error, reason} ->
        %{page | mode: :list, status: "not saved: #{reason}"}
    end
  end

  defp history_key(page, %{code: "esc"}), do: {:ok, %{page | mode: :list}}

  defp history_key(%{mode: {:history, %{compare: %{}} = h}} = page, _key),
    do: {:ok, %{page | mode: {:history, %{h | compare: nil}}}}

  defp history_key(%{mode: {:history, h}} = page, %{code: code})
       when code in ["up", "k", "down", "j"] do
    step = if code in ["up", "k"], do: -1, else: 1

    {:ok,
     %{
       page
       | mode:
           {:history,
            %{h | cursor: (h.cursor + step) |> max(0) |> min(max(length(h.versions) - 1, 0))}}
     }}
  end

  defp history_key(%{mode: {:history, h}} = page, %{code: " "}),
    do: {:ok, %{page | mode: {:history, %{h | mark: h.cursor}}}}

  # Two versions side by side, the older on the left: the marked one, else the one beside
  # the cursor's, as the plane reads both.
  defp history_key(%{mode: {:history, h}} = page, %{code: "enter"}) do
    other = h.mark || if(h.cursor == 0, do: min(1, length(h.versions) - 1), else: 0)

    case Enum.sort([number_at(h, other), number_at(h, h.cursor)]) do
      [older, newer] when is_integer(older) and is_integer(newer) ->
        case Client.memory_history(version: newer, against: older) do
          {:ok, both} ->
            compare = %{
              older: {older, both["against_text"] || ""},
              newer: {newer, both["text"] || ""}
            }

            {:ok, %{page | mode: {:history, %{h | compare: compare}}}}

          {:error, reason} ->
            {:ok, %{page | status: "the versions could not be read: #{reason}"}}
        end

      _none ->
        {:ok, page}
    end
  end

  defp history_key(%{mode: {:history, h}} = page, %{code: "r"}) do
    case number_at(h, h.cursor) do
      nil ->
        {:ok, page}

      n ->
        if n == own(page).version,
          do: {:ok, %{page | status: "version #{n} is the one in force"}},
          else:
            {:ok,
             saved(
               page,
               Client.rollback_own_memory(n, own(page).version),
               "Rolled back to version #{n}.",
               nil
             )}
    end
  end

  defp history_key(page, _key), do: {:ok, page}

  defp number_at(h, index), do: h.versions |> Enum.at(index) |> then(&(&1 && &1["version"]))

  ## Rendering

  @doc "The page in `rect`."
  @spec render(t(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(page, rect, _state) do
    [tabs_rect, note_rect, body_rect, status_rect] =
      Layout.split(rect, :vertical, [{:length, 1}, {:length, 1}, {:fill, 1}, {:length, 2}])

    [
      {%Paragraph{text: tabs_line(page)}, tabs_rect},
      {%Paragraph{text: note(page), style: Theme.style(:muted)}, note_rect}
    ] ++
      body(page, body_rect) ++
      [{%Paragraph{text: status_text(page), wrap: true, style: Theme.style(:muted)}, status_rect}]
  end

  @doc "The line under the page that says what the keys do."
  @spec footer(t()) :: String.t()
  def footer(%{mode: {:topic, _}}),
    do: " a memory — its topic · Enter goes on to its words · Esc cancels "

  def footer(%{mode: {:box, _}}),
    do: " its words — type · Enter a new line · Ctrl-S saves · Esc cancels "

  def footer(%{mode: {:forget, _}}), do: " y forgets it · any other key keeps it "
  def footer(%{mode: {:conflict, _}}), do: " l reloads the version saved since · Esc back "
  def footer(%{mode: {:history, %{compare: %{}}}}), do: " any key back to the versions "

  def footer(%{mode: {:history, _}}),
    do: " ↑↓ a version · Space marks one · Enter side by side · r roll back to it · Esc back "

  def footer(%{mode: :list, tab: 0}),
    do: " memory — ←/→ or 1–9 level · ↑↓ · Enter reads · t team · s status · Esc back "

  def footer(%{mode: :list}),
    do:
      " memory — ←/→ level · ↑↓ · Enter reads · a add · e edit · f forget · h versions · b who wrote it · s status · Esc back "

  def footer(_page), do: " Esc back "

  defp tabs_line(page) do
    labels =
      ["In effect"] ++
        Enum.map(page.levels, fn level ->
          {glyph, name} = glyph_name(level, page.organisation)
          read = if editable?(page, level), do: "", else: " · read"
          "#{glyph} #{name} #{length(level.entries)}#{read}"
        end)

    labels
    |> Enum.with_index()
    |> Enum.flat_map(fn {label, i} ->
      style = if i == page.tab, do: Theme.style(:accent, [:bold]), else: Theme.style(:muted)
      [Span.new(" #{i + 1} #{label} ", style: style), Span.new("‹", style: Theme.style(:rail))]
    end)
    |> Enum.drop(-1)
    |> Line.new()
  end

  defp glyph_name(%{scope: "organisation"}, nil), do: {"◉", "Everyone at your organisation"}
  defp glyph_name(%{scope: "organisation"}, name), do: {"◉", "Everyone at #{name}"}
  defp glyph_name(%{scope: "user"}, _name), do: {"○", "Only you"}
  defp glyph_name(%{name: name}, _name), do: {"◎", name}

  defp title(page, level), do: level |> glyph_name(page && page[:organisation]) |> elem(1)

  defp lock(%{scope: "organisation"}), do: "platform administrators keep it, in the console"
  defp lock(%{name: name}), do: "#{name}'s team admins change it, in the console"

  defp note(%{local_only: true}),
    do:
      "Local only: the plane is not asked. Read from this machine's copy; nothing is changed here."

  defp note(%{tab: 0} = page),
    do:
      "A new session in #{team_name(page)} starts knowing this; the closer level wins: yours over your team's, your team's over the organisation's."

  defp note(page) do
    case level(page) do
      %{scope: "organisation"} ->
        "The baseline: every session in every team starts with these unless a team or you say otherwise."

      %{scope: "user"} ->
        "Applies to every session you start, in any team. Nobody else can see these, not even admins."

      %{name: name} ->
        "Applies to every #{name} session; overrides the organisation's memory on the same topic."

      nil ->
        ""
    end
  end

  defp team_name(%{team: nil}), do: "no team"

  defp team_name(page),
    do: page.levels |> Enum.find(&(&1.id == page.team)) |> then(&((&1 && &1.name) || "no team"))

  defp body(%{error: error}, rect) when is_binary(error),
    do: [
      {%Paragraph{text: error, wrap: true, block: %Block{title: " memory ", borders: [:all]}}, rect}
    ]

  defp body(%{mode: {:entry, row}}, rect) do
    width = max(rect.width - 2, 1)
    lines = Model.frame(Model.markdown(row.entry.body))

    replaced =
      Enum.flat_map(row.replaces, fn under ->
        [
          {:muted, ""},
          {:muted, "replaces #{title(nil, under.from)}’s: " <> Model.one_line(under.entry.body)}
        ]
      end)

    [
      {%Paragraph{
         text: View.frame_rows(lines ++ replaced, width, 0, max(rect.height - 2, 1)),
         wrap: false,
         block: %Block{
           title: " #{row.entry.topic || "(no topic)"} · #{title(nil, row.from)} — Esc back ",
           borders: [:all]
         }
       }, rect}
    ]
  end

  defp body(%{mode: {:box, box}} = page, rect) do
    [
      {%Paragraph{
         text: box.draft <> "▏",
         wrap: true,
         block: %Block{
           title: " #{box.topic} — #{save_line(page)} ",
           borders: [:all],
           border_type: :double
         }
       }, rect}
    ]
  end

  defp body(%{mode: {:status, lines}}, rect),
    do: [
      {%Paragraph{
         text: Enum.join(lines, "\n"),
         wrap: true,
         block: %Block{title: " where this machine's copy stands — Esc back ", borders: [:all]}
       }, rect}
    ]

  defp body(%{mode: {:blame, lines}}, rect) do
    labels = Enum.map(lines, &Client.written_by/1)
    width = labels |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> min(40)

    items =
      Enum.zip_with(labels, lines, fn label, line ->
        Line.new([
          Span.new(String.pad_trailing(label, width) <> "  ", style: Theme.style(:muted)),
          Span.new(line["text"] || "")
        ])
      end)

    [
      {%List{
         items: items,
         block: %Block{title: " who wrote each line — b or Esc back ", borders: [:all]}
       }, rect}
    ]
  end

  defp body(%{mode: {:conflict, c}}, rect) do
    [left, right] = Layout.split(rect, :horizontal, [{:fill, 1}, {:fill, 1}])

    [
      {%Paragraph{
         text: c.mine,
         wrap: true,
         block: %Block{
           title: " yours, not saved ",
           borders: [:all],
           border_style: Theme.style(:needs_you)
         }
       }, left},
      {%Paragraph{
         text: c.theirs["text"] || "",
         wrap: true,
         block: %Block{
           title:
             " version #{c.theirs["version"]}, saved since#{by_when(c.theirs["changed_by"], c.theirs["changed_at"])} — l reloads it ",
           borders: [:all]
         }
       }, right}
    ]
  end

  defp body(%{mode: {:history, %{compare: %{} = compare} = h}}, rect) do
    [left, right] = Layout.split(rect, :horizontal, [{:fill, 1}, {:fill, 1}])

    for {{n, text}, r} <- [{compare.older, left}, {compare.newer, right}] do
      version = Enum.find(h.versions, &(&1["version"] == n)) || %{}

      {%Paragraph{
         text: text,
         wrap: true,
         block: %Block{
           title: " version #{n}#{by_when(version["changed_by"], version["changed_at"])} ",
           borders: [:all]
         }
       }, r}
    end
  end

  defp body(%{mode: {:history, h}} = page, rect) do
    current = own(page).version

    items =
      h.versions
      |> Enum.with_index()
      |> Enum.map(fn {version, i} ->
        mark = if h.mark == i, do: "◆ ", else: "  "
        now = if version["version"] == current, do: " · in force", else: ""

        "#{mark}v#{version["version"]}#{by_when(version["changed_by"], version["changed_at"])} · #{version["bytes"]} bytes#{now}"
      end)

    [
      {%List{
         items: if(items == [], do: ["(no versions yet)"], else: items),
         selected: if(items == [], do: nil, else: h.cursor),
         highlight_symbol: "▸ ",
         highlight_style: Theme.style(:accent, [:bold]),
         block: %Block{title: " versions of your memory ", borders: [:all]}
       }, rect}
    ]
  end

  defp body(page, rect) do
    rows = rows(page)

    items =
      case rows do
        [] -> [empty(page)]
        rows -> Enum.flat_map(rows, &row_lines(page, &1, rect.width))
      end

    selected = if rows == [], do: nil, else: row_index(page, rows)

    [
      {%List{
         items: items,
         selected: selected,
         highlight_symbol: "▸ ",
         highlight_style: Theme.style(:accent, [:bold]),
         block: %Block{title: " #{tab_title(page)} ", borders: [:all], border_type: :double}
       }, rect}
    ]
  end

  # In effect, a topic takes a line and one more per entry it replaces.
  defp row_index(%{tab: 0} = page, rows),
    do: rows |> Enum.take(page.cursor) |> Enum.map(&(1 + length(&1.replaces))) |> Enum.sum()

  defp row_index(page, _rows), do: page.cursor

  defp tab_title(%{tab: 0} = page), do: "in effect for you in #{team_name(page)}"
  defp tab_title(page), do: title(page, level(page))

  defp empty(%{tab: 0}), do: "Nothing in effect: no level has a memory yet."

  defp empty(page) do
    case level(page) do
      %{scope: "user"} ->
        "Nothing personal yet. a adds how you like to work: the length of answers, the language, what to skip."

      %{scope: "organisation"} ->
        "No memory for everyone yet."

      %{name: name} ->
        "#{name} has no memory of its own; its sessions use the organisation's as it is."
    end
  end

  defp row_lines(page, row, width) do
    topic = row.entry.topic || "(no topic)"

    first =
      row.entry.body
      |> String.split("\n")
      |> Enum.find("", &(String.trim(&1) != ""))
      |> Model.one_line()

    from = if page.tab == 0, do: " · from #{title(page, row.from)}", else: ""
    # Who last changed the entry and when, as the plane read it off the blame, at every level.
    meta =
      if row.entry[:by] || row.entry[:at],
        do: by_when(row.entry[:by], row.entry[:at]) <> used(row.entry[:used]),
        else: by_when(row.from.changed_by, row.from.changed_at)
    room = max(width - String.length(topic) - String.length(from) - String.length(meta) - 10, 10)
    first = if String.length(first) > room, do: String.slice(first, 0, room - 1) <> "…", else: first

    [
      Line.new([
        Span.new(topic, style: Theme.style(nil, [:bold])),
        Span.new(from, style: Theme.style(:muted)),
        Span.new("  " <> first),
        Span.new("  " <> String.trim_leading(meta, " · "), style: Theme.style(:muted))
      ])
    ] ++
      Enum.map(row.replaces, fn under ->
        Line.new([
          Span.new("    replaces #{title(page, under.from)}’s", style: Theme.style(:muted))
        ])
      end)
  end

  defp used(n) when is_integer(n), do: " · used in #{n} session#{if n == 1, do: "", else: "s"}"
  defp used(_none), do: ""

  defp by_when(by, at) do
    parts = Enum.reject([by, at && ArtifactsPage.ago(at)], &(&1 in [nil, ""]))
    if parts == [], do: "", else: " · " <> Enum.join(parts, " · ")
  end

  defp save_line(_page), do: "saves to Only you · your new sessions in any team · Ctrl-S"

  defp status_text(%{mode: {:topic, t}} = page),
    do: "topic: #{t}▏   #{save_line(page)}" <> if(page.status, do: "\n" <> page.status, else: "")

  defp status_text(%{mode: {:forget, row}}),
    do:
      "Forget “#{row.entry.topic}”? New sessions stop starting with it. Sessions already running keep it until they sleep. y forgets · n keeps it"

  defp status_text(%{mode: {:conflict, c}}),
    do:
      "Not saved: your memory was saved somewhere else since, version #{c.theirs["version"]}. Both are here; l reloads it."

  defp status_text(%{status: status}) when is_binary(status), do: status
  defp status_text(_page), do: ""
end
