defmodule Troupe.UI.HQ do
  @moduledoc """
  The remote HQ page: teams, the profiles a team can run with their health and
  capacity, and the sessions on the plane — with this machine's local sessions
  in the same list, labelled, so switching between the two is one keypress
  rather than two programs.

  It holds page state and answers keys; the TUI server owns the process and the
  frame, exactly like the settings, observer and sessions pages. Everything it
  knows comes from `Troupe.Client`, so it works against a plane, against
  `FakeRemote`, and (with no teams and no capacity) against a local-only
  machine.

  When the plane is unreachable the page still renders: the sessions already
  attached keep streaming, the list shows what the last call returned, and a
  banner says that creating and activating are the things that will not work
  (Decision 78).
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Troupe.Client
  alias Troupe.UI.TUI.Model

  @type column :: :teams | :profiles | :sessions

  @typedoc """
  The new-session wizard: which field is being filled, and what has been chosen
  so far. It is deliberately a plain map — the page is a fold over keypresses,
  and a half-finished session is not worth a process.
  """
  @type create :: %{
          step: :profile | :source | :url | :ref | :visibility | :prompt,
          profile: String.t() | nil,
          source: String.t(),
          url: String.t(),
          ref: String.t(),
          visibility: String.t(),
          prompt: String.t(),
          cursor: non_neg_integer()
        }

  @type t :: %{
          origin: Client.origin() | nil,
          workspace: String.t(),
          teams: [map()],
          profiles: [map()],
          sessions: [Client.summary()],
          column: column(),
          cursors: %{column() => non_neg_integer()},
          status: map(),
          error: String.t() | nil,
          create: create() | nil
        }

  @doc "Opens HQ against a plane (or nothing, for a local-only machine)."
  @spec open(Client.origin() | nil, String.t()) :: t()
  def open(origin, workspace) do
    %{
      origin: origin,
      workspace: workspace,
      teams: [],
      profiles: [],
      sessions: [],
      column: :sessions,
      cursors: %{teams: 0, profiles: 0, sessions: 0},
      status: status(origin),
      error: nil,
      create: nil
    }
    |> load_teams()
    |> reload()
  end

  @doc "Reloads profiles and sessions for the selected team, and the plane's status."
  @spec reload(t()) :: t()
  def reload(hq) do
    hq = %{hq | status: status(hq.origin)}
    team = selected_team(hq)

    hq
    |> load_profiles(team)
    |> load_sessions(team)
  end

  @doc "The row the cursor is on in a column."
  @spec selected(t(), column()) :: map() | nil
  def selected(hq, :teams), do: Enum.at(hq.teams, cursor(hq, :teams))
  def selected(hq, :profiles), do: Enum.at(hq.profiles, cursor(hq, :profiles))
  def selected(hq, :sessions), do: Enum.at(hq.sessions, cursor(hq, :sessions))

  @spec selected_team(t()) :: String.t() | nil
  def selected_team(hq) do
    case selected(hq, :teams) do
      %{id: id} -> id
      _ -> nil
    end
  end

  @doc "Whether the plane is answering. A local-only HQ is always up."
  @spec up?(t()) :: boolean()
  def up?(%{status: %{up?: up?}}), do: up?
  def up?(_hq), do: false

  ## Keys

  @doc """
  Handles a key. Returns `{:ok, hq}`, `{:open, hq, session_id}` when a session
  was attached and should take the screen, or `:close`.
  """
  @spec key(t(), map()) :: {:ok, t()} | {:open, t(), String.t()} | :close
  def key(%{create: %{}} = hq, key), do: create_key(hq, key)

  def key(_hq, %{code: "esc"}), do: :close

  def key(hq, %{code: code}) when code in ["tab", "right", "l"],
    do: {:ok, %{hq | column: next_column(hq.column, 1)}}

  def key(hq, %{code: code}) when code in ["left", "h"],
    do: {:ok, %{hq | column: next_column(hq.column, -1)}}

  def key(hq, %{code: code}) when code in ["up", "k"], do: {:ok, move(hq, -1)}
  def key(hq, %{code: code}) when code in ["down", "j"], do: {:ok, move(hq, 1)}
  def key(hq, %{code: "r"}), do: {:ok, reload(hq)}
  def key(hq, %{code: "n"}), do: {:ok, start_create(hq)}

  def key(hq, %{code: "enter"}) do
    case hq.column do
      :teams -> {:ok, reload(hq)}
      :profiles -> {:ok, %{hq | column: :sessions}}
      :sessions -> open_selected(hq)
    end
  end

  def key(hq, _key), do: {:ok, hq}

  @doc "Applies a fleet `summary` notification to the list without a round trip."
  @spec summary(t(), String.t(), map()) :: t()
  def summary(hq, session_id, diff) when is_binary(session_id) do
    sessions =
      Enum.map(hq.sessions, fn session ->
        if session.id == session_id, do: merge_diff(session, diff), else: session
      end)

    %{hq | sessions: sessions}
  end

  def summary(hq, _session_id, _diff), do: hq

  ## Rendering

  @doc "Renders the page into `rect`."
  @spec render(t(), Rect.t(), map()) :: [{term(), Rect.t()}]
  def render(hq, rect, state) do
    {banner, rect} = banner(hq, rect)

    case hq.create do
      nil -> banner ++ columns(hq, rect, state)
      create -> banner ++ create_page(hq, create, rect)
    end
  end

  @doc "The line under the page that says what the keys do."
  @spec footer(t()) :: String.t()
  def footer(%{create: %{step: step}}), do: " new session — #{step_hint(step)} · Esc cancels "

  def footer(_hq),
    do: " HQ — ↑↓ move · ←/→/Tab column · Enter opens · n new session · r refresh · Esc back "

  defp banner(hq, rect) do
    if up?(hq) do
      {[], rect}
    else
      [line, rest] = Layout.split(rect, :vertical, [{:length, 1}, {:fill, 1}])

      text =
        "⚠ the plane is unreachable — attached sessions keep streaming; " <>
          "creating and activating sessions are unavailable" <> reason(hq)

      {[{%Paragraph{text: text, style: %Style{fg: :yellow, modifiers: [:bold]}}, line}], rest}
    end
  end

  defp reason(%{error: error}) when is_binary(error), do: " (#{error})"

  defp reason(%{status: %{error: error}}) when error not in [nil, :not_started],
    do: " (#{inspect(error)})"

  defp reason(_hq), do: ""

  defp columns(hq, rect, state) do
    [teams_rect, profiles_rect, sessions_rect] =
      Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}, {:fill, 5}])

    [
      {team_list(hq), teams_rect},
      {profile_list(hq), profiles_rect},
      {session_list(hq, state), sessions_rect}
    ]
  end

  defp team_list(hq) do
    items = Enum.map(hq.teams, & &1.name)

    %List{
      items: if(items == [], do: ["(no teams)"], else: items),
      selected: if(hq.teams == [], do: nil, else: cursor(hq, :teams)),
      highlight_symbol: "▸ ",
      highlight_style: highlight(hq, :teams),
      block: %Block{title: " teams ", borders: [:all], border_style: border(hq, :teams)}
    }
  end

  defp profile_list(hq) do
    items =
      Enum.map(hq.profiles, fn profile ->
        String.trim_trailing(
          String.pad_trailing(profile.name, 14) <>
            String.pad_trailing(to_string(profile.health), 10) <> capacity(profile.capacity)
        )
      end)

    %List{
      items: if(items == [], do: ["(no profiles)"], else: items),
      selected: if(hq.profiles == [], do: nil, else: cursor(hq, :profiles)),
      highlight_symbol: "▸ ",
      highlight_style: highlight(hq, :profiles),
      block: %Block{
        title: " profiles — health · capacity ",
        borders: [:all],
        border_style: border(hq, :profiles)
      }
    }
  end

  defp capacity(%{free: free, total: total}) when is_integer(free) and is_integer(total),
    do: "#{free}/#{total} free"

  defp capacity(_capacity), do: ""

  defp session_list(hq, state) do
    items = Enum.map(hq.sessions, &session_line(&1, state))

    %List{
      items: if(items == [], do: ["(no sessions)"], else: items),
      selected: if(hq.sessions == [], do: nil, else: cursor(hq, :sessions)),
      highlight_symbol: "▸ ",
      highlight_style: highlight(hq, :sessions),
      block: %Block{
        title: " sessions — remote and local ",
        borders: [:all],
        border_style: border(hq, :sessions)
      }
    }
  end

  # Where a session lives is the first thing on its row, not a footnote: a list
  # that mixes the two has to say which is which at a glance.
  defp session_line(session, state) do
    marker = if session.id == state.session_id, do: "●", else: " "

    [
      marker,
      String.pad_trailing(label(session.origin), 8),
      String.pad_trailing(to_string(session.state), 10),
      String.pad_trailing(to_string(session.profile || "—"), 10),
      String.pad_trailing(to_string(session.team || session.owner || ""), 10),
      Model.one_line(session.title || session.id)
    ]
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  defp label({:remote, _plane}), do: "remote"
  defp label(_origin), do: "local"

  defp highlight(hq, column) do
    if hq.column == column,
      do: %Style{fg: :cyan, modifiers: [:bold]},
      else: %Style{modifiers: [:bold]}
  end

  defp border(hq, column) do
    if hq.column == column, do: %Style{fg: :cyan}, else: %Style{fg: :dark_gray}
  end

  ## The new-session wizard

  defp start_create(hq) do
    %{
      hq
      | create: %{
          step: :profile,
          profile: nil,
          source: "empty",
          url: "",
          ref: "",
          visibility: "private",
          prompt: "",
          cursor: 0
        }
    }
  end

  defp create_key(hq, %{code: "esc"}), do: {:ok, %{hq | create: nil}}

  defp create_key(%{create: %{step: :profile} = create} = hq, %{code: code})
       when code in ["up", "k"],
       do: {:ok, put_create(hq, cursor: max(create.cursor - 1, 0))}

  defp create_key(%{create: %{step: :profile} = create} = hq, %{code: code})
       when code in ["down", "j"],
       do: {:ok, put_create(hq, cursor: min(create.cursor + 1, max(length(hq.profiles) - 1, 0)))}

  defp create_key(%{create: %{step: :profile} = create} = hq, %{code: "enter"}) do
    case Enum.at(hq.profiles, create.cursor) do
      nil -> {:ok, hq}
      profile -> {:ok, put_create(hq, profile: profile.name, step: :source, cursor: 0)}
    end
  end

  defp create_key(%{create: %{step: :source}} = hq, %{code: code})
       when code in ["up", "k", "down", "j"] do
    next = if hq.create.source == "empty", do: "git", else: "empty"
    {:ok, put_create(hq, source: next)}
  end

  defp create_key(%{create: %{step: :source, source: "git"}} = hq, %{code: "enter"}),
    do: {:ok, put_create(hq, step: :url)}

  defp create_key(%{create: %{step: :source}} = hq, %{code: "enter"}),
    do: {:ok, put_create(hq, step: :visibility)}

  defp create_key(%{create: %{step: :url}} = hq, %{code: "enter"}),
    do: {:ok, put_create(hq, step: :ref)}

  defp create_key(%{create: %{step: :ref}} = hq, %{code: "enter"}),
    do: {:ok, put_create(hq, step: :visibility)}

  defp create_key(%{create: %{step: :visibility}} = hq, %{code: code})
       when code in ["up", "k", "down", "j"] do
    next = if hq.create.visibility == "private", do: "team", else: "private"
    {:ok, put_create(hq, visibility: next)}
  end

  defp create_key(%{create: %{step: :visibility}} = hq, %{code: "enter"}),
    do: {:ok, put_create(hq, step: :prompt)}

  defp create_key(%{create: %{step: :prompt}} = hq, %{code: "enter"}), do: create_session(hq)

  defp create_key(%{create: %{step: step}} = hq, %{code: "backspace"})
       when step in [:url, :ref, :prompt],
       do: {:ok, put_create(hq, [{step, String.slice(Map.fetch!(hq.create, step), 0..-2//1)}])}

  defp create_key(%{create: %{step: step}} = hq, %{code: code, modifiers: mods})
       when step in [:url, :ref, :prompt] and mods in [[], ["shift"]] do
    if String.length(code) == 1,
      do: {:ok, put_create(hq, [{step, Map.fetch!(hq.create, step) <> code}])},
      else: {:ok, hq}
  end

  defp create_key(hq, _key), do: {:ok, hq}

  defp put_create(hq, changes), do: %{hq | create: Enum.into(changes, hq.create)}

  defp create_session(%{origin: nil} = hq),
    do: {:ok, %{hq | create: nil, error: "no plane; run troupe login <plane-url> first"}}

  defp create_session(hq) do
    create = hq.create

    params = %{
      team: selected_team(hq),
      profile: create.profile,
      source: source(create),
      visibility: create.visibility,
      prompt: create.prompt
    }

    case Client.create_session(hq.origin, params) do
      {:ok, session_id} ->
        {:open, %{hq | create: nil, error: nil}, session_id}

      {:error, reason} ->
        {:ok, %{hq | create: nil, error: message(reason)}}
    end
  end

  defp source(%{source: "git", url: url, ref: ref}),
    do: %{type: "git", url: url, ref: if(ref == "", do: "main", else: ref)}

  defp source(_create), do: %{type: "empty"}

  defp create_page(hq, create, rect) do
    lines = [
      "profile     #{create.profile || "(pick one)"}",
      "team        #{selected_team(hq) || "(none)"}",
      "source      #{create.source}#{git_summary(create)}",
      "visibility  #{create.visibility}",
      "prompt      #{create.prompt}▏",
      "",
      step_hint(create.step)
    ]

    body =
      case create.step do
        :profile -> profile_choices(hq, create) ++ ["", step_hint(create.step)]
        _ -> lines
      end

    [
      {%Paragraph{
         text: Enum.join(body, "\n"),
         wrap: true,
         block: %Block{title: " new session ", borders: [:all], border_type: :double}
       }, rect}
    ]
  end

  defp profile_choices(hq, create) do
    ["pick a profile:", ""] ++
      Enum.with_index(hq.profiles, fn profile, index ->
        marker = if index == create.cursor, do: "▸ ", else: "  "
        marker <> String.pad_trailing(profile.name, 14) <> capacity(profile.capacity)
      end)
  end

  defp git_summary(%{source: "git", url: url, ref: ref}), do: " #{url}##{ref}"
  defp git_summary(_create), do: ""

  defp step_hint(:profile), do: "↑↓ pick a profile, Enter continues"
  defp step_hint(:source), do: "↑↓ empty or git, Enter continues"
  defp step_hint(:url), do: "type the repository URL, Enter continues"
  defp step_hint(:ref), do: "type the ref (blank means main), Enter continues"
  defp step_hint(:visibility), do: "↑↓ private or team, Enter continues"
  defp step_hint(:prompt), do: "type the first prompt, Enter creates the session and attaches"

  ## Opening

  defp open_selected(hq) do
    case selected(hq, :sessions) do
      nil ->
        {:ok, hq}

      session ->
        # Browsing is always mode `read`: opening a dormant session must not
        # wake it, and the first activating action is what does.
        case Client.open_session(session.origin, session.id, :read) do
          {:ok, session_id} -> {:open, %{hq | error: nil}, session_id}
          {:error, reason} -> {:ok, %{hq | error: message(reason)}}
        end
    end
  end

  ## Loading

  defp load_teams(%{origin: nil} = hq), do: hq

  defp load_teams(hq) do
    case Client.teams(hq.origin) do
      {:ok, teams} -> %{hq | teams: teams, error: nil}
      {:error, reason} -> %{hq | error: message(reason)}
    end
  end

  defp load_profiles(%{origin: nil} = hq, _team), do: %{hq | profiles: []}

  defp load_profiles(hq, team) do
    case Client.profiles(hq.origin, team) do
      {:ok, profiles} -> %{hq | profiles: profiles}
      {:error, reason} -> %{hq | error: message(reason)}
    end
  end

  # Remote sessions first, then this machine's own: one list, each row saying
  # where it lives, so a local session is never hidden behind a plane outage.
  defp load_sessions(hq, team) do
    remote =
      case hq.origin && Client.sessions(hq.origin, %{team: team}) do
        {:ok, sessions} -> sessions
        _ -> keep_remote(hq)
      end

    local =
      case Client.sessions({:local, hq.workspace}, %{}) do
        {:ok, sessions} -> sessions
        _ -> []
      end

    %{hq | sessions: remote ++ local}
  end

  # A plane that stopped answering should not empty the list: what it last said
  # is still the best description of what is out there.
  defp keep_remote(hq), do: Enum.filter(hq.sessions, &match?({:remote, _}, &1.origin))

  defp status(nil), do: %{up?: true, origin: nil, principal: nil, scopes: [], error: nil}
  defp status(origin), do: Client.fleet_status(origin)

  defp merge_diff(session, diff) when is_map(diff) do
    Enum.reduce(diff, session, fn {key, value}, acc ->
      case key do
        "state" -> %{acc | state: state_atom(value)}
        "status" -> %{acc | status: value}
        "title" -> %{acc | title: value}
        "tokens" -> %{acc | tokens: value}
        "cost" -> %{acc | cost: value}
        "updated_at" -> %{acc | updated_at: value}
        _ -> acc
      end
    end)
  end

  defp merge_diff(session, _diff), do: session

  defp state_atom(value) when is_binary(value) do
    case value do
      "active" -> :active
      "dormant" -> :dormant
      "read_only" -> :read_only
      "erased" -> :erased
      other -> String.to_atom(other)
    end
  end

  defp state_atom(value) when is_atom(value), do: value
  defp state_atom(_value), do: :dormant

  defp cursor(hq, column) do
    count =
      case column do
        :teams -> length(hq.teams)
        :profiles -> length(hq.profiles)
        :sessions -> length(hq.sessions)
      end

    min(Map.get(hq.cursors, column, 0), max(count - 1, 0))
  end

  defp move(hq, step) do
    column = hq.column
    next = max(cursor(hq, column) + step, 0)
    hq = %{hq | cursors: Map.put(hq.cursors, column, next)}

    # Moving between teams changes what the other two columns are about.
    if column == :teams, do: reload(hq), else: hq
  end

  defp next_column(column, step) do
    columns = [:teams, :profiles, :sessions]
    index = Enum.find_index(columns, &(&1 == column)) || 0
    Enum.at(columns, rem(index + step + length(columns), length(columns)))
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
