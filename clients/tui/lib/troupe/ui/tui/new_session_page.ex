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

  Where more than one of the person's teams may use the profile, the sentence ends
  "everyone on [team] can open it" and the team is a fourth chip: the one this machine
  remembers for the profile (`Troupe.Client.TeamChoice`), else "which team?", and Enter
  then opens its picker first, whose pick starts. The plane's own "choose a team" refusal
  opens the same question on the names it gave (`choose_team/2`).

  Enter starts, as Enter sends on the command line; Ctrl-J is a new line, as it is there,
  and so is Shift, Alt or Ctrl on Enter where the terminal tells them from Enter. Without
  a keyboard protocol most do not (Windows Terminal sends Shift+Enter as Enter and keeps
  Alt+Enter for full screen), so the footer names Ctrl-J alone. A typed character always
  types: "start like last time" is the recents row, which Tab reaches after CALLED, where
  ↑↓ and Enter or `1`-`3` set the chips to that session's where, folder, profile and agent,
  the box left alone, and the line under the sentence says so.

  The page is taller than a small terminal: it is folded to the width and drawn from the
  row that keeps what has the focus on screen (the box's cursor, the picker's cursor).

  The page is a fold over keypresses, as HQ is; the server owns the process, starts the
  session in a task and draws the casting steps from what the task tells it. Esc on the
  casting steps goes back to the form and the start goes on: the form says it is starting,
  and Enter there starts nothing a second time.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.{Lines, NewSession}
  alias Troupe.UI.TUI.{Input, Model, Theme}

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
    seed = Keyword.get_lazy(opts, :seed, fn -> System.os_time(:millisecond) end)

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
      # `/new --only-me`: on the platform, its owner's and the people they invite until it
      # is shared, on the team's profile and budget all the same.
      only_me: Keyword.get(opts, :only_me, false),
      # The team HQ had selected, which the plane charges and opens the session to.
      team: Keyword.get(opts, :team),
      # Where more than one of the person's teams may use a profile: the team picked for
      # each profile here, the one this machine remembers for it, the teams a refusal named
      # for one since the listing was read, and whether a pick starts (Enter asked first).
      team_picks: %{},
      remembered: Keyword.get_lazy(opts, :remembered, fn -> remembered(origin) end),
      teams_asked: %{},
      start_on_team: false,
      folder: workspace,
      folders: recent_folders(workspace),
      profiles: profiles,
      local_agents: agents,
      recents: recents(sessions, workspace),
      last_used: last_used(sessions),
      daemon_up: Keyword.get_lazy(opts, :daemon_up, &Client.daemon_up?/0),
      ceiling: %{},
      seed: seed,
      quip: Lines.first(:start_screen, seed),
      casting: nil,
      # The start left running when Esc went back to the form: its casting, until the
      # server says it finished.
      pending: Keyword.get(opts, :pending),
      # The recent the chips were last set like, said under the sentence until a chip is
      # picked by hand; and the recent the recents row has selected.
      liked: nil,
      recent: 0
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

  defp remembered(origin), do: Client.remembered_teams(origin)

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

    # The chip's word: on the platform an agent nobody picked is the profile's default.
    agent_label =
      cond do
        named_agent -> named_agent
        where == :platform and default_agent != nil -> default_agent <> " (default)"
        true -> default_agent || "its default"
      end

    # Whose session it is, where more than one of the person's teams may use the profile:
    # the listing's teams, or the ones the plane's refusal named since, which are newer. A
    # chip on the sentence only then; with one team the plane takes it and nothing shows.
    candidates =
      if where == :platform and profile != nil,
        do: page.teams_asked[name] || List.wrap(profile["teams"]),
        else: []

    team_choice = length(candidates) > 1

    team =
      NewSession.chosen_team(
        candidates,
        page.team_picks[name] || page.team,
        page.remembered[name]
      )

    cleaned = NewSession.clean(text, names)
    local_down = where == :local and not page.daemon_up
    no_plane = page.origin == nil and page.where == :platform
    not_allowed = where == :platform and profile == nil and name != nil and page.profiles != []

    why =
      cond do
        page.said ->
          {:warn, page.said}

        page.pending ->
          {:plain, starting(page.pending)}

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

        team_choice and team == nil ->
          {:plain, NewSession.team_question(name, candidates)}

        sentence = NewSession.tokens_sentence(tokens) ->
          {:plain, sentence}

        # What the chips hold now, which is not always what the recent had.
        page.liked ->
          on = if where == :local, do: page.folder, else: name
          {:plain, "Like #{page.liked}: #{on}, #{agent_label}."}

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
      agent_label: agent_label,
      named_agent: named_agent,
      # What the create names. On the platform only an agent the person picked: with none
      # the plane fills the profile's own default, by the rule the chip shows. On this
      # computer the one on screen, as `/new` always started.
      sent_agent: if(where == :platform, do: named_agent, else: named_agent || page.local_agent),
      cleaned: cleaned,
      title: title_of(page, cleaned),
      local_down: local_down,
      why: why,
      who:
        NewSession.who(where, if(team, do: [team], else: profile && profile["teams"]), page.only_me),
      only_me: where == :platform and page.only_me,
      team_candidates: candidates,
      team_choice: team_choice,
      team: team,
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

  # The start Esc left running, as the form says it.
  defp starting(%{} = c) do
    on = if c.where == :local, do: "this computer", else: c.profile
    wait = if c.waiting, do: " Waiting for a free place.", else: ""
    "Starting #{c.title} on #{on}…" <> wait
  end

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

  # Back to the form; the start goes on, and the form says so until it finishes.
  defp step(%{casting: %{} = c} = page, %{code: "esc"}),
    do: {:ok, %{page | casting: nil, pending: c}}

  defp step(%{casting: %{}} = page, _key), do: {:ok, page}

  # Esc on the team question goes back to the form, and nothing starts.
  defp step(%{open: open} = page, %{code: "esc"}) when open != nil,
    do: {:ok, %{page | open: nil, start_on_team: false}}

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
    do: {:ok, %{page | chip: min(page.chip + 1, length(chips(page)) - 1)}}

  defp step(%{field: :chips} = page, %{code: "enter"}), do: open_chip(page)

  # The recents row: a digit or Enter sets the chips like that session, and the focus goes
  # back to the box to type.
  defp step(%{field: :recents} = page, %{code: code}) when code in ["up", "k"],
    do: {:ok, %{page | recent: max(page.recent - 1, 0)}}

  defp step(%{field: :recents} = page, %{code: code}) when code in ["down", "j"],
    do: {:ok, %{page | recent: min(page.recent + 1, max(length(page.recents) - 1, 0))}}

  defp step(%{field: :recents} = page, %{code: "enter"}),
    do: {:ok, %{like(page, page.recent + 1) | field: :message}}

  defp step(%{field: :recents} = page, %{code: <<d>>}) when d in ?1..?3 do
    if d - ?0 <= length(page.recents),
      do: {:ok, %{like(page, d - ?0) | field: :message}},
      else: {:ok, page}
  end

  defp step(%{field: :recents} = page, _key), do: {:ok, page}

  defp step(%{field: field} = page, %{code: "enter", modifiers: mods})
       when field != :chips and mods != [],
       do: {:ok, edit(page, field, &Input.insert(&1, "\n"))}

  defp step(%{field: :message} = page, %{code: "j", modifiers: ["ctrl"]}),
    do: {:ok, edit(page, :message, &Input.insert(&1, "\n"))}

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
  def paste(%{field: field} = page, _text) when field in [:chips, :recents], do: page
  def paste(page, text), do: edit(page, page.field, &Input.insert(&1, text))

  defp input_of(page, :message), do: page.text
  defp input_of(page, :title), do: page.title || {title_of(page, resolved(page).cleaned), 0}

  defp edit(page, :message, fun), do: %{page | text: fun.(page.text)}

  defp edit(page, :title, fun) do
    {text, _} = input = input_of(page, :title)
    current = if page.title, do: input, else: {text, String.length(text)}
    %{page | title: fun.(current)}
  end

  # The recents row is a stop only where there are recents.
  defp fields(%{recents: []}), do: [:message, :chips, :title]
  defp fields(_page), do: [:message, :chips, :title, :recents]

  defp next_field(page, step) do
    fields = fields(page)
    n = length(fields)
    i = Enum.find_index(fields, &(&1 == page.field))
    %{page | field: Enum.at(fields, rem(i + step + n, n)), open: nil}
  end

  defp chips(page) do
    r = resolved(page)

    cond do
      r.where == :local -> [:where, :folder, :agent]
      r.team_choice -> [:where, :profile, :agent, :team]
      true -> [:where, :profile, :agent]
    end
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

  def options(%{open: :team} = page) do
    for name <- resolved(page).team_candidates,
        do: {name, name, "#{name}'s budget pays; everyone on #{name} can open it", true}
  end

  def options(_page), do: []

  # A chip's option picked: it holds, and the token of its kind leaves the message.
  defp pick(page) do
    case Enum.at(options(page), page.cursor) do
      {_value, _label, _detail, false} ->
        {:ok, page}

      {value, _label, _detail, true} when page.open == :team ->
        pick_team(page, value)

      {value, _label, _detail, true} ->
        {kind, page} =
          case page.open do
            :where -> {:where, %{page | where: value}}
            :folder -> {nil, %{page | folder: value}}
            :profile -> {:profile, %{page | profile: value}}
            :agent -> {:agent, %{page | agent: value}}
          end

        {:ok, %{strip(page, kind) | open: nil, liked: nil}}

      nil ->
        {:ok, %{page | open: nil}}
    end
  end

  # A team picked for the profile: it holds, this machine remembers it for the profile, and
  # an Enter that asked for it goes on to start.
  defp pick_team(page, team) do
    name = resolved(page).profile_name

    :ok = Client.remember_team(page.origin, name, team)

    page = %{
      page
      | team_picks: Map.put(page.team_picks, name, team),
        remembered: Map.put(page.remembered, name, team),
        open: nil
    }

    if page.start_on_team,
      do: start(%{page | start_on_team: false}),
      else: {:ok, page}
  end

  @doc """
  The plane asked which team: more than one of the person's teams may use the profile, which
  the listing had not said. Back to the form with the question open on the names it gave;
  the pick sends the create again, and Esc leaves the form as it was, nothing started. A
  team this machine remembers for the profile, and one of those named, is the answer: the
  create goes again at once (`{:start, …}`, as a key's), without the question.
  """
  @spec choose_team(t(), [String.t()]) :: {:ok, t()} | {:start, t(), Client.origin(), map()}
  def choose_team(page, teams) do
    c = page.casting || page.pending
    profile = (c && c.profile) || resolved(page).profile_name

    page = %{
      page
      | casting: nil,
        pending: nil,
        teams_asked: Map.put(page.teams_asked, profile, teams)
    }

    if page.remembered[profile] in teams,
      do: start(page),
      else: {:ok, ask_team(page)}
  end

  # The question: the team chip's picker, open, its pick starting.
  defp ask_team(page) do
    at = Enum.find_index(chips(page), &(&1 == :team)) || 0
    %{page | open: :team, cursor: 0, field: :chips, chip: at, start_on_team: true}
  end

  @doc "The agent chosen in the agent picker, as a chip pick."
  @spec chose_agent(t(), String.t()) :: t()
  def chose_agent(page, name), do: strip(%{page | agent: name, open: nil, liked: nil}, :agent)

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
        page = if recent.agent, do: %{page | agent: recent.agent}, else: page
        %{page | liked: recent.title}
    end
  end

  defp start(page) do
    r = resolved(page)

    cond do
      page.pending ->
        {:ok, %{page | said: "Already starting; wait for it."}}

      r.blocked ->
        {:ok, page}

      # Whose budget pays is the person's to say: with no team chosen the question opens,
      # and the pick starts it.
      r.team_choice and r.team == nil ->
        {:ok, ask_team(page)}

      true ->
        cast(page, r)
    end
  end

  defp cast(page, r) do
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
           team: r.team || page.team,
           visibility: NewSession.visibility(page.only_me)
         }}
    end
  end

  ## What the server tells it

  @doc "The plane says the session waits for a place."
  @spec waiting(t()) :: t()
  def waiting(%{casting: %{} = c} = page),
    do: %{page | casting: %{c | done: 1, queued: true, waiting: true}}

  def waiting(%{pending: %{} = c} = page),
    do: %{page | pending: %{c | done: 1, queued: true, waiting: true}}

  def waiting(page), do: page

  @doc """
  The start Esc left running finished, or failed: the form stops saying it is starting.
  """
  @spec settled(t()) :: t()
  def settled(page), do: %{page | pending: nil}

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

  # The place frees by itself only where the plane answered that the start waits for one;
  # Esc goes back to the form, and the start goes on either way.
  def footer(%{casting: %{waiting: true}} = page),
    do:
      " #{Lines.first(:waiting_for_a_place, page.seed)} — Esc goes back; it starts when a place frees "

  def footer(%{casting: %{}} = page),
    do: " #{Lines.first(:casting, page.seed)} — Esc goes back to the form; the start goes on "

  def footer(%{open: :team, start_on_team: true}),
    do: " ↑↓ move · Enter picks the team and starts · Esc goes back without starting "

  def footer(%{open: open}) when open != nil, do: " ↑↓ move · Enter picks · Esc closes "

  def footer(%{field: :recents}),
    do: " ↑↓ move · Enter or 1-3 sets the chips like it · Tab on · Esc closes "

  def footer(%{recents: []}),
    do: " Enter starts · Tab the settings, then ←→ and Enter · Ctrl-J new line · Esc closes "

  def footer(_page),
    do:
      " Enter starts · Tab the settings, then ←→ and Enter · Ctrl-J new line · Tab to the recents to start like one · Esc closes "

  @spec render(t(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(page, rect, _state) do
    rows = rows(page, max(rect.width - 2, 1), max(rect.height - 2, 1))
    [{%Paragraph{text: rows, block: block(page)}, rect}]
  end

  @doc """
  The rows drawn inside a `width` × `height` page: its lines folded to the width, from the
  row that keeps what has the focus on screen.
  """
  @spec rows(t(), pos_integer(), pos_integer()) :: [Line.t()]
  def rows(page, width, height) do
    {lines, {keep, until}} = focused_lines(page)
    folded = Enum.map(lines, &fold(&1, width))
    starts = folded |> Enum.scan(0, &(length(&1) + &2)) |> then(&[0 | &1])
    keep_row = Enum.at(starts, keep)
    until_row = Enum.at(starts, until + 1) - 1
    top = min(max(until_row - height + 1, 0), keep_row)
    folded |> Enum.concat() |> Enum.drop(top) |> Enum.take(height)
  end

  @doc "The rows `rows/3` draws, as plain text."
  @spec plain_rows(t(), pos_integer(), pos_integer()) :: [String.t()]
  def plain_rows(page, width, height) do
    page |> rows(width, height) |> Enum.map(&line_text/1)
  end

  defp line_text(%Line{spans: spans}), do: Enum.map_join(spans, & &1.content)

  # A line folded at word ends to `width` cells, each span keeping its style; a word wider
  # than the page is cut.
  defp fold(%Line{spans: spans} = line, width) do
    if Model.cell_width(line_text(line)) <= width do
      [line]
    else
      pieces =
        for span <- spans,
            word <- Regex.split(~r/(?<= )/u, span.content, trim: true),
            chunk <- chop(word, width),
            do: {%{span | content: chunk}, Model.cell_width(chunk)}

      {rows, row, _used} =
        Enum.reduce(pieces, {[], [], 0}, fn {span, w}, {rows, row, used} ->
          if used + w > width and row != [],
            do: {[Enum.reverse(row) | rows], [span], w},
            else: {rows, [span | row], used + w}
        end)

      [Enum.reverse(row) | rows] |> Enum.reverse() |> Enum.map(&%{line | spans: &1})
    end
  end

  defp chop(word, width) do
    if Model.cell_width(word) <= width do
      [word]
    else
      word
      |> String.graphemes()
      |> Enum.chunk_while(
        {"", 0},
        fn g, {acc, w} ->
          gw = Model.cell_width(g)
          if w + gw > width, do: {:cont, acc, {g, gw}}, else: {:cont, {acc <> g, w + gw}}
        end,
        fn {acc, _w} -> {:cont, acc, {"", 0}} end
      )
    end
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

  defp lines(page, _width), do: page |> focused_lines() |> elem(0)

  # The form's lines, and which of them the focus is on: `{keep, until}`, the line that
  # must stay on screen and the last one worth showing under it.
  defp focused_lines(%{casting: %{}} = page), do: {lines(page, 0), {0, 0}}

  defp focused_lines(page) do
    r = resolved(page)

    head = [
      Line.new([Span.new("What should the troupe do?", style: Theme.style(nil, [:bold]))]),
      Line.new([Span.new(page.quip, style: Theme.style(:muted, [:italic]))]),
      Line.new([])
    ]

    message = message_lines(page)
    why = why_line(r)
    picker = picker_lines(page)

    lines =
      head ++
        message ++
        [Line.new([]), sentence(page, r)] ++
        why ++ picker ++ [Line.new([]), called(page, r), hint()] ++ recent_lines(page)

    sentence_at = length(head) + length(message) + 1
    picker_at = sentence_at + 1 + length(why)
    called_at = picker_at + length(picker) + 1

    focus =
      cond do
        page.open != nil ->
          {picker_at + 2 + page.cursor, picker_at + 2 + page.cursor}

        page.field == :message ->
          {text, pos} = page.text
          cursor_line = (text |> String.slice(0, pos) |> String.split("\n") |> length()) - 1
          {length(head) + cursor_line, sentence_at + length(why)}

        page.field == :chips ->
          {sentence_at, sentence_at + length(why)}

        page.field == :title ->
          {called_at, called_at}

        page.field == :recents ->
          {called_at + 4 + page.recent, called_at + 4 + page.recent}
      end

    {lines, focus}
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
      chip.(2, r.agent_label, nil)
      | who_spans(r, chip)
    ])
  end

  # Whose it is: a chip where more than one of the person's teams may use the profile, the
  # sentence's end as it was where one may.
  defp who_spans(%{where: :platform, team_choice: true, only_me: true} = r, chip),
    do: [
      Span.new(" · for "),
      chip.(3, r.team || "which team?", if(r.team, do: nil, else: :stale)),
      Span.new(" · " <> r.who)
    ]

  defp who_spans(%{where: :platform, team_choice: true} = r, chip),
    do: [
      Span.new(" · everyone on "),
      chip.(3, r.team || "which team?", if(r.team, do: nil, else: :stale)),
      Span.new(" can open it")
    ]

  defp who_spans(r, _chip), do: [Span.new(" · " <> r.who)]

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
      agent: "HOW IT STARTS  #agent",
      team: "WHICH TEAM IT IS FOR  its budget pays"
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

        selected = page.field == :recents and page.recent == n - 1
        mark = if selected, do: "▸ ", else: "  "
        title_style = if selected, do: Theme.style(nil, [:bold, :reversed]), else: Theme.style(nil)

        Line.new([
          Span.new("#{mark}#{n} ", style: Theme.style(:accent, [:bold])),
          Span.new(r.title, style: title_style),
          Span.new("  "),
          Span.new(Enum.join(facts, " · "), style: Theme.style(:muted))
        ])
      end)

    [
      Line.new([]),
      Line.new([Span.new("// START LIKE LAST TIME", style: Theme.style(:working))]) | rows
    ]
  end
end
