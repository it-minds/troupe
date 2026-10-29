defmodule Troupe.Plane.ProfileView do
  @moduledoc """
  What a profile gives a session, for the person about to start one: which agents, which
  skills, which MCP servers with whose access, the per-tool rules, the model, the hosts its
  pods may reach, the limits and the team the session would belong to (`profile.get`).

  Composed here from the same pieces the plane hands a pod, and not from anything a client
  could compose for itself: the profile row in effect (its chain resolved), the channel's
  current bundle, the profile's agents rule, the entitlement rows of the grant, the rules
  `Extends.rules/1` sends at every activation, the hosts `WorkerProfile.egress_destinations/1`
  gives the operator for egress, and the ceilings a session's budget is checked against. A
  client that composed it from the bundle would show what the bundle says rather than what
  the plane enforces, and the two differ exactly where it matters: a grant that narrows, a
  rule that takes an agent away, a server whose host the policy refused.

  The agents come in three lists: `agents`, those a session may start as and the subagents
  they delegate to; `functions`, those the harness may run there for a job of their own
  (`answer` for an `AI?` comment, the librarian), which no session runs as its agent; and
  `agents_not_here`. A function agent is in that last list only when the profile's rule
  took it away, since no grant names one.

  It says what a session will not get as well as what it will (`agents_not_here`, an MCP
  server `offered: false`), each with why, because a person who does not find the agent
  they expected should be told whose word took it away rather than left to guess whether
  it exists at all. Nothing secret is in it: an identity at a server is the server and its
  token host, never its client id or its key.

  The offering helpers here (`offering/2`, `listing_entitlements/2`, `agent_rule/1`) are the
  ones the harness uses for `profiles.list`, `session.create` and every activation, so the
  view and the pod cannot drift apart.
  """

  alias Troupe.Plane.{Bundles, Fleet, Identity, Ledger}
  alias Troupe.Plane.Fleet.Extends
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Policy
  alias Troupe.Protocol.{AgentDefinition, AgentRule, Error, PermissionRule}
  alias Troupe.WorkerProfile
  alias Troupe.WorkerProfile.Reach

  @access %{person: "yours", profile: "profile", client_credentials: "system"}

  # -- the offering, shared with the harness ----------------------------------------

  @doc """
  What the channel's current bundle gives a session on this profile, cut to the agents the
  profile says exist on it, then narrowed by the entitlement rows that apply: the profile's
  rule comes first, so a grant can only narrow it and never reach past it. A profile the
  plane has no record of follows no channel and offers the built-ins; no rows narrows
  nothing, which is every grant until somebody opens the editor.
  """
  @spec offering(String.t(), [map()]) :: map()
  def offering(profile, entitlements) do
    case Fleet.get_profile(profile) do
      nil ->
        Bundles.offering(nil, entitlements)

      %{config_bundle_channel: channel} = row ->
        Bundles.offering(channel, entitlements, agent_rule(row))
    end
  end

  @doc """
  The profile's rule on which agents exist on it, composed through what it extends: the row
  holds the profile in effect, so its spec's `agents` is already the chain's. One the row
  holds that cannot be read is no rule, as the put would have refused it.
  """
  @spec agent_rule(map() | nil) :: AgentRule.t() | nil
  def agent_rule(%{spec: %{"agents" => rule}}) do
    case AgentRule.parse(rule) do
      {:ok, rule} -> rule
      {:error, _problems} -> nil
    end
  end

  def agent_rule(_profile), do: nil

  @doc """
  A person's own set for a profile, for *listing*: the union over the teams of theirs that
  may use it, because a person in two teams may use what either gives them and a listing
  that showed an intersection would hide something they can have. A session is narrower on
  purpose: it belongs to one team and gets that team's set.
  """
  @spec listing_entitlements(User.t(), String.t()) :: [map()]
  def listing_entitlements(user, profile) do
    user
    |> teams_using(profile)
    |> Enum.flat_map(&Identity.entitlements_for(&1, profile))
    |> union_of_sets()
  end

  # Union across teams, with "deny wins" applied last: a name denied everywhere stays
  # denied, and a name allowed anywhere is allowed. Rows are compared by kind and name, so
  # two teams allowing the same skill is one row.
  defp union_of_sets(rows) do
    rows
    |> Enum.group_by(&{&1.kind, &1.name})
    |> Enum.map(fn {{kind, name}, group} ->
      mode = if Enum.all?(group, &(&1.mode == "deny")), do: "deny", else: "allow"
      %{kind: kind, name: name, mode: mode}
    end)
  end

  defp teams_using(user, profile) do
    user
    |> Identity.teams_for()
    |> Enum.filter(&Identity.may_use?(user, profile, &1))
    |> Enum.sort_by(& &1.name)
  end

  # -- the view --------------------------------------------------------------------

  @doc """
  The view of `name` for `user`: the one a session of theirs would get.

  The team is the one `session.create` would pick: the only team of theirs that may use the
  profile, or the one named by `team`. With several and none named it is `nil`, as a create
  would ask, and the grant is the union over them, as `profiles.list` shows it. A platform
  admin in no team that may use it gets the profile's own view, no grant narrowing it and
  no team; anybody else is `not_found`, as is a team named that is not one of theirs that
  may use it.
  """
  @spec get(User.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%User{} = user, name, opts \\ []) when is_binary(name) do
    teams = teams_using(user, name)
    row = Fleet.get_profile(name)

    with {:ok, team, entitlements} <- grant(user, name, row, teams, opts) do
      {:ok, compose(user, name, row, team, teams, entitlements)}
    end
  end

  defp grant(_user, name, row, [], opts) do
    if Keyword.get(opts, :platform_admin?, false) and row != nil and is_nil(opts[:team]),
      do: {:ok, nil, []},
      else: not_found(name)
  end

  defp grant(user, name, _row, teams, opts) do
    case {opts[:team], teams} do
      {nil, [team]} ->
        {:ok, team, Identity.entitlements_for(team, name)}

      {nil, _several} ->
        {:ok, nil, listing_entitlements(user, name)}

      {wanted, teams} ->
        case Enum.find(teams, &(&1.name == wanted)) do
          nil -> not_found(name)
          team -> {:ok, team, Identity.entitlements_for(team, name)}
        end
    end
  end

  defp not_found(name),
    do:
      {:error,
       Error.new(:not_found, %{profile: name, reason: "you start no sessions on #{name}"})}

  defp compose(user, name, row, team, teams, entitlements) do
    offered = offering(name, entitlements)
    whole = offering(name, [])
    parsed = bundle_of(row)
    rule = agent_rule(row)
    {here, functions, not_here} = agents(parsed, rule, offered, whole)

    %{
      "name" => name,
      "channel" => offered.channel,
      "bundle_version" => offered.bundle_version,
      "bundle_hash" => offered.bundle_hash,
      "team" => team_name(team),
      "teams" => Enum.map(teams, & &1.name),
      "model" => model(row),
      "agents" => here,
      "functions" => functions,
      "agents_not_here" => not_here,
      "skills" => Enum.map(offered.skills, & &1.name),
      "tools" => %{"rules" => rules(row), "mcp" => servers(parsed, offered)},
      "reach" => reach(name, row),
      "limits" => limits(user, name, row, team),
      # A profile carries no terms of its own: a session's are what its creator sends, and
      # a create that sends none is held to the default approvals alone.
      "terms" => nil
    }
  end

  defp team_name(%Team{name: name}), do: name
  defp team_name(nil), do: nil

  defp bundle_of(%{config_bundle_channel: channel}) when is_binary(channel) do
    case Bundles.current(channel) do
      nil -> nil
      bundle -> Bundles.contents(bundle)
    end
  end

  defp bundle_of(_row), do: nil

  # -- agents ----------------------------------------------------------------------

  # Every agent the bundle or Troupe has on these pods, sorted into the three lists. The
  # bundle's win over a built-in of the same name, as they do on the pod. On the pod the
  # profile's rule applies to every mode, and the team's set to primaries alone (a subagent
  # is the bundle's own delegation, a function agent the harness's own job), so that is how
  # each is judged here: a primary is here when the offering for this grant names it, not
  # here for the grant when the offering without one does, and not here for the profile
  # when the rule takes it away; a function agent is the harness's to run unless the rule
  # takes it away.
  defp agents(parsed, rule, offered, whole) do
    {here, functions, not_here} =
      parsed
      |> all_agents()
      |> Enum.reduce({[], [], []}, fn agent, {here, functions, not_here} ->
        case judge(agent, rule, offered.agents, whole.agents) do
          :here -> {[agent | here], functions, not_here}
          :function -> {here, [Map.delete(agent, "mode") | functions], not_here}
          {:not_here, why} -> {here, functions, [Map.put(agent, "why", why) | not_here]}
          :never -> {here, functions, not_here}
        end
      end)

    {sort_agents(here), Enum.sort_by(functions, & &1["name"]), sort_agents(not_here)}
  end

  defp judge(%{"name" => name, "mode" => mode}, rule, offered, whole) do
    cond do
      not AgentRule.allows?(rule, name) -> {:not_here, "profile"}
      mode == "function" -> :function
      mode != "primary" -> :here
      name in offered -> :here
      name in whole -> {:not_here, "grant"}
      true -> :never
    end
  end

  defp sort_agents(agents), do: Enum.sort_by(agents, &{&1["mode"] != "primary", &1["name"]})

  defp all_agents(parsed) do
    own =
      for %{name: name, parsed: definition} <- agents_of(parsed),
          do: agent_json(name, definition, "bundle")

    names = MapSet.new(own, & &1["name"])

    builtins =
      for {name, text} <- Enum.sort(Bundles.builtin_definitions()),
          not MapSet.member?(names, name),
          {:ok, definition} <- [AgentDefinition.parse(name, text)],
          do: agent_json(name, definition, "builtin")

    own ++ builtins
  end

  defp agents_of(nil), do: []
  defp agents_of(%{agents: agents}), do: agents

  defp agent_json(name, definition, from) do
    %{
      "name" => name,
      "mode" => Atom.to_string(definition.mode),
      "description" => blank_nil(definition.description),
      "from" => from
    }
  end

  defp blank_nil(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp blank_nil(_text), do: nil

  # -- tools -----------------------------------------------------------------------

  # The rules a pod session obeys as the plane hands them over: the profile's and those of
  # every profile it extends. A pod reads no organisation layer, so the organisation's
  # enforced rules for people's own machines are not among them, and a repository's or a
  # person's own are not the plane's to know. A rule a pod could not read is dropped, as the
  # pod drops it.
  defp rules(nil), do: []

  defp rules(row) do
    for %{"action" => action, "rule" => text} <- Extends.rules(row),
        {:ok, rule} <- [PermissionRule.parse(text)],
        do: %{
          "tool" => rule.tool,
          "pattern" => rule.pattern,
          "access" => action,
          "from" => "profile"
        }
  end

  # The bundle's servers, as the pod loads them, each with whose credential a call goes
  # out with and whether this grant leaves it to the session: the pod gives a session the
  # tools of the servers its set names and no others.
  defp servers(parsed, offered) do
    for server <- servers_of(parsed) do
      offered? = server.name in offered.mcp_servers

      %{
        "name" => server.name,
        "host" => WorkerProfile.host_of(server.url),
        "access" => Map.fetch!(@access, server.credential_mode),
        "permission" => Atom.to_string(server.permission),
        "tools" => if(server.tools == :all, do: "all", else: server.tools),
        "offered" => offered?,
        "why" => if(offered?, do: nil, else: "grant")
      }
    end
  end

  defp servers_of(nil), do: []
  defp servers_of(%{mcp_servers: servers}), do: servers

  # -- the model and the network ---------------------------------------------------

  # What the operator hands the pods: the `llm` settings only where there is an endpoint,
  # the provider `openai` where none is named, and a key where the profile names a Secret.
  # Without an endpoint the pods run on the settings their image has, which the plane does
  # not know, so each field is null rather than a guess.
  defp model(row) do
    llm = (row && row.spec["llm"]) || %{}

    case llm["endpoint"] do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        %{
          "model" => llm["model"],
          "small_model" => llm["smallModel"],
          "provider" => llm["provider"] || "openai",
          "host" => WorkerProfile.host_of(endpoint),
          "key" => if(get_in(llm, ["secretRef", "name"]), do: "profile")
        }

      _none ->
        %{"model" => nil, "small_model" => nil, "provider" => nil, "host" => nil, "key" => nil}
    end
  end

  # The hosts outside the cluster the operator lets this profile's pods reach, as it derives
  # them: the declared names and git hosts, the model's endpoint, each MCP server's host and
  # each identity's token host. An entry that is not a pattern, or one the operator refuses
  # to admit (loopback, link-local), gets no rule there and is not listed here.
  defp reach(_name, nil), do: []

  defp reach(name, row) do
    %{"metadata" => %{"name" => name}, "spec" => row.spec || %{}}
    |> WorkerProfile.from_resource()
    |> WorkerProfile.egress_destinations()
    |> Enum.filter(&Policy.pattern?/1)
    |> Enum.reject(fn destination ->
      {host, _port} = Policy.host_and_port(destination)
      Reach.refused?(host)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- limits ----------------------------------------------------------------------

  # The room, as `profiles.list` counts it, and the three ceilings a session's budget is
  # checked against below the platform's: the profile's, the team's and the person's.
  # Zero or none is no ceiling, as the ledger reads it.
  defp limits(user, name, row, team) do
    workers = Fleet.list_workers(name)
    placeable = Enum.reject(workers, & &1.draining)

    %{
      "sessions_per_pod" => row && row.sessions_per_pod,
      "max_sessions" => row && row.max_sessions,
      "capacity" => Enum.sum(Enum.map(placeable, & &1.capacity)),
      "active_sessions" => Enum.sum(Enum.map(workers, & &1.active_sessions)),
      "budgets" => %{
        "profile" => ceiling(row && row.budget_micros),
        "team" => ceiling(team && Ledger.budget_micros(team.id)),
        "you" => ceiling(is_binary(user.subject) && Ledger.person_budget_micros(user.subject))
      }
    }
  end

  defp ceiling(micros) when is_integer(micros) and micros > 0, do: micros
  defp ceiling(_none), do: nil
end
