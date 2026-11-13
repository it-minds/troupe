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

  @doc ~S|"A", "A and B", "A, B and C".|
  @spec and_list([String.t()]) :: String.t()
  def and_list([]), do: ""
  def and_list([one]), do: one

  def and_list(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  @doc "Who can open it, as the sentence ends: it follows from where it runs."
  @spec who(:local | :platform, [String.t()] | nil, boolean()) :: String.t()
  def who(:local, _teams, _private?), do: "only you can open it"
  def who(_platform, _teams, true), do: "only you can open it"
  def who(:platform, [_ | _] = teams, false), do: "everyone on #{and_list(teams)} can open it"
  def who(:platform, _none, false), do: "your team can open it"

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
    do: "This computer's Troupe app isn't running yet. Start it, and this switches on by itself."
end
