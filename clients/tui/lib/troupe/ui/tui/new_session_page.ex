defmodule Troupe.UI.TUI.NewSessionPage do
  @moduledoc """
  `/new`'s screen: a session starts from a message.

  The message box comes first. Under it the settings read as one sentence, "Runs on the
  platform with dev as build · everyone on core can open it", whose bracketed words are
  chips: Tab moves to them, ←→ between them, Enter opens the picker under the sentence
  (where it runs, the folder, the profile with its room, the agent), ↑↓ and Enter pick,
  Esc closes. A line under the sentence says why the profile was picked. `@profile`,
  `#agent`, `/local` and `/platform` typed in the box set the chips and are taken out
  before the agent reads it (`Troupe.UI.NewSession`): in this box `@name` naming a profile
  is a token, not a path to complete, and `/local` is a token, since the box is not the
  command line. CALLED is the first line until it is edited (Tab again).

  Enter starts, as Enter sends on the command line; Shift, Alt or Ctrl on Enter is a new
  line, as it is there. Ctrl+Enter is not told from Enter by most terminals, which is why
  the screen does not depend on it. On an empty box a digit starts like last time: that
  recent session's where, folder, profile and agent, the box left alone.

  The page is a fold over keypresses, as HQ is; the server owns the process, starts the
  session in a task and draws the casting steps from what the task tells it.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.NewSession
  alias Troupe.UI.TUI.{Input, Theme}

  @quips [
    "The stage is set. Give them the plot and step into the wings.",
    "No auditions today. Everyone already knows their lines.",
    "Break a leg. Or a build. Preferably not production.",
    "Every good run starts with a cue line.",
    "The house lights are down. What's the scene?"
  ]

  @typedoc "The screen's state: a plain map, as HQ's is."
  @type t :: map()

  @doc """
  The screen, its chips pre-set by `opts`: `:where` (`:local` or `:platform`), `:profile`,
  `:agent` (one the person picked), `:private`, `:team`; `:workspace` is the folder a
  session here starts in, and `:origin` the plane, where there is one, or else `:plane_why`
  why there is none. `:local_agent` is the agent a session on this computer starts as when
  none is picked, the one on screen: it is this computer's, and never sent to the plane,
  whose profile has a default of its own.
  """
  @spec open(keyword()) :: t()
  def open(opts) do
    origin = Keyword.get(opts, :origin)
    workspace = Keyword.fetch!(opts, :workspace)
    {profiles, sessions, plane_error} = plane_rows(origin)
    agents = local_agents(workspace)

    %{
      origin: origin,
      text: {"", 0},
      title: nil,
      field: :message,
      chip: 0,
      open: nil,
      cursor: 0,
      where: Keyword.get(opts, :where),
      profile: Keyword.get(opts, :profile),
      agent: Keyword.get(opts, :agent),
      local_agent: Keyword.get(opts, :local_agent),
      plane_why: Keyword.get(opts, :plane_why),
      plane_error: plane_error,
      # A sentence a key just earned, such as why the agent chip has nothing to pick; the
      # next key takes it away.
      said: nil,
      private: Keyword.get(opts, :private, false),
      # The team HQ had selected, which the plane charges and opens the session to.
      team: Keyword.get(opts, :team),
      folder: workspace,
      folders: recent_folders(workspace),
      profiles: profiles,
      local_agents: agents,
      recents: recents(sessions, workspace),
      last_used: last_used(sessions),
      daemon_up: Keyword.get_lazy(opts, :daemon_up, &Client.daemon_up?/0),
      ceiling: %{},
      quip: Enum.random(@quips),
      casting: nil
    }
  end

  # The plane's profiles and sessions, and the error the profile listing answered: an
  # expired sign-in or a plane that is down is said as itself, not as having no profile.
  # The sessions only give the recents and the last used, so without them nothing on the
  # page is untrue; a plane that refuses the one refuses the other alike.
  defp plane_rows(nil), do: {[], [], nil}

  defp plane_rows(origin) do
    {profiles, error} = rows_or_error(Client.profile_rows(origin))
    {sessions, _error} = rows_or_error(Client.plane_session_rows(origin))
    {profiles, sessions, error}
  end

  defp rows_or_error({:ok, rows}), do: {rows, nil}
  defp rows_or_error({:error, reason}), do: {[], reason}

  defp local_agents(workspace) do
    case Client.profiles({:local, workspace}) do
      {:ok, agents} -> Enum.map(agents, & &1.name)
      {:error, _} -> []
    end
  end

  defp recent_folders(workspace) do
    case Client.sessions({:local, workspace}) do
      {:ok, rows} ->
        rows |> Enum.map(& &1.workspace) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.take(5)

      {:error, _} ->
        []
    end
    |> then(&Enum.uniq([workspace | &1]))
  end

  # The newest sessions on the plane and here, not a branch: up to three to start like.
  defp recents(plane_rows, workspace) do
    remote =
      for row <- plane_rows, is_binary(row["profile"]) do
        %{
          title: row["title"] || row["id"],
          where: :platform,
          folder: nil,
          profile: row["profile"],
          agent: row["agent"],
          at: to_string(row["last_active_at"])
        }
      end

    local =
      case Client.sessions({:local, workspace}) do
        {:ok, rows} ->
          for row <- rows, row.parent == nil do
            %{
              title: row.title || row.workspace,
              where: :local,
              folder: row.workspace,
              profile: nil,
              agent: row.profile,
              at: to_string(row.updated_at)
            }
          end

        {:error, _} ->
          []
      end

    (remote ++ local) |> Enum.sort_by(& &1.at, :desc) |> Enum.take(3)
  end

  defp last_used(rows) do
    rows
    |> Enum.filter(&is_binary(&1["profile"]))
    |> Enum.max_by(&to_string(&1["last_active_at"]), fn -> %{} end)
    |> Map.get("profile")
  end

  ## What the chips resolve to

  @doc "What the screen would start now: where, the profile and its room, the agent, the line under the sentence."
  @spec resolved(t()) :: map()
  def resolved(page) do
    {text, _pos} = page.text
    {auto, auto_why} = NewSession.auto_pick(page.profiles, page.last_used)
    pre = Enum.find(page.profiles, &(&1["name"] == (page.profile || auto)))

    names = %{
      profiles: Enum.map(page.profiles, & &1["name"]),
      agents: Enum.uniq(page.local_agents ++ agents_of(pre))
    }

    tokens = NewSession.tokens(text, names)
    where = where_of(page, tokens)
    name = tokens[:profile] || page.profile || auto
    profile = Enum.find(page.profiles, &(&1["name"] == name))
    room = profile && NewSession.room(profile)
    full = where == :platform and room != nil and room.full

    at_ceiling =
      where == :platform and profile != nil and
        (room.at_ceiling or Map.has_key?(page.ceiling, name))

    offered = agents_of(profile)

    default_agent =
      if where == :local,
        do: page.local_agent || List.first(page.local_agents, "build"),
        else: default_of(profile)

    # On the platform an agent counts as picked only where the profile offers it: one
    # picked here, or a recent's, does not follow the session onto a profile without it.
    named_agent =
      tokens[:agent] ||
        if(where == :local or page.agent in offered, do: page.agent)

    cleaned = NewSession.clean(text, names)
    local_down = where == :local and not page.daemon_up
    no_plane = page.origin == nil and page.where == :platform
    not_allowed = where == :platform and profile == nil and name != nil and page.profiles != []

    why =
      cond do
        page.said ->
          {:warn, page.said}

        local_down ->
          {:warn, NewSession.local_down()}

        no_plane ->
          {:warn, NewSession.no_plane(page.plane_why, page.profile)}

        where == :platform and page.plane_error != nil ->
          {:warn, NewSession.plane_error(page.plane_error)}

        not_allowed ->
          {:warn, NewSession.not_allowed(name)}

        at_ceiling ->
          {:warn, page.ceiling[name] || NewSession.ceiling(name, room.max_sessions || 0)}

        full ->
          {:warn, NewSession.full_house(name, room.capacity)}

        sentence = NewSession.tokens_sentence(tokens) ->
          {:plain, sentence}

        where == :platform and page.profile == nil ->
          {:plain, auto_why}

        true ->
          nil
      end

    %{
      where: where,
      names: names,
      tokens: tokens,
      profile: profile,
      profile_name: name,
      full: full,
      at_ceiling: at_ceiling,
      agent: named_agent || default_agent || "its default",
      # The chip's word: on the platform an agent nobody picked is the profile's default.
      agent_label:
        cond do
          named_agent -> named_agent
          where == :platform and default_agent != nil -> default_agent <> " (default)"
          true -> default_agent || "its default"
        end,
      named_agent: named_agent,
      # What the create names. On the platform only an agent the person picked: with none
      # the plane fills the profile's own default, by the rule the chip shows. On this
      # computer the one on screen, as `/new` always started.
      sent_agent: if(where == :platform, do: named_agent, else: named_agent || page.local_agent),
      cleaned: cleaned,
      title: title_of(page, cleaned),
      local_down: local_down,
      why: why,
      who: NewSession.who(where, profile && profile["teams"], page.private),
      blocked: if(where == :local, do: local_down, else: profile == nil or at_ceiling)
    }
  end

  # A token wins over the chip; `@profile` alone without `/local` means the platform, where
  # there is one; else the chip, else this computer as `/new` always started.
  defp where_of(%{origin: nil}, _tokens), do: :local

  defp where_of(page, tokens) do
    tokens[:where] || if(tokens[:profile], do: :platform) || page.where || :local
  end

  defp agents_of(nil), do: []

  defp agents_of(row),
    do:
      row["agents"] |> List.wrap() |> Enum.map(&if(is_map(&1), do: &1["name"], else: to_string(&1)))

  # The profile's default, which the chip shows and the plane fills when the create names
  # none, by the same rule. Where the profile offers none the plane says why.
  defp default_of(row), do: row |> agents_of() |> NewSession.default_agent()

  defp title_of(%{title: {title, _pos}}, _cleaned), do: title
  defp title_of(_page, cleaned), do: NewSession.title(cleaned)

  ## Keys

  @doc """
  A key: `{:ok, page}`; `:close`; `{:start, page, origin, params}` to start it; or
  `{:choose_agent, page}`, where the agent on this computer is chosen in the one agent
  picker (`Troupe.UI.TUI.AgentChooser`).
  """
  @spec key(t(), map()) ::
          {:ok, t()} | :close | {:start, t(), Client.origin(), map()} | {:choose_agent, t()}
  def key(page, key), do: step(%{page | said: nil}, key)

  defp step(%{casting: %{failed: failed}} = page, %{code: code})
       when is_binary(failed) and code in ["esc", "enter"],
       do: {:ok, %{page | casting: nil}}

  defp step(%{casting: %{}} = page, %{code: "esc"}), do: {:ok, %{page | casting: nil}}
  defp step(%{casting: %{}} = page, _key), do: {:ok, page}

  defp step(%{open: open} = page, %{code: "esc"}) when open != nil, do: {:ok, %{page | open: nil}}
  defp step(_page, %{code: "esc"}), do: :close

  defp step(%{open: open} = page, %{code: code}) when open != nil and code in ["up", "k"],
    do: {:ok, %{page | cursor: max(page.cursor - 1, 0)}}

  defp step(%{open: open} = page, %{code: code}) when open != nil and code in ["down", "j"],
    do: {:ok, %{page | cursor: min(page.cursor + 1, max(length(options(page)) - 1, 0))}}

  defp step(%{open: open} = page, %{code: "enter"}) when open != nil, do: pick(page)

  defp step(page, %{code: "tab"}), do: {:ok, next_field(page, 1)}
  defp step(page, %{code: "backtab"}), do: {:ok, next_field(page, -1)}

  defp step(%{field: :chips} = page, %{code: code}) when code in ["left", "h"],
    do: {:ok, %{page | chip: max(page.chip - 1, 0)}}

  defp step(%{field: :chips} = page, %{code: code}) when code in ["right", "l"],
    do: {:ok, %{page | chip: min(page.chip + 1, 2)}}

  defp step(%{field: :chips} = page, %{code: "enter"}), do: open_chip(page)

  defp step(%{field: :chips} = page, %{code: <<d>>}) when d in ?1..?3, do: {:ok, like(page, d - ?0)}

  defp step(%{field: :message, text: {"", _}} = page, %{code: <<d>>, modifiers: []})
       when d in ?1..?3,
       do: {:ok, like(page, d - ?0)}

  defp step(%{field: field} = page, %{code: "enter", modifiers: mods})
       when field != :chips and mods != [],
       do: {:ok, edit(page, field, &Input.insert(&1, "\n"))}

  defp step(%{field: field} = page, %{code: "enter"}) when field != :chips, do: start(page)

  defp step(%{field: field} = page, %{code: code, modifiers: mods} = key) when field != :chips do
    if String.length(code) == 1 and mods in [[], ["shift"]] do
      {:ok, edit(page, field, &Input.insert(&1, code))}
    else
      case Input.key(key, input_of(page, field)) do
        {:ok, input} -> {:ok, edit(page, field, fn _ -> input end)}
        :pass -> {:ok, page}
      end
    end
  end

  defp step(page, _key), do: {:ok, page}

  @doc "Pasted text, into the box being typed in."
  @spec paste(t(), String.t()) :: t()
  def paste(%{field: :chips} = page, _text), do: page
  def paste(page, text), do: edit(page, page.field, &Input.insert(&1, text))

  defp input_of(page, :message), do: page.text
  defp input_of(page, :title), do: page.title || {title_of(page, resolved(page).cleaned), 0}

  defp edit(page, :message, fun), do: %{page | text: fun.(page.text)}

  defp edit(page, :title, fun) do
    {text, _} = input = input_of(page, :title)
    current = if page.title, do: input, else: {text, String.length(text)}
    %{page | title: fun.(current)}
  end

  @fields [:message, :chips, :title]

  defp next_field(page, step) do
    i = Enum.find_index(@fields, &(&1 == page.field))
    %{page | field: Enum.at(@fields, rem(i + step + 3, 3)), open: nil}
  end

  defp chips(page) do
    if resolved(page).where == :local,
      do: [:where, :folder, :agent],
      else: [:where, :profile, :agent]
  end

  # The agent chip with nothing to pick says why instead of opening an empty picker.
  defp open_chip(page) do
    case Enum.at(chips(page), page.chip) do
      :agent ->
        r = resolved(page)

        cond do
          r.where == :local and page.daemon_up ->
            {:choose_agent, page}

          options(%{page | open: :agent}) == [] ->
            {:ok, %{page | said: NewSession.no_agents(r.where, r.profile_name, page.daemon_up)}}

          true ->
            {:ok, %{page | open: :agent, cursor: 0}}
        end

      kind ->
        {:ok, %{page | open: kind, cursor: 0}}
    end
  end

  @doc """
  The daemon link came up or went down: "On this computer" switches on or off by itself,
  and coming up, the agents this computer has are read again (`agents`, or `nil` to keep
  them).
  """
  @spec daemon(t(), boolean(), [String.t()] | nil) :: t()
  def daemon(page, up?, agents \\ nil) do
    page = %{page | daemon_up: up?}
    if up? and is_list(agents), do: %{page | local_agents: agents}, else: page
  end

  @doc "The options the open picker lists: `{value, label, detail, enabled}`."
  @spec options(t()) :: [{term(), String.t(), String.t(), boolean()}]
  def options(%{open: :where} = page) do
    platform =
      if page.origin,
        do: [
          {:platform, "On the platform", "keeps running when you close this; your team can open it",
           true}
        ],
        else: []

    here =
      if page.daemon_up,
        do: {:local, "On this computer", "your own checkout and files", true},
        else: {:local, "On this computer", "DAEMON NOT RUNNING: " <> NewSession.local_down(), false}

    platform ++ [here]
  end

  def options(%{open: :folder} = page), do: Enum.map(page.folders, &{&1, &1, "", true})

  def options(%{open: :profile} = page) do
    for row <- page.profiles do
      room = NewSession.room(row)

      tag =
        cond do
          room.at_ceiling -> "AT ITS LIMIT"
          room.full -> "FULL"
          room.idle -> "idle"
          true -> "#{room.free} of #{room.capacity} free"
        end

      {row["name"], row["name"], tag, true}
    end
  end

  def options(%{open: :agent} = page) do
    # This computer's agents are picked in the agent picker, never from a profile's list.
    r = resolved(page)
    profile = if r.where == :platform, do: r.profile
    default = default_of(profile)

    for name <- agents_of(profile),
        do: {name, name, if(name == default, do: "its default", else: ""), true}
  end

  def options(_page), do: []

  # A chip's option picked: it holds, and the token of its kind leaves the message.
  defp pick(page) do
    case Enum.at(options(page), page.cursor) do
      {_value, _label, _detail, false} ->
        {:ok, page}

      {value, _label, _detail, true} ->
        {kind, page} =
          case page.open do
            :where -> {:where, %{page | where: value}}
            :folder -> {nil, %{page | folder: value}}
            :profile -> {:profile, %{page | profile: value}}
            :agent -> {:agent, %{page | agent: value}}
          end

        {:ok, %{strip(page, kind) | open: nil}}

      nil ->
        {:ok, %{page | open: nil}}
    end
  end

  @doc "The agent chosen in the agent picker, as a chip pick."
  @spec chose_agent(t(), String.t()) :: t()
  def chose_agent(page, name), do: strip(%{page | agent: name, open: nil}, :agent)

  defp strip(page, nil), do: page

  defp strip(page, kind) do
    {text, pos} = page.text
    stripped = NewSession.strip_kinds(text, [kind], resolved(page).names)
    %{page | text: {stripped, Input.clamp(stripped, pos)}}
  end

  # Start like last time: that session's where, folder, profile and agent; the box stays.
  defp like(page, n) do
    case Enum.at(page.recents, n - 1) do
      nil ->
        page

      recent ->
        page =
          if recent.where == :local and not page.daemon_up,
            do: page,
            else: %{page | where: recent.where}

        page = if recent.folder, do: %{page | folder: recent.folder}, else: page
        page = if recent.profile, do: %{page | profile: recent.profile}, else: page
        if recent.agent, do: %{page | agent: recent.agent}, else: page
    end
  end

  defp start(page) do
    r = resolved(page)

    if r.blocked do
      {:ok, page}
    else
      casting = %{
        title: if(r.title == "", do: "Untitled session", else: r.title),
        where: r.where,
        folder: page.folder,
        profile: r.profile_name,
        agent: r.agent,
        named_agent: r.sent_agent,
        has_text: r.cleaned != "",
        queued: r.full,
        done: 0,
        waiting: false,
        failed: nil
      }

      page = %{page | casting: casting, open: nil}
      title = if r.title == "", do: nil, else: r.title

      case r.where do
        :local ->
          {:start, page, {:local, page.folder},
           %{
             profile: r.sent_agent,
             prompt: r.cleaned,
             title: title,
             worktree: "never",
             private: page.private
           }}

        :platform ->
          {:start, page, page.origin,
           %{
             profile: r.profile_name,
             agent: r.sent_agent,
             prompt: r.cleaned,
             title: title,
             team: page.team
           }}
      end
    end
  end

  ## What the server tells it

  @doc "The plane says the session waits for a place."
  @spec waiting(t()) :: t()
  def waiting(%{casting: %{} = c} = page),
    do: %{page | casting: %{c | done: 1, queued: true, waiting: true}}

  def waiting(page), do: page

  @doc "The create failed: why, in one line, and the form is offered back."
  @spec failed(t(), String.t()) :: t()
  def failed(%{casting: %{} = c} = page, why) do
    ceiling = if why =~ "at once", do: Map.put(page.ceiling, c.profile, why), else: page.ceiling
    %{page | casting: %{c | failed: why, waiting: false}, ceiling: ceiling}
  end

  def failed(page, _why), do: page

  @doc "The casting steps, as the curtain line says them: `{word, line}` each."
  @spec steps(map()) :: [{String.t(), String.t()}]
  def steps(c) do
    lines = [
      if(c.where == :local,
        do: "Opening #{c.folder} on this computer",
        else: "Finding a machine on the platform"
      ),
      if(c.queued,
        do: "Waiting for a free place in #{c.profile}",
        else: "Setting up #{if c.where == :local, do: c.agent, else: "#{c.profile} as #{c.agent}"}"
      ),
      if(c.has_text, do: "Handing over your instruction", else: "Ready for your first message")
    ]

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      word =
        cond do
          i < c.done -> "done"
          i == c.done and c.failed == nil -> if(c.waiting and i == 1, do: "waiting", else: "now")
          true -> "next"
        end

      {word, line}
    end)
  end

  ## Drawing

  @doc "The line under the page that says what the keys do."
  @spec footer(t()) :: String.t()
  def footer(%{casting: %{failed: f}}) when is_binary(f),
    do: " casting — Enter or Esc back to the form "

  def footer(%{casting: %{}}),
    do: " casting — Esc stops waiting; the session starts by itself when a place frees "

  def footer(%{open: open}) when open != nil, do: " ↑↓ move · Enter picks · Esc closes "

  def footer(_page),
    do:
      " Enter starts · Shift/Alt+Enter new line · Tab the settings, then ←→ and Enter · 1-3 like last time · Esc closes "

  @spec render(t(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(page, rect, _state) do
    [{%Paragraph{text: lines(page, rect.width - 2), wrap: true, block: block(page)}, rect}]
  end

  defp block(%{casting: %{}}), do: %Block{title: " casting ", borders: [:all], border_type: :double}

  defp block(_page),
    do: %Block{title: " new session · act I ", borders: [:all], border_type: :double}

  @doc "The page's lines as plain text, for a test and a screen reader alike."
  @spec plain(t(), pos_integer()) :: String.t()
  def plain(page, width \\ 100) do
    page
    |> lines(width)
    |> Enum.map_join("\n", fn %Line{spans: spans} -> Enum.map_join(spans, & &1.content) end)
  end

  defp lines(%{casting: %{} = c} = page, _width) do
    head = [Line.new([Span.new(c.title, style: Theme.style(nil, [:bold]))]), Line.new([])]

    steps =
      for {word, line} <- steps(c) do
        style = if word == "next", do: Theme.style(:muted), else: Theme.style(nil)

        Line.new([
          Span.new("  #{String.pad_trailing(word, 8)}", style: Theme.style(:working)),
          Span.new(line, style: style)
        ])
      end

    tail =
      if c.failed,
        do: [
          Line.new([]),
          Line.new([Span.new("▲ Could not start: " <> c.failed, style: Theme.style(:error))])
        ],
        else: [Line.new([]), Line.new([Span.new(page.quip, style: Theme.style(:muted, [:italic]))])]

    head ++ steps ++ tail
  end

  defp lines(page, _width) do
    r = resolved(page)

    [
      Line.new([Span.new("What should the troupe do?", style: Theme.style(nil, [:bold]))]),
      Line.new([Span.new(page.quip, style: Theme.style(:muted, [:italic]))]),
      Line.new([])
    ] ++
      message_lines(page) ++
      [Line.new([]), sentence(page, r)] ++
      why_line(r) ++
      picker_lines(page) ++
      [Line.new([]), called(page, r), hint()] ++ recent_lines(page)
  end

  defp message_lines(page) do
    {text, pos} = page.text
    focused = page.field == :message

    shown =
      cond do
        text == "" and not focused ->
          "Rewrite the placement loop so it tries corners first. Add @dev or #plan to change how it starts."

        focused ->
          elem(Input.insert({text, pos}, Input.cursor_glyph()), 0)

        true ->
          text
      end

    style = if text == "", do: Theme.style(:muted), else: Theme.style(nil)
    marker = if focused, do: Theme.style(:accent, [:bold]), else: Theme.style(:rail)

    shown
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new("▌ ", style: marker), Span.new(&1, style: style)]))
  end

  defp sentence(page, r) do
    chip = fn i, word, tone ->
      selected = page.field == :chips and page.chip == i
      style = Theme.style(tone, if(selected, do: [:bold, :reversed], else: [:bold]))
      Span.new("[#{word}]", style: style)
    end

    {middle_word, middle} =
      if r.where == :local,
        do: {" in ", chip.(1, page.folder, nil)},
        else:
          {" with ",
           chip.(1, r.profile_name || "no profile", if(r.full or r.at_ceiling, do: :stale))}

    Line.new([
      Span.new("Runs "),
      chip.(
        0,
        if(r.where == :local, do: "on this computer", else: "on the platform"),
        if(r.where == :local, do: nil, else: :working)
      ),
      Span.new(middle_word),
      middle,
      Span.new(" as "),
      chip.(2, r.agent_label, nil),
      Span.new(" · " <> r.who)
    ])
  end

  defp why_line(%{why: nil}), do: []

  defp why_line(%{why: {:warn, text}}),
    do: [Line.new([Span.new("▲ " <> text, style: Theme.style(:stale))])]

  defp why_line(%{why: {:plain, text}}),
    do: [Line.new([Span.new(text, style: Theme.style(:muted))])]

  defp picker_lines(%{open: nil}), do: []

  defp picker_lines(page) do
    title = %{
      where: "WHERE IT RUNS  /local · /platform",
      folder: "WHICH FOLDER  recent",
      profile: "WHAT IT CAN REACH  @profile",
      agent: "HOW IT STARTS  #agent"
    }

    rows =
      page
      |> options()
      |> Enum.with_index()
      |> Enum.map(fn {{_value, label, detail, enabled}, i} ->
        mark = if i == page.cursor, do: "▸ ", else: "  "

        tag_style =
          if detail in ["FULL", "AT ITS LIMIT"],
            do: Theme.style(:stale, [:bold]),
            else: Theme.style(:muted)

        label_style = if enabled, do: Theme.style(nil, [:bold]), else: Theme.style(:muted, [:dim])

        Line.new([
          Span.new(mark, style: Theme.style(:accent)),
          Span.new(label, style: label_style),
          Span.new("  " <> detail, style: tag_style)
        ])
      end)

    [
      Line.new([]),
      Line.new([Span.new("// " <> title[page.open], style: Theme.style(:working))]) | rows
    ]
  end

  defp called(page, r) do
    text =
      if page.field == :title,
        do: elem(Input.insert(input_of(page, :title), Input.cursor_glyph()), 0),
        else: r.title

    style = if page.field == :title, do: Theme.style(:accent, [:bold]), else: Theme.style(:muted)

    Line.new([
      Span.new("CALLED ", style: style),
      Span.new(if(text == "", do: "named from your first line", else: text))
    ])
  end

  defp hint do
    Line.new([
      Span.new(
        "Type @profile, #agent or /local in the message to change these; they're removed before the troupe reads it.",
        style: Theme.style(:muted)
      )
    ])
  end

  defp recent_lines(%{recents: []}), do: []

  defp recent_lines(page) do
    rows =
      page.recents
      |> Enum.with_index(1)
      |> Enum.map(fn {r, n} ->
        facts = [
          if(r.where == :local, do: "THIS COMPUTER", else: "PLATFORM"),
          r.folder || r.profile,
          r.agent || "its default"
        ]

        Line.new([
          Span.new("  #{n} ", style: Theme.style(:accent, [:bold])),
          Span.new(r.title <> "  "),
          Span.new(Enum.join(facts, " · "), style: Theme.style(:muted))
        ])
      end)

    [
      Line.new([]),
      Line.new([Span.new("// START LIKE LAST TIME", style: Theme.style(:working))]) | rows
    ]
  end
end
