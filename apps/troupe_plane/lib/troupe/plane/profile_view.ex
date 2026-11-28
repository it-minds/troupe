defmodule Troupe.Plane.ProfileView do
  @moduledoc """
  What a profile gives a session, for the person about to start one: which agents, which
  skills, which MCP servers with whose access, the per-tool rules, the model, the hosts its
  pods may reach, the limits and the team the session would belong to (`profile.get`); and,
  where the bundle's author wrote them, its `about` lines: what the profile is for, what
  each server is and what each of its tools does.

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

  The offering helpers here (`offering/2`, `offering_at/3`, `listing_entitlements/2`,
  `agent_rule/1`) are the ones the harness uses for `profiles.list`, `session.create` and
  every activation, so the view and the pod cannot drift apart.
  """

  alias Troupe.Plane.{Bundles, Fleet, Identity, Ledger}
  alias Troupe.Plane.Fleet.Extends
  alias Troupe.Plane.GitHub.Policy, as: GitHubPolicy
  alias Troupe.Plane.Identity.{Entitlement, Team, User}
  alias Troupe.Plane.Memory.Proposals
  alias Troupe.Plane.Settings.Ladder
  alias Troupe.Policy
  alias Troupe.Protocol.{AgentCheck, AgentDefinition, AgentRule, Allowance, Error}
  alias Troupe.Protocol.{PermissionRule, Text}
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
  `offering/2` for a session pinned to `version` of the profile's channel: that version's
  agents, skills and servers, not the current bundle's, cut and narrowed the same way.
  `nil` is the current version.
  """
  @spec offering_at(String.t(), integer() | nil, [map()]) :: map()
  def offering_at(profile, version, entitlements) do
    case Fleet.get_profile(profile) do
      nil ->
        Bundles.offering(nil, entitlements)

      %{config_bundle_channel: channel} = row ->
        Bundles.offering_at(channel, version, entitlements, agent_rule(row))
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

  The union is of what each team's grant resolves to, not of the grants' rows: a team with
  no rows gives everything, though it names nothing, and one team's allow list and
  another's deny each give their own names. It comes back as rows, `offering/2`'s input:
  the deny rows that leave exactly those names of what the profile offers.
  """
  @spec listing_entitlements(User.t(), String.t()) :: [map()]
  def listing_entitlements(user, profile) do
    case teams_using(user, profile) do
      [] -> []
      [team] -> Identity.entitlements_for(team, profile)
      teams -> union_of_sets(profile, teams)
    end
  end

  defp union_of_sets(profile, teams) do
    whole = offering(profile, [])
    sets = Enum.map(teams, &offering(profile, Identity.entitlements_for(&1, profile)))

    Enum.flat_map(Entitlement.kinds(), fn kind ->
      kept = sets |> Enum.flat_map(&names(&1, kind)) |> MapSet.new()

      for name <- names(whole, kind),
          not MapSet.member?(kept, name),
          do: %{kind: kind, name: name, mode: "deny"}
    end)
  end

  defp names(offering, "agent"), do: offering.agents
  defp names(offering, "skill"), do: Enum.map(offering.skills, & &1.name)
  defp names(offering, "mcp_server"), do: offering.mcp_servers
  defp names(offering, "acp_agent"), do: Map.get(offering, :acp_agents, [])

  @doc """
  The caller's teams that may use `profile`, by name and sorted: who a session there would
  be open to, which `profiles.list` answers per profile so a client can say so without a
  `profile.get` for each.
  """
  @spec team_names(User.t(), String.t()) :: [String.t()]
  def team_names(user, profile), do: user |> teams_using(profile) |> Enum.map(& &1.name)

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
    definitions = definitions(parsed)
    {here, functions, not_here} = agents(definitions, rule, offered, whole)
    cap = max_tokens(row)
    rules = rules(row)

    %{
      "name" => name,
      "channel" => offered.channel,
      "bundle_version" => offered.bundle_version,
      "bundle_hash" => offered.bundle_hash,
      "team" => team_name(team),
      "teams" => Enum.map(teams, & &1.name),
      "about" => profile_about(parsed),
      "model" => model(row),
      "agents" => Enum.map(here, &own_limits(&1, definitions, cap)),
      "functions" => functions,
      "agents_not_here" => not_here,
      "skills" => Enum.map(offered.skills, & &1.name),
      "skill_details" => skill_details(parsed, offered.skills),
      "tools" => %{"rules" => rules, "mcp" => servers(parsed, offered)},
      "harness_tools" => harness_tools(rules),
      "reach" => reach(name, row),
      "limits" => limits(user, name, row, team, cap),
      "github" => github(name, row, team),
      "personal_tools" => personal_tools(row),
      "memory_proposals" => memory_proposals(row),
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

  # -- skills ----------------------------------------------------------------------

  # The most of a SKILL.md the answer carries; past it the body is cut and says so.
  @skill_body_cap 65_536

  # Each skill the grant leaves, in `skills`' order, with what it does and the body of its
  # SKILL.md after the front matter, which says the name and description already given.
  # A skill with no SKILL.md in the bundle has a `nil` body.
  defp skill_details(parsed, offered) do
    files = for skill <- skills_of(parsed), into: %{}, do: {skill.name, skill.files}

    Enum.map(offered, fn skill ->
      body = files |> Map.get(skill.name, %{}) |> Map.get("SKILL.md") |> skill_body()
      cut? = is_binary(body) and byte_size(body) > @skill_body_cap

      %{
        "name" => skill.name,
        "description" => skill.description,
        "body" => if(cut?, do: Text.cut(body, @skill_body_cap), else: body),
        "truncated" => cut?
      }
    end)
  end

  defp skills_of(%{skills: skills}), do: skills
  defp skills_of(_parsed), do: []

  defp skill_body(text) when is_binary(text) do
    case Regex.run(~r/\A---\r?\n.*?\r?\n---\r?\n?(.*)\z/s, text) do
      [_, rest] -> String.trim_leading(rest)
      nil -> text
    end
  end

  defp skill_body(_text), do: nil

  # -- agents ----------------------------------------------------------------------

  # Every agent the bundle or Troupe has on these pods, sorted into the three lists. The
  # bundle's win over a built-in of the same name, as they do on the pod. On the pod the
  # profile's rule applies to every mode, and the team's set to primaries alone (a subagent
  # is the bundle's own delegation, a function agent the harness's own job), so that is how
  # each is judged here: a primary is here when the offering for this grant names it, not
  # here for the grant when the offering without one does, and not here for the profile
  # when the rule takes it away; a function agent is the harness's to run unless the rule
  # takes it away.
  defp agents(definitions, rule, offered, whole) do
    {here, functions, not_here} =
      definitions
      |> Enum.map(fn {name, definition, from} -> agent_json(name, definition, from) end)
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

  # Each agent's name, its definition and where it is from: the bundle's, then the built-ins
  # it does not replace.
  defp definitions(parsed) do
    own =
      for %{name: name, parsed: definition} <- agents_of(parsed),
          do: {name, definition, "bundle"}

    names = MapSet.new(own, &elem(&1, 0))

    builtins =
      for {name, text} <- Enum.sort(Bundles.builtin_definitions()),
          not MapSet.member?(names, name),
          {:ok, definition} <- [AgentDefinition.parse(name, text)],
          do: {name, definition, "builtin"}

    own ++ builtins
  end

  # An agent's own `max_turns` and `max_tokens`, where its definition sets them, as the pod
  # holds it to them: each lowers the session's and never raises it, so a number above the
  # session's is the session's.
  defp own_limits(%{"name" => name} = agent, definitions, cap) do
    {_name, definition, _from} = List.keyfind(definitions, name, 0)

    agent
    |> put_lower("max_turns", definition.max_turns, Allowance.max_turns())
    |> put_lower("max_tokens", definition.max_tokens, cap)
  end

  defp put_lower(agent, _key, nil, _session), do: agent
  defp put_lower(agent, key, own, session), do: Map.put(agent, key, min(own, session))

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

  # The harness's own tools, each with whether a rule above refuses it whole: a `deny` with
  # no pattern takes the tool away from every call, where one with a pattern takes only the
  # calls it matches, and the tool is still there.
  defp harness_tools(rules) do
    off =
      for %{"access" => "deny", "pattern" => nil, "tool" => tool} <- rules,
          into: MapSet.new(),
          do: tool

    for name <- AgentCheck.harness_tools(),
        do: %{"name" => name, "refused" => MapSet.member?(off, name)}
  end

  # Whether a person may offer a session there their own signed-in tools, as the harness
  # sends it at every activation: `forbid`, or the default `allow`.
  defp personal_tools(%{spec: %{"personalTools" => "forbid"}}), do: "forbid"
  defp personal_tools(_row), do: "allow"

  # Whether a session's agents may propose to a team's or the organisation's memory: not
  # while the plane's setting switches proposals off, nor where the profile in effect says
  # `memoryProposals: false`, as a proposal is refused.
  defp memory_proposals(row) do
    Proposals.enabled?() and not match?(%{spec: %{"memoryProposals" => false}}, row)
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
        "why" => if(offered?, do: nil, else: "grant"),
        "about" => server_about(Map.get(server, :about))
      }
    end
  end

  # The bundle author's words for a reader, as the bundle carries them: the profile's
  # sentence, and a server's subtitle and its line per tool.
  defp profile_about(%{about: %{summary: summary}}), do: %{"summary" => summary}
  defp profile_about(_parsed), do: nil

  defp server_about(%{summary: summary, tools: tools}),
    do: %{"summary" => summary, "tools" => tools}

  defp server_about(_none), do: nil

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

  # The room, counted by the same `Fleet.room/2` as `profiles.list`, and the three ceilings
  # a session's budget is checked against below the platform's: the profile's, the team's
  # and the person's. Zero or none is no ceiling, as the ledger reads it.
  #
  # Then what each agent of the session is held to: the output cap of one model call, the
  # profile's in effect or Troupe's; and the harness's allowance, Troupe's own, since a pod
  # reads no organisation layer and a profile sets none of it. And the team's: how long a
  # session rests before it sleeps, as the ladder resolves it and so as a pod is given it,
  # the platform's own with no team; and the period its budget runs over, the team's only.
  defp limits(user, name, row, team, cap) do
    room = Fleet.room(name, row)
    resolved = Ladder.resolve(team)

    %{
      "sessions_per_pod" => row && row.sessions_per_pod,
      "max_sessions" => row && row.max_sessions,
      "capacity" => room.capacity,
      "active_sessions" => room.active_sessions,
      "max_tokens" => cap,
      "session" => %{
        "max_turns" => Allowance.max_turns(),
        "wall_clock_seconds" => div(Allowance.wall_clock_ms(), 1000),
        "max_input_tokens" => Allowance.max_input_tokens(),
        "max_output_tokens" => Allowance.max_output_tokens(),
        "max_depth" => Allowance.max_depth()
      },
      "idle_seconds" => Ladder.idle_timeout_seconds(team),
      "budgets" => %{
        "profile" => ceiling(row && row.budget_micros),
        "team" => ceiling(team && Ledger.budget_micros(team.id)),
        "you" => ceiling(is_binary(user.subject) && Ledger.person_budget_micros(user.subject)),
        "team_period" => resolved && resolved.budget_period
      },
      # The calls of this profile's sessions this month that nobody priced, which every
      # budget above counts as free; `nil` where there were none.
      "unpriced" => unpriced(name)
    }
  end

  defp unpriced(name) do
    case Ledger.unpriced({:profile, name}) do
      nil ->
        nil

      totals ->
        %{
          "calls" => totals.calls,
          "tokens" => totals.tokens,
          "since" => DateTime.to_iso8601(totals.since)
        }
    end
  end

  # The output cap a pod's every model call asks no more than: the profile's `llm.maxTokens`,
  # its chain's lowest already, or Troupe's where it sets none.
  defp max_tokens(%{spec: %{"llm" => %{"maxTokens" => cap}}}) when is_integer(cap) and cap > 0,
    do: cap

  defp max_tokens(_row), do: Allowance.max_tokens()

  # What a session there may do on GitHub through the plane's App, where the profile gives
  # it any: the permissions its token is narrowed to, and the fix loop's caps, the lower of
  # the profile's and the team's (`nil` for none, attempts one where neither says).
  defp github(name, %{spec: %{"github" => %{} = github}}, team) do
    Map.put(GitHubPolicy.caps(name, team), "permissions", github["permissions"] || %{})
  end

  defp github(_name, _row, _team), do: nil

  defp ceiling(micros) when is_integer(micros) and micros > 0, do: micros
  defp ceiling(_none), do: nil
end
