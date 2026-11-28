defmodule Troupe.Client.OwnTriggers do
  @moduledoc """
  A person's own triggers in the terminal (root #1235): the ones a yes of theirs to a
  proposal made, which run as their own principal in a team and spend their budget, so are
  theirs to switch off, on again, and remove. `/triggers` lists them, each with whether it
  is on and when it runs next, how its last run went and what a run may spend;
  `/trigger off|on|remove NAME` changes one at the plane, as this person
  (`trigger.own.disable`, `.enable`, `.delete`). Anybody else's trigger is refused by the
  plane, saying whose it is.
  """

  @typedoc "What `/triggers` and `/trigger` ask."
  @type verb :: :list | {:off | :on | :remove, String.t()}

  @doc "What `/trigger` names after the command: `off`, `on` or `remove`, and the trigger."
  @spec parse(String.t()) :: {:ok, verb()} | {:error, String.t()}
  def parse(args) do
    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [word, name] when word in ["off", "on", "remove"] and name != "" ->
        {:ok,
         {Map.fetch!(%{"off" => :off, "on" => :on, "remove" => :remove}, word), String.trim(name)}}

      _ ->
        {:error,
         "/trigger off NAME, /trigger on NAME or /trigger remove NAME; /triggers lists yours"}
    end
  end

  @doc "The method a change is asked as."
  @spec method(:off | :on | :remove) :: String.t()
  def method(:off), do: "trigger.own.disable"
  def method(:on), do: "trigger.own.enable"
  def method(:remove), do: "trigger.own.delete"

  @doc "`/triggers`: one line each, or that there are none."
  @spec list([map()]) :: String.t()
  def list([]),
    do:
      "no triggers of yours: one you turn on with /proposal yes in a session on the platform is listed here"

  def list(triggers) do
    lines = Enum.map(triggers, &("  " <> line(&1)))

    Enum.join(
      [
        "Your triggers; /trigger off NAME switches one off, /trigger remove NAME removes it:"
        | lines
      ],
      "\n"
    )
  end

  @doc "One trigger in a line: name, team, state, its last run and what a run may spend."
  @spec line(map()) :: String.t()
  def line(t) do
    "#{t["name"]} in #{t["team"]}: #{state(t)}; #{last_run(t["last_run"])}; #{budget(t["budget_micros"])}"
  end

  @doc "What a change answers: the trigger as it now is, or that it was removed."
  @spec changed(:off | :on | :remove, map()) :: String.t()
  def changed(:remove, answer),
    do: "#{answer["name"]} of #{answer["team"]} is removed; its runs' sessions stay"

  def changed(_switch, %{"trigger" => t}), do: line(t)

  @doc "Why a change did not go through, in a sentence."
  @spec refused(:off | :on | :remove, String.t()) :: String.t()
  def refused(verb, why) do
    lead = %{off: "not switched off", on: "not switched on", remove: "not removed"}[verb]
    "#{lead}: #{why}"
  end

  @doc "What a plane from before them says to `/triggers` and `/trigger`."
  @spec not_known() :: String.t()
  def not_known,
    do:
      "this plane does not let you change your own triggers yet; a team admin can, on the console's Triggers page"

  @doc "Why a session on this computer has no triggers to list."
  @spec not_here() :: String.t()
  def not_here,
    do: "your triggers are the platform's: /triggers lists them in a session on the platform"

  defp state(%{"enabled" => false}), do: "off"

  defp state(t) do
    every = if t["cron"], do: "on, cron #{t["cron"]} (UTC)", else: "on"
    if t["next_run_at"], do: "#{every}, next #{utc(t["next_run_at"])}", else: every
  end

  @runs %{
    "created" => "starting",
    "running" => "running",
    "waiting" => "waiting for room",
    "done" => "finished",
    "failed" => "failed",
    "skipped" => "skipped"
  }

  defp last_run(nil), do: "not run yet"

  defp last_run(run) do
    how = Map.get(@runs, run["state"], run["state"])
    why = if run["state"] == "skipped" and run["reason"], do: ", #{run["reason"]}", else: ""
    "last ran #{utc(run["fired_at"])}: #{how}#{why}"
  end

  defp budget(micros) when is_integer(micros),
    do: "up to $#{:erlang.float_to_binary(micros / 1_000_000, decimals: 2)} a run, as you"

  defp budget(_micros), do: "as you"

  defp utc(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, at, _offset} -> Calendar.strftime(at, "%a %-d %b %H:%M UTC")
      _ -> iso || "—"
    end
  end
end
