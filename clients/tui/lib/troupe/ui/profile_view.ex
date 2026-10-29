defmodule Troupe.UI.ProfileView do
  @moduledoc """
  What a profile gives a session, in words: the one-line summary `/profiles` lists each
  profile with, and the page `/profile <name>` and `troupe profiles <name>` show, in six
  groups in reading order — Agents, Tools, Model, Reach, Limits, Who.

  The words are said once, here, so the terminal's frame and the plain lines of the
  command line and headless mode cannot drift apart: each line is `{kind, text}`, and only
  how a kind is drawn differs (`:group` a heading, `:sub` a heading inside one, `:line`
  plain, `:muted` quieter, `:dimmed` what a session will not have).

  Everything comes from the plane's answer as it is. A field the plane left null is
  unknown, and is said to be (`not said`), never filled in from a default or a guess: a
  page that invented a limit would be believed. Whose access a server or a key runs with
  is said in the person's words — *as you, once you connect it*, *as the profile*, *as the
  profile's own identity* — and why an agent or a server is not there names who left it
  out: the profile, or the team's grant.
  """

  alias Troupe.UI.TUI.Model

  @type kind :: :group | :sub | :line | :muted | :dimmed
  @type line :: {kind(), String.t()}

  @unsaid "not said"

  ## The list

  @doc """
  One profile's summary: `3 agents · severa, sursen · reaches github.com · 2 of 8 sessions`
  — the agents a session may start as, the MCP servers it is offered, the hosts it
  reaches, and the sessions on it now of those it has room for.
  """
  @spec summary(map()) :: String.t()
  def summary(page) do
    [agents_count(page["agents"]), servers(page), reach_words(page), sessions_words(page["limits"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "The list as lines: each profile's name, then its summary."
  @spec list_lines([map()]) :: [line()]
  def list_lines([]),
    do: [{:muted, "No profile you may use: an administrator grants them to your teams."}]

  def list_lines(pages) do
    width = pages |> Enum.map(&String.length(name(&1))) |> Enum.max() |> max(8)
    Enum.map(pages, &{:line, String.pad_trailing(name(&1), width + 2) <> summary(&1)})
  end

  @doc "A profile's name, as the plane said it."
  @spec name(map()) :: String.t()
  def name(page), do: to_string(page["name"] || "?")

  defp agents_count(agents) when is_list(agents), do: count(length(agents), "agent")
  defp agents_count(_unsaid), do: "agents " <> @unsaid

  defp servers(page) do
    case offered(page) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp offered(page) do
    for server <- mcp(page), server["offered"] != false, do: to_string(server["name"])
  end

  defp reach_words(%{"reach" => hosts}) when is_list(hosts) and hosts != [],
    do: "reaches " <> hosts_words(hosts)

  defp reach_words(%{"reach" => []}), do: "reaches no host"
  defp reach_words(_page), do: "reach " <> @unsaid

  defp hosts_words(hosts) when length(hosts) > 3,
    do: Enum.join(Enum.take(hosts, 2), ", ") <> " and #{length(hosts) - 2} more"

  defp hosts_words(hosts), do: Enum.join(hosts, ", ")

  defp sessions_words(%{"active_sessions" => active, "capacity" => capacity})
       when is_integer(active) and is_integer(capacity),
       do: "#{active} of #{capacity} sessions"

  defp sessions_words(_limits), do: "sessions " <> @unsaid

  ## The page

  @doc """
  The page, `width` columns wide (the tools of a server wrap under it): the six groups in
  reading order, each a heading and its lines.
  """
  @spec lines(map(), pos_integer()) :: [line()]
  def lines(page, width \\ 80) do
    width = max(width, 40)

    Enum.concat([
      group("Agents", agents(page)),
      group("Tools", tools(page, width)),
      group("Model", model(page["model"])),
      group("Reach", reach(page["reach"])),
      group("Limits", limits(page["limits"])),
      group("Who", who(page))
    ])
    |> Enum.drop(-1)
  end

  @doc "Lines as plain text, one string each, headings and all."
  @spec plain([line()]) :: [String.t()]
  def plain(lines), do: Enum.map(lines, fn {_kind, text} -> text end)

  defp group(title, lines), do: [{:group, title} | lines] ++ [{:line, ""}]

  # -- Agents ------------------------------------------------------------------

  defp agents(page) do
    offered = List.wrap(page["agents"])
    missing = List.wrap(page["agents_not_here"])

    width =
      (offered ++ missing)
      |> Enum.map(&String.length(to_string(&1["name"])))
      |> Enum.max(fn -> 0 end)

    width = max(width, 10) + 2

    here =
      case offered do
        [] -> [{:muted, "  none: a session here has no agent to start as"}]
        agents -> Enum.map(agents, &agent_line(&1, width))
      end

    not_here =
      case missing do
        [] -> []
        agents -> [{:sub, "  Not here"} | Enum.map(agents, &missing_line(&1, width))]
      end

    here ++ not_here
  end

  defp agent_line(agent, width) do
    description = agent["description"] |> to_string() |> Model.one_line()
    built_in = if agent["from"] == "builtin", do: " (built in)", else: ""

    {:line,
     String.trim_trailing(
       "  " <>
         String.pad_trailing(to_string(agent["name"]), width) <>
         mode(agent["mode"]) <> description <> built_in
     )}
  end

  defp missing_line(agent, width) do
    built_in = if agent["from"] == "builtin", do: " (built in)", else: ""

    {:dimmed,
     "  " <>
       String.pad_trailing(to_string(agent["name"]), width) <>
       mode(agent["mode"]) <> agent_why(agent["why"]) <> built_in}
  end

  defp mode(mode) when is_binary(mode), do: String.pad_trailing(mode, 10)
  defp mode(_unsaid), do: String.pad_trailing("", 10)

  defp agent_why("profile"), do: "the profile leaves it out"
  defp agent_why("grant"), do: "your team's grant leaves it out"
  defp agent_why(_unsaid), do: "not here; why is " <> @unsaid

  # -- Tools -------------------------------------------------------------------

  defp tools(page, width) do
    tools = page["tools"]
    rules = if is_map(tools), do: tools["rules"], else: nil
    rules(rules) ++ servers_lines(mcp(page), width) ++ skills(page["skills"], width)
  end

  defp rules(nil), do: [{:muted, "  rules " <> @unsaid}]

  defp rules([]),
    do: [
      {:muted, "  no rules: no tool is allowed, asked or denied by the profile or the organisation"}
    ]

  defp rules(rules) do
    width =
      rules |> Enum.map(&String.length(rule_target(&1))) |> Enum.max() |> Kernel.+(3) |> max(18)

    Enum.map(rules, fn rule ->
      {:line,
       "  " <>
         String.pad_trailing(to_string(rule["access"] || "?"), 6) <>
         String.pad_trailing(rule_target(rule), width) <> rule_from(rule["from"])}
    end)
  end

  defp rule_target(%{"tool" => tool, "pattern" => pattern})
       when is_binary(pattern) and pattern != "",
       do: "#{tool}(#{pattern})"

  defp rule_target(rule), do: to_string(rule["tool"])

  defp rule_from("profile"), do: "the profile"
  defp rule_from("organisation"), do: "the organisation"
  defp rule_from(_unsaid), do: @unsaid

  defp mcp(page) do
    case page["tools"] do
      %{"mcp" => servers} when is_list(servers) -> servers
      _ -> []
    end
  end

  defp servers_lines([], _width), do: [{:sub, "  MCP servers"}, {:muted, "    none"}]

  defp servers_lines(servers, width) do
    {offered, not_offered} = Enum.split_with(servers, &(&1["offered"] != false))

    [{:sub, "  MCP servers"}] ++
      Enum.flat_map(offered, &server(&1, width)) ++ Enum.map(not_offered, &not_offered/1)
  end

  defp server(server, width) do
    head =
      "    " <>
        Enum.join(
          [
            to_string(server["name"]),
            host(server["host"]),
            access(server["access"]),
            asked(server["permission"])
          ],
          " · "
        )

    [{:line, head} | wrap("tools: ", server_tools(server["tools"]), "      ", width)]
  end

  defp not_offered(server) do
    why =
      if server["why"] == "grant", do: "your team's grant does not offer it", else: "not offered"

    {:dimmed,
     "    " <>
       Enum.join([to_string(server["name"]), host(server["host"]), "not offered: " <> why], " · ")}
  end

  defp host(host) when is_binary(host) and host != "", do: host
  defp host(_unsaid), do: "host " <> @unsaid

  @doc "Whose access a server acts with, in words."
  @spec access(String.t() | nil) :: String.t()
  def access("yours"), do: "as you, once you connect it"
  def access("profile"), do: "as the profile"
  def access("system"), do: "as the profile's own identity"
  def access(_unsaid), do: "whose access is " <> @unsaid

  defp asked("ask"), do: "asked first"
  defp asked("auto"), do: "automatic"
  defp asked(_unsaid), do: "asked or automatic " <> @unsaid

  defp server_tools("all"), do: ["all of its tools"]
  defp server_tools([]), do: ["none"]
  defp server_tools(tools) when is_list(tools), do: Enum.map(tools, &to_string/1)
  defp server_tools(_unsaid), do: [@unsaid]

  defp skills(skills, width) when is_list(skills) and skills != [],
    do: [{:sub, "  Skills"} | wrap("", Enum.map(skills, &skill_name/1), "    ", width)]

  defp skills(_none, _width), do: []

  defp skill_name(%{"name" => name}), do: to_string(name)
  defp skill_name(name), do: to_string(name)

  # Words joined by commas, wrapped at `width`, every row under the first indented alike.
  defp wrap(label, words, indent, width) do
    room = max(width - String.length(indent), 20)

    {rows, last} =
      Enum.reduce(words, {[], label}, fn word, {rows, row} ->
        joined = if row == label, do: row <> word, else: row <> ", " <> word

        if String.length(joined) > room and row != label,
          do: {[row <> "," | rows], word},
          else: {rows, joined}
      end)

    Enum.map(Enum.reverse([last | rows]), &{:muted, indent <> &1})
  end

  # -- Model -------------------------------------------------------------------

  defp model(%{} = model) do
    provider =
      case {model["provider"], model["host"]} do
        {nil, nil} -> @unsaid
        {provider, nil} -> provider
        {nil, host} -> "at " <> host
        {provider, host} -> "#{provider} at #{host}"
      end

    [
      field("model", model["model"]),
      field("small model", model["small_model"]),
      field("provider", provider),
      field("key", key(model["key"]))
    ]
  end

  defp model(_unsaid), do: [{:muted, "  " <> @unsaid}]

  defp key("profile"), do: "the profile's"
  defp key("yours"), do: "your own"
  defp key(_unsaid), do: nil

  # -- Reach -------------------------------------------------------------------

  defp reach(hosts) when is_list(hosts) and hosts != [],
    do: Enum.map(hosts, &{:line, "  " <> to_string(&1)})

  defp reach([]), do: [{:line, "  no host: a session here reaches nothing outside its pod"}]
  defp reach(_unsaid), do: [{:muted, "  " <> @unsaid}]

  # -- Limits ------------------------------------------------------------------

  defp limits(%{} = limits) do
    [
      field("sessions", running(limits)),
      field("to a pod", limits["sessions_per_pod"]),
      field("at most", at_most(limits["max_sessions"])),
      field("budgets", budgets(limits["budgets"]))
    ]
  end

  defp limits(_unsaid), do: [{:muted, "  " <> @unsaid}]

  defp running(%{"active_sessions" => active, "capacity" => capacity})
       when is_integer(active) and is_integer(capacity),
       do: "#{active} running of the #{capacity} there is room for"

  defp running(%{"active_sessions" => active}) when is_integer(active),
    do: "#{active} running; room " <> @unsaid

  defp running(_limits), do: nil

  defp at_most(n) when is_integer(n), do: "#{count(n, "session")} at once"
  defp at_most(_unsaid), do: nil

  defp budgets(%{} = budgets) do
    Enum.map_join(
      [{"profile", "the profile"}, {"team", "your team"}, {"you", "you"}],
      " · ",
      fn {key, who} -> who <> " " <> money(budgets[key]) end
    )
  end

  defp budgets(_unsaid), do: nil

  defp money(micros) when is_integer(micros), do: Model.dollars(micros)
  defp money(_unsaid), do: @unsaid

  # -- Who ---------------------------------------------------------------------

  defp who(page) do
    teams =
      case page["teams"] do
        [_ | _] = teams -> Enum.join(teams, ", ")
        [] -> "none of your teams"
        _ -> nil
      end

    [
      field("team", team_words(page["team"], page["teams"])),
      field("your teams", teams && "#{teams}: those of yours that may use it"),
      field("bundle", bundle(page)),
      field("terms", terms(page["terms"]))
    ]
  end

  # With several teams of the person's that may use it and none named, the plane says no
  # one team: the session runs under the one it is started under.
  defp team_words(team, _teams) when is_binary(team), do: "a session runs under #{team}"

  defp team_words(nil, [_, _ | _]),
    do: "a session runs under the one of your teams it is started under"

  defp team_words(_team, _teams), do: nil

  defp bundle(page) do
    case [
           page["channel"],
           page["bundle_version"] && "v#{page["bundle_version"]}",
           hash(page["bundle_hash"])
         ]
         |> Enum.reject(&is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp hash(hash) when is_binary(hash) and hash != "", do: String.slice(hash, 0, 12)
  defp hash(_none), do: nil

  defp terms(%{} = terms) when map_size(terms) > 0,
    do:
      terms
      |> Enum.sort()
      |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{term_value(value)}" end)

  defp terms(%{}), do: "none"
  defp terms(_unsaid), do: nil

  defp term_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp term_value(value), do: Jason.encode!(value)

  # -- Shared ------------------------------------------------------------------

  defp field(label, nil), do: {:muted, "  " <> String.pad_trailing(label, 13) <> @unsaid}
  defp field(label, value), do: {:line, "  " <> String.pad_trailing(label, 13) <> to_string(value)}

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
