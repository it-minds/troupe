defmodule Troupe.Plane.Settings.Ladder do
  @moduledoc """
  Five rungs, and the rule that a lower one may only narrow.

      deployment  →  platform  →  team  →  profile  →  session

  Settings had two rungs: what the plane was deployed with, and what a platform admin
  stored over it. A team's own values — its idle timeout, its retention, whether its
  members may steer a session — sat beside them rather than under them, which meant a
  team admin could lengthen a retention the platform had shortened and nothing said so.

  ## A lower rung may only narrow

  Narrower is not smaller: it is *less*. For a duration or a retention, fewer; for a
  permission, off. The direction is declared per setting because it is the thing a
  reader gets wrong — `idle_timeout_seconds` narrows downward and `pins_allowed` narrows
  to `false`, and a resolver that guessed would be wrong half the time.

  Two consequences worth stating plainly:

  * A team that *already* holds a wider value stops getting it the moment the platform
    narrows. The stored row is left alone — an administrator who widens the platform
    again should get their team's setting back rather than have had it silently
    rewritten — but what the team runs on is the tighter of the two.
  * A team's attempt to widen is refused rather than clamped, and the refusal quotes the
    ceiling. Clamping would leave an administrator looking at a form that had accepted
    their number and a system that was not using it.

  ## Deny wins from any rung

  A boolean here is a permission, and `false` at any rung is `false` at every rung below
  it. That is `stage-6.md` §2's rule promoted from one table to the whole ladder, and it
  is why `pins_allowed` resolves with `and` rather than by taking the nearest opinion.

  ## Absence means everything

  A rung with no opinion does not participate. Every laddered setting has a deployment
  fallback so there is always at least one opinion; what "absent" means is that the
  platform stored nothing and the team has not been given a value, and then the
  deployment's is what runs.

  ## What this does not cover

  The profile and session rungs are the `WorkerProfile` spec and the entitlement set
  resolved at create, which already narrow and are already recorded in `session_created`.
  They are named in `rungs/0` so the ladder is one list rather than two, and resolved
  where they live.
  """

  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Settings

  # A laddered setting: the platform key, the team's column, and which way narrower runs.
  #
  # `:lower` — a number where less is narrower: a shorter retention, a shorter idle
  # timeout. `:off` — a permission where `false` is narrower.
  @laddered %{
    "default_idle_timeout_seconds" => %{field: :idle_timeout_seconds, narrower: :lower},
    "default_cache_eviction_days" => %{field: :cache_eviction_days, narrower: :lower},
    "default_erase_after_days" => %{field: :erase_after_days, narrower: :lower},
    "pins_allowed" => %{field: :pins_allowed, narrower: :off},
    "members_may_control" => %{field: :members_may_control, narrower: :off}
  }

  # By the team's own column, which is how a `team.update` arrives.
  @by_field Map.new(@laddered, fn {key, spec} -> {spec.field, {key, spec}} end)

  @doc "Every rung, widest first, as a reader should see them listed."
  @spec rungs() :: [atom()]
  def rungs, do: [:deployment, :platform, :team, :profile, :session]

  @doc "Every setting that is decided at more than one rung, by its platform key."
  @spec laddered() :: %{String.t() => map()}
  def laddered, do: @laddered

  @doc "The team column a laddered setting lands in, or `nil`."
  @spec field_for(String.t()) :: atom() | nil
  def field_for(key), do: get_in(@laddered, [key, :field])

  @doc """
  What this setting resolves to here, which rung decided it, and every rung that had an
  opinion.

  The whole point of the view: an administrator looking at a value that is not what they
  set should be able to see who set it instead without reading the code. The losers are
  in the answer, not only the winner — "30 days" tells you nothing about why your 365
  is not in force.
  """
  @spec effective(String.t(), Team.t() | nil) :: map() | nil
  def effective(key, team \\ nil)

  def effective(key, team) when is_map_key(@laddered, key) do
    spec = @laddered[key]
    opinions = opinions(key, spec, team)
    {rung, value} = decide(spec, opinions)

    %{
      key: key,
      # The team's own column, in the answer rather than looked up: a console is an admin
      # API client and gets no private access to this module, so everything it needs to
      # render a row has to be in the row.
      field: spec.field,
      value: value,
      decided_by: rung,
      # What a team may not go past. The tighter of the two rungs above it, which is the
      # number a refusal quotes.
      ceiling: ceiling(spec, opinions),
      opinions: opinions
    }
  end

  def effective(_key, _team), do: nil

  @doc """
  The team with every laddered field replaced by what the ladder resolves.

  What anything that *acts* on one of these values reads, rather than the column. The
  row is left alone: a team that holds a wider value than the platform allows should
  find its own setting where it left it when the platform widens again, and a resolver
  that wrote the tighter value back would have destroyed the administrator's intent to
  save itself a lookup.
  """
  @spec resolve(Team.t() | nil) :: Team.t() | nil
  def resolve(nil), do: nil

  def resolve(%Team{} = team) do
    Enum.reduce(@laddered, team, fn {key, spec}, acc ->
      %{value: value} = effective(key, team)
      Map.put(acc, spec.field, value)
    end)
  end

  @doc "Every laddered setting, resolved for this team."
  @spec all(Team.t() | nil) :: [map()]
  def all(team \\ nil) do
    @laddered |> Map.keys() |> Enum.sort() |> Enum.map(&effective(&1, team))
  end

  @doc """
  Whether a team may be given these values, and what refuses if not.

  Called before the changeset, so a widening attempt is refused with the ceiling quoted
  rather than clamped. An administrator whose form accepted a number the system is not
  using has been told a lie by a system that knew better.
  """
  @spec check(Team.t() | nil, map()) :: :ok | {:error, map()}
  def check(_team, attrs) when attrs == %{}, do: :ok

  def check(team, attrs) do
    attrs
    |> Enum.map(fn {field, value} -> {field_of(field), value} end)
    |> Enum.find_value(:ok, fn {field, value} -> widening(team, field, value) end)
  end

  # -- resolution -------------------------------------------------------------

  defp widening(_team, nil, _value), do: nil

  defp widening(team, field, value) do
    {key, spec} = @by_field[field]
    value = coerce(spec, value)
    above = ceiling(spec, opinions(key, spec, team))

    if is_nil(value) or is_nil(above) or not wider?(spec, value, above) do
      nil
    else
      {:error, %{key: key, field: field, asked: value, ceiling: above, rung: above_rung(key)}}
    end
  end

  # Which of the two rungs above the team set the ceiling, so the refusal can name it.
  defp above_rung(key) do
    if is_nil(Settings.stored_value(key)), do: :deployment, else: :platform
  end

  defp opinions(key, spec, team) do
    [
      %{rung: :deployment, value: Settings.deployed_value(key)},
      %{rung: :platform, value: Settings.stored_value(key)},
      %{rung: :team, value: team && coerce(spec, Map.get(team, spec.field))}
    ]
    |> Enum.reject(&is_nil(&1.value))
  end

  # The tightest opinion wins, whichever rung it came from. Not the nearest: a team that
  # holds a wider value than the platform allows stops getting it, without its own row
  # being rewritten — an administrator who widens the platform again should find their
  # team's setting where they left it.
  defp decide(spec, opinions) do
    opinions
    |> Enum.min_by(&tightness(spec, &1.value), fn -> %{rung: :deployment, value: nil} end)
    |> then(fn %{rung: rung, value: value} -> {rung, value} end)
  end

  # What the two rungs above the team allow, which is what a team may not go past.
  defp ceiling(spec, opinions) do
    opinions
    |> Enum.filter(&(&1.rung in [:deployment, :platform]))
    |> Enum.min_by(&tightness(spec, &1.value), fn -> nil end)
    |> case do
      nil -> nil
      %{value: value} -> value
    end
  end

  # `false` sorts below `true`, so a permission denied at any rung wins by the same
  # comparison a shorter duration does — which is the point of writing it this way
  # rather than as two resolvers.
  defp tightness(%{narrower: :lower}, value) when is_integer(value), do: value
  defp tightness(%{narrower: :off}, false), do: 0
  defp tightness(%{narrower: :off}, true), do: 1
  defp tightness(_spec, _value), do: :infinity

  defp wider?(spec, value, ceiling), do: tightness(spec, value) > tightness(spec, ceiling)

  defp field_of(field) when is_atom(field), do: if(@by_field[field], do: field)

  defp field_of(field) when is_binary(field) do
    Enum.find(Map.keys(@by_field), &(to_string(&1) == field))
  end

  defp field_of(_field), do: nil

  # A form sends strings and a JSON-RPC caller sends what it likes.
  defp coerce(%{narrower: :lower}, value) when is_integer(value), do: value

  defp coerce(%{narrower: :lower}, value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp coerce(%{narrower: :off}, value) when is_boolean(value), do: value
  defp coerce(%{narrower: :off}, "true"), do: true
  defp coerce(%{narrower: :off}, "on"), do: true
  defp coerce(%{narrower: :off}, "false"), do: false
  defp coerce(_spec, _value), do: nil
end
