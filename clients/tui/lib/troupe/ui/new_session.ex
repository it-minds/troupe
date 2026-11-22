defmodule Troupe.UI.NewSession do
  @moduledoc """
  The rules of the prompt-first new session, apart from any screen: what the inline
  tokens in a message set, what the agent is left to read, the title the first line
  gives, which profile is picked when nobody picked one and the sentence that says why,
  how full a profile is, and who can open the session.

  `/new`'s screen and `troupe run`'s task text read these; the desktop app has the same
  rules in `@troupe/client` (`newSession.ts`), and the two suites hold them to the same
  examples.

  A token is `@profile`, `#agent`, `/local` or `/platform`, at the start of the message or
  after whitespace, and is one only where it names something on offer: `#123` and
  `@someone` stay in the message as they were typed. A token wins over a chip and a chip
  over the auto-pick; picking a chip takes the token of its kind out, so the last thing the
  person did is what holds.
  """

  alias Troupe.Protocol.Words

  @profile ~r/(^|\s)@([\w.-]+)/u
  @agent ~r/(^|\s)#([\w.-]+)/u
  @where ~r/(^|\s)\/(local|platform)(?=\s|$)/u

  @typedoc "What the tokens in a message set."
  @type tokens :: %{
          optional(:profile) => String.t(),
          optional(:agent) => String.t(),
          optional(:where) => :local | :platform
        }

  @typedoc "The names a token may name."
  @type names :: %{profiles: [String.t()], agents: [String.t()]}

  @doc "The tokens in `text`, each only where it names something on offer."
  @spec tokens(String.t(), names()) :: tokens()
  def tokens(text, names) do
    %{}
    |> put_first(:profile, first(@profile, text, names.profiles))
    |> put_first(:agent, first(@agent, text, names.agents))
    |> put_first(:where, where(first(@where, text, nil)))
  end

  defp where("local"), do: :local
  defp where("platform"), do: :platform
  defp where(_none), do: nil

  defp put_first(map, _key, nil), do: map
  defp put_first(map, key, value), do: Map.put(map, key, value)

  defp first(re, text, known) do
    re
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.find_value(fn [_lead, name] -> if known == nil or name in known, do: name end)
  end

  @doc "The message with its tokens taken out and spaces closed up: what the agent reads."
  @spec clean(String.t(), names()) :: String.t()
  def clean(text, names) do
    text
    |> strip(@profile, names.profiles)
    |> strip(@agent, names.agents)
    |> strip(@where, nil)
    |> String.replace(~r/[ \t]+/u, " ")
    |> String.replace(~r/ *\n */u, "\n")
    |> String.trim()
  end

  @doc """
  The message with the tokens of the kinds just picked on a chip taken out (`:profile`,
  `:agent`, `:where`), so the chip holds.
  """
  @spec strip_kinds(String.t(), [:profile | :agent | :where], names()) :: String.t()
  def strip_kinds(text, kinds, names) do
    Enum.reduce(kinds, text, fn
      :profile, t -> strip(t, @profile, names.profiles)
      :agent, t -> strip(t, @agent, names.agents)
      :where, t -> strip(t, @where, nil)
    end)
    |> String.replace(~r/[ \t]{2,}/u, " ")
    |> String.replace(~r/[ \t]+$/mu, "")
    |> String.replace(~r/^[ \t]+/u, "")
  end

  defp strip(text, re, known) do
    Regex.replace(re, text, fn whole, lead, name ->
      if known == nil or name in known, do: lead, else: whole
    end)
  end

  @doc "The title the cleaned message gives: its first sentence or line, at most 60 characters."
  @spec title(String.t()) :: String.t()
  def title(cleaned) do
    cleaned
    |> String.split(~r/\.\s|\.$|\n/u, parts: 2)
    |> List.first("")
    |> String.trim()
    |> String.slice(0, 60)
  end

  @typedoc "How full a profile is, from its `profiles.list` row."
  @type room :: %{
          free: non_neg_integer(),
          capacity: non_neg_integer(),
          full: boolean(),
          idle: boolean(),
          at_ceiling: boolean(),
          max_sessions: pos_integer() | nil
        }

  @doc """
  What a create would meet on a profile: no room below the ceiling is `full` (a create
  waits for the next place), the ceiling is `at_ceiling` (a create is refused). A profile
  with no pod and nothing running is scaled to zero, `idle` and not full: a create there
  starts a pod.
  """
  @spec room(map()) :: room()
  def room(row) do
    capacity = int(row["capacity"])
    active = int(row["active_sessions"])
    max = if is_integer(row["max_sessions"]), do: row["max_sessions"]
    at_ceiling = max != nil and active >= max
    free = max(capacity - active, 0)
    idle = not at_ceiling and capacity == 0 and active == 0

    %{
      free: free,
      capacity: capacity,
      full: not at_ceiling and not idle and free == 0,
      idle: idle,
      at_ceiling: at_ceiling,
      max_sessions: max
    }
  end

  defp int(n) when is_integer(n), do: n
  defp int(_other), do: 0

  @doc """
  The agent a session on a profile starts as when none is named: `build` where the profile
  offers it, else the first it offers, the plane's own rule; `nil` where it offers none, and
  the create then names none and the plane chooses or says why it cannot.
  """
  @spec default_agent([String.t()]) :: String.t() | nil
  def default_agent(agents) do
    if "build" in agents, do: "build", else: List.first(agents)
  end

  @doc """
  The profile picked when nobody picked one, and why: the last used while it has room,
  else the first with room in the listing's order; with none that has room, the last used
  (or the first) all the same, to queue on.
  """
  @spec auto_pick([map()], String.t() | nil) :: {String.t() | nil, String.t()}
  def auto_pick(rows, last_used) do
    last = last_used && Enum.find(rows, &(&1["name"] == last_used))

    # A profile scaled to zero has room: a create there starts a pod rather than waiting.
    roomy = fn row ->
      r = room(row)
      (r.free > 0 or r.idle) and not r.at_ceiling
    end

    any = Enum.find(rows, roomy)

    cond do
      last && roomy.(last) -> {last["name"], "Picked #{last["name"]} because you used it last."}
      any && last -> {any["name"], "Picked #{any["name"]}: #{last["name"]} is full right now."}
      any -> {any["name"], "Picked #{any["name"]}: the first profile with room right now."}
      fallback = last || List.first(rows) -> {fallback["name"], "Every profile is full right now."}
      true -> {nil, "There is no profile you may start a session on."}
    end
  end

  @doc """
  Who can open it, as the sentence ends: it follows from where it runs. Private (sealed) is
  this computer's: a platform session from the screen is the team's, `--private` or not,
  unless `only_me?` (`/new --only-me`), its owner's and the people they invite, on the
  team's profile all the same. The desktop app's `whoCanOpen` says the same.
  """
  @spec who(:local | :platform, [String.t()] | nil, boolean()) :: String.t()
  def who(:local, _teams, _only_me?), do: "only you can open it"

  def who(:platform, _teams, true), do: "only you can open it until you invite people"

  def who(:platform, [_ | _] = teams, _only_me?),
    do: "everyone on #{Words.and_list(teams)} can open it"

  def who(:platform, _none, _only_me?), do: "your team can open it"

  @doc """
  What a platform create sends as `visibility`: `team`, or `private`, its owner and the
  people invited by name. Never a sealed session; the desktop's `platformVisibility`.
  """
  @spec visibility(boolean()) :: String.t()
  def visibility(true), do: "private"
  def visibility(false), do: "team"

  @doc ~S|"Set from your message: /local @dev #plan.", or nil with no token.|
  @spec tokens_sentence(tokens()) :: String.t() | nil
  def tokens_sentence(tokens) do
    said =
      [
        tokens[:where] && "/#{tokens[:where]}",
        tokens[:profile] && "@#{tokens[:profile]}",
        tokens[:agent] && "##{tokens[:agent]}"
      ]
      |> Enum.reject(&is_nil/1)

    if said != [], do: "Set from your message: #{Enum.join(said, " ")}."
  end

  @doc "The line for a full profile."
  @spec full_house(String.t(), non_neg_integer()) :: String.t()
  def full_house(name, capacity),
    do:
      "Full house: #{name} has #{capacity} of #{capacity} running. Pick another, or queue it for the next free place."

  @doc "The line for a profile at its ceiling, until the plane's own sentence is known."
  @spec ceiling(String.t(), non_neg_integer()) :: String.t()
  def ceiling(name, 1), do: "#{name} allows 1 session at once."
  def ceiling(name, max), do: "#{name} allows #{max} sessions at once."

  @doc "The line while this computer's daemon is not there."
  @spec local_down() :: String.t()
  def local_down,
    do:
      "This computer's daemon isn't running. Start it with troupe daemon, and this switches on by itself."

  @doc """
  The line for a platform start this computer cannot make: why there is no plane (`reason`
  as `Troupe.Client.signed_in_plane/0` answers it), and that Enter starts it here instead.
  """
  @spec no_plane(term(), String.t() | nil) :: String.t()
  def no_plane(reason, profile) do
    what = if profile, do: "#{profile} is not on offer", else: "the platform is not on offer"

    case reason do
      :local_only ->
        "Local only is on, so the platform is not asked and #{what}. Enter starts it on this computer."

      none when none in [nil, :logged_out] ->
        "This computer is not signed in to a platform, so #{what}: run troupe login <plane-url>. " <>
          "Enter starts it on this computer."

      other ->
        "The platform is not reachable (#{Troupe.Client.profile_refusal(other)}), so #{what}. " <>
          "Enter starts it on this computer."
    end
  end

  @doc """
  The line for a plane that answered the profile or session listing with an error, as the
  plane's error, not as having no profile.
  """
  @spec plane_error(term()) :: String.t()
  def plane_error(:logged_out),
    do:
      "This computer is not signed in to the platform: run troupe login <plane-url>, then /new again."

  def plane_error("signed out" <> _rest),
    do: "Your sign-in to the platform has run out: run troupe login <plane-url>, then /new again."

  def plane_error(reason),
    do: "The platform did not list your profiles: #{Troupe.Client.profile_refusal(reason)}."

  @doc "The line for a profile the person may not start a session on."
  @spec not_allowed(String.t()) :: String.t()
  def not_allowed(name),
    do: "You may not start a session on #{name}. The profile chip lists the ones you may."

  @doc "The line for an agent chip with nothing to pick: why there is nothing."
  @spec no_agents(:local | :platform, String.t() | nil, boolean()) :: String.t()
  def no_agents(:local, _profile, false = _daemon_up?),
    do:
      "This computer's daemon is not running, so there is no agent to pick. Start it with troupe daemon."

  def no_agents(:local, _profile, true), do: "This computer has no agent to pick."
  def no_agents(:platform, nil, _daemon_up?), do: "There is no profile to pick an agent from."

  def no_agents(:platform, profile, _daemon_up?),
    do: "#{profile} offers no agents to pick."

  @doc """
  The teams a refused `session.create` asks the person to choose between: the plane's
  `invalid_params` with `reason: "choose a team"` and `teams`, sent when more than one of
  their teams may use the profile and the create named none. Whose budget pays and who can
  open the session follow from the answer, so the plane asks rather than guess. `nil` for
  any other refusal.
  """
  @spec teams_to_choose(term()) :: [String.t()] | nil
  def teams_to_choose(%{data: %{"reason" => "choose a team", "teams" => teams}}),
    do: teams_to_choose({:choose_team, teams})

  def teams_to_choose({:choose_team, teams}) when is_list(teams) do
    case Enum.filter(teams, &(is_binary(&1) and &1 != "")) do
      [_, _ | _] = names -> names
      _fewer -> nil
    end
  end

  def teams_to_choose(_refusal), do: nil

  @doc """
  The team a session on a profile is for, where that is a choice: the one picked on the
  screen, else the one this client remembers for the profile, whichever is still one of
  `candidates`; `nil` where there is none yet and the person is asked. With one candidate
  or none it is `nil` as well, and the create names no team: the plane takes the only one.
  """
  @spec chosen_team([String.t()] | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def chosen_team(candidates, picked, remembered) do
    names = candidates || []

    cond do
      length(names) < 2 -> nil
      picked in names -> picked
      remembered in names -> remembered
      true -> nil
    end
  end

  @doc "The question, when more than one of the person's teams may use the profile."
  @spec team_question(String.t(), [String.t()]) :: String.t()
  def team_question(profile, teams) do
    all = if length(teams) == 2, do: "both", else: "all"

    "#{Words.and_list(teams)} can #{all} use #{profile}. " <>
      "Choose the team it is for: its budget pays, and everyone on it can open it."
  end
end
