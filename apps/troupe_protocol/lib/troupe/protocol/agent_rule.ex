defmodule Troupe.Protocol.AgentRule do
  @moduledoc """
  A worker profile's word on which agents exist on it: `spec.agents`, `allow` and `deny`,
  each a list of agent names, built-ins and the bundle's alike.

  Read in two places from one module, so they cannot disagree: the plane applies it to the
  primaries it offers before any team's grant narrows them, and a pod applies it to every
  definition it loads, subagents included. A grant is a team's narrowing of what the
  profile offers; this is the profile saying the agent is not there at all, which is why a
  subagent is dropped here and left alone by the grant.

  `allow` present means only those names exist; `deny` takes names away; a name in both is
  refused rather than read one way or the other; absent is every agent the bundle and
  Troupe give. A profile that extends another has its parent's rule as well as its own and
  can only narrow (`compose/2`): the child's `allow` is cut to the parent's where the parent
  has one, and its `deny` adds. Unknown names are not refused, since a bundle may gain the
  agent later; `unmatched/2` says which names match nothing today.
  """

  @type t :: %{allow: [String.t()] | nil, deny: [String.t()]}

  @doc """
  Read a rule as a profile's spec holds it, or as the activation carries it: `nil` for
  none, and the problems with one that cannot be read, each a sentence naming the field.

  Only the shape is held: a list of non-empty strings under each of `allow` and `deny`,
  nothing else beside them, and no name in both. An empty `allow` is a profile that
  offers no agent, which a child's `allow` cut to its parent's can come to; it is read,
  and `admin.profile.agents` shows nothing offered.
  """
  @spec parse(term()) :: {:ok, t() | nil} | {:error, [String.t()]}
  def parse(nil), do: {:ok, nil}

  def parse(%{} = map) do
    allow = Map.get(map, "allow")
    deny = Map.get(map, "deny")

    problems =
      Enum.flat_map(Map.keys(map), fn
        key when key in ["allow", "deny"] -> []
        key -> ["agents.#{key} is not a field: agents has allow and deny"]
      end) ++
        names_problems("allow", allow) ++ names_problems("deny", deny) ++ both(allow, deny)

    case problems do
      [] -> {:ok, %{allow: allow && Enum.uniq(allow), deny: Enum.uniq(deny || [])}}
      problems -> {:error, problems}
    end
  end

  def parse(other),
    do: {:error, ["agents must be an object with allow and deny lists, not #{inspect(other)}"]}

  @doc "The sentences `parse/1` would refuse a rule with; `[]` for one it reads."
  @spec problems(term()) :: [String.t()]
  def problems(rule) do
    case parse(rule) do
      {:ok, _rule} -> []
      {:error, problems} -> problems
    end
  end

  defp names_problems(_field, nil), do: []

  defp names_problems(field, names) when is_list(names) do
    case Enum.reject(names, &(is_binary(&1) and String.trim(&1) != "")) do
      [] ->
        []

      bad ->
        [
          "agents.#{field} names agents, and #{Enum.map_join(bad, ", ", &inspect/1)} is not a name"
        ]
    end
  end

  defp names_problems(field, other),
    do: ["agents.#{field} must be a list of agent names, not #{inspect(other)}"]

  defp both(allow, deny) when is_list(allow) and is_list(deny) do
    case Enum.filter(allow, &(is_binary(&1) and &1 in deny)) do
      [] ->
        []

      names ->
        ["#{Enum.join(names, ", ")} is in both agents.allow and agents.deny: name it in one"]
    end
  end

  defp both(_allow, _deny), do: []

  @doc """
  Whether an agent of this name exists under the rule. `nil` is no rule, so everything.
  Deny over allow, as a grant's rows are read.
  """
  @spec allows?(t() | nil, String.t()) :: boolean()
  def allows?(nil, _name), do: true

  def allows?(%{allow: allow, deny: deny}, name) do
    name not in deny and (is_nil(allow) or name in allow)
  end

  @doc "The names of `names` the rule keeps, in their order."
  @spec keep([String.t()], t() | nil) :: [String.t()]
  def keep(names, nil), do: names
  def keep(names, rule), do: Enum.filter(names, &allows?(rule, &1))

  @doc """
  The names a rule speaks of that are none of `names`: a bundle that has not been
  published yet, or a typo. Said, not refused.
  """
  @spec unmatched(t() | nil, [String.t()]) :: [String.t()]
  def unmatched(nil, _names), do: []

  def unmatched(%{allow: allow, deny: deny}, names) do
    Enum.reject(Enum.uniq((allow || []) ++ deny), &(&1 in names))
  end

  @doc """
  A child's rule under its parent's: only narrower. The `allow` is the parent's cut to
  the child's where both have one (an empty cut stands: the child named none of what the
  parent allows), the one of them that has one otherwise; the `deny` is both, and a name
  denied leaves the `allow`, so the result reads as a profile could have written it. Two
  `nil`s are no rule.
  """
  @spec compose(t() | nil, t() | nil) :: t() | nil
  def compose(nil, child), do: child
  def compose(parent, nil), do: parent

  def compose(%{allow: above, deny: parent_deny}, %{allow: own, deny: child_deny}) do
    deny = Enum.uniq(parent_deny ++ child_deny)

    allow =
      case {above, own} do
        {nil, own} -> own
        {above, nil} -> above
        {above, own} -> Enum.filter(above, &(&1 in own))
      end

    %{allow: allow && Enum.reject(allow, &(&1 in deny)), deny: deny}
  end

  @doc """
  A rule as a spec holds it and as `session.activate` and `session_created` carry it:
  `deny` always, `allow` only where there is one, since the resource's schema types it as
  a list and a null there is not one.
  """
  @spec json(t() | nil) :: map() | nil
  def json(nil), do: nil
  def json(%{allow: nil, deny: deny}), do: %{"deny" => deny}
  def json(%{allow: allow, deny: deny}), do: %{"allow" => allow, "deny" => deny}

  @doc """
  A rule as the pod reads it off the activation. Forgiving of shape, since the pod can
  only run what it was told: a list that is not one is read as absent, and a name that is
  not a string is skipped.
  """
  @spec from_json(term()) :: t() | nil
  def from_json(%{} = map) do
    allow = Map.get(map, "allow")
    deny = Map.get(map, "deny")

    %{
      allow: if(is_list(allow), do: Enum.filter(allow, &is_binary/1)),
      deny: if(is_list(deny), do: Enum.filter(deny, &is_binary/1), else: [])
    }
  end

  def from_json(_other), do: nil
end
