defmodule Troupe.Plane.Fleet.Extends do
  @moduledoc """
  A profile that extends another, resolved into the one flat profile its pods run.

  A profile may name one profile it extends. What its administrator wrote is kept as it
  was written (`own` on the row), and the row's columns and `spec` are the profile in
  effect: the parent's effective profile with this one's laid over it, field by field.
  Placement, the scaler, the policy check and the `WorkerProfile` read those, so nothing
  past the plane knows a profile has a parent: the operator, admission and the worker see
  a flat profile, as they always have.

  ## What a child gets from its parent

  | Field | Rule |
  | --- | --- |
  | `egress.fqdns`, `egress.gitHosts` | **added**: the parent's, then the child's that the parent lacks |
  | `mcpServers`, and the bundle its pods load | **added** by name, composed with the chain's channels' bundles (`Troupe.Plane.Bundles.Effective`). An entry with a name above it replaces that one only with `override: true`; otherwise the one above is kept, and the clash is reported |
  | `max_sessions`, `budget_micros` | **narrow only**: the lower of the two, where either sets one; a child's budget above its parent's is refused where it is written |
  | `personalTools`, `repositoryOverridesBundle`, `github.allowPublic` | **restrict only**: a parent's `forbid` or `false` holds whatever the child says; otherwise the child's, or the parent's |
  | `github.denyPaths` | **added**, as the egress lists are |
  | `github.maxPushes`, `github.maxRuns`, `github.maxAttempts` | **narrow only**, as `max_sessions` is |
  | `permissions.deny`, `permissions.ask`, `permissions.allow` | **added**: a child adds rules and drops none of its parent's; each profile's are its own scope on the pods (`rules/1`), so the strictest holds and no child loosens a parent's `deny` or `ask` |
  | `agents.allow`, `agents.deny` | **narrow only**: the child's `allow` is cut to the parent's where the parent has one (an empty cut stands), its `deny` is added, and a denied name leaves the `allow`, so a child never offers an agent its parent said is not there |
  | `image`, `size_class`, `provisioner`, every `llm` field but `secretRef`, `storage.storageClassName`, `configBundleChannel`, and any other spec field | **replaced** where the child sets it, the parent's where it does not |
  | `llm.secretRef`, `mcpIdentities` | **never inherited**: credentials are each profile's own, in its own namespace |
  | `warm_workers` | **never inherited**: how many of the child's own workers stay up |

  A child cannot take away what its parent has: an empty value is one it did not set. And a
  child's grants are its own, because the resource's `teams` is projected from the grants
  on its own name.

  A chain is at most four profiles long, counting from the one that extends nothing.

  In GitOps mode a repository's manifest names the parent in `spec.extends`
  (`Troupe.Plane.Gitops.Profiles`), and the same resolution is written into the resource's
  status rather than onto its spec. There `sessionsPerPod`, `resources` and `storage.size`
  are the repository's numbers rather than the size class's, so they are **replaced** where
  the child sets them, as any other field is.
  """

  import Ecto.Query

  alias Troupe.Plane.{Bundles, Fleet, Provision, Repo}
  alias Troupe.Plane.Bundles.Effective
  alias Troupe.Plane.Fleet.Profile
  alias Troupe.Protocol.AgentRule

  @max_depth 4

  # What `own` keeps: what a parent can give, as `admin.profile.put` takes it.
  @written ~w(image size_class max_sessions budget_micros warm_workers provisioner spec)

  # What the plane writes into a resource itself, which neither a parent nor a child gives.
  @plane_written ~w(replicas sessionsPerPod resources teams image)

  @top [
    {"image", :replaced},
    {"size_class", :replaced},
    {"provisioner", :replaced},
    {"max_sessions", :narrow},
    {"budget_micros", :narrow},
    {"warm_workers", :own}
  ]

  @spec_rules %{
    "llm" => {:each, %{"secretRef" => :own}},
    "egress" => {:each, %{"fqdns" => :added, "gitHosts" => :added}},
    # The size is the class's, written by the plane; only the storage class is anybody's.
    "storage" => {:each, %{"size" => :dropped}},
    # Composed with the chain's bundles once the chain is merged (`with_bundle/3`).
    "mcpServers" => :dropped,
    "mcpIdentities" => :own,
    "personalTools" => {:restrict, "forbid"},
    "repositoryOverridesBundle" => {:restrict, false},
    # The fix loop's policy on GitHub: a parent's denied paths stay denied, its "no public
    # repositories" holds, and its caps can only be lowered.
    "github" =>
      {:each,
       %{
         "allowPublic" => {:restrict, false},
         "denyPaths" => :added,
         "maxPushes" => :narrow,
         "maxRuns" => :narrow,
         "maxAttempts" => :narrow
       }},
    # Per-tool rules: a child's are added to its parent's, and on the pods each profile's
    # are a scope of their own, the strictest holding (`rules/1`).
    "permissions" => {:each, %{"deny" => :added, "ask" => :added, "allow" => :added}},
    # Which agents exist on the pods: a child can only narrow. Its `allow` is cut to the
    # parent's where the parent has one, and its `deny` adds to the parent's, so no child
    # offers an agent its parent said is not there (`Troupe.Protocol.AgentRule.compose/2`).
    "agents" => :agent_rule,
    # A resource's own words for the parent and the budget, which are the row's columns.
    "extends" => :dropped,
    "budgetMicros" => :dropped
  }

  # In GitOps mode the repository sizes its pods, not the class, so these are its to give.
  @gitops_plane_written ~w(replicas teams image)

  @type resolved :: %{attrs: map(), from: map(), problems: [String.t()], chain: [String.t()]}

  @doc "How many profiles a chain may hold, the one that extends nothing included."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "The fields of a profile a parent can give and `own` keeps."
  @spec written_keys() :: [String.t()]
  def written_keys, do: @written

  @doc """
  A profile as its administrator wrote it: `own` for one that extends another, and the
  row's own columns for one that does not, with the MCP servers it wrote itself rather than
  the ones its bundle gives it.
  """
  @spec written(Profile.t()) :: map()
  def written(%Profile{extends: parent, own: own}) when is_binary(parent), do: own || %{}

  def written(%Profile{} = profile) do
    spec =
      (profile.spec || %{})
      |> Map.delete("mcpServers")
      |> put_new_channel(profile.config_bundle_channel)

    %{
      "image" => profile.image,
      "size_class" => profile.size_class,
      "max_sessions" => profile.max_sessions,
      "budget_micros" => profile.budget_micros,
      "warm_workers" => profile.warm_workers,
      "provisioner" => profile.provisioner,
      "spec" => put_set(spec, "mcpServers", blank_to_nil(own_servers(profile)))
    }
  end

  # A row whose spec names no channel follows its column's, which a row written by the plane
  # alone may hold without the spec saying so; the channel the plane composes onto is not one.
  defp put_new_channel(spec, channel) do
    if presence(spec["configBundleChannel"]) || Effective.reserved?(channel) || is_nil(channel),
      do: spec,
      else: Map.put(spec, "configBundleChannel", channel)
  end

  @doc """
  The MCP servers a profile that extends nothing wrote itself. For a row from before the
  plane kept them apart, the spec's servers its channel's bundle does not name as they are.
  """
  @spec own_servers(Profile.t()) :: [map()]
  def own_servers(%Profile{own_servers: servers}) when is_list(servers), do: servers

  def own_servers(%Profile{} = profile) do
    projected = Bundles.mcp_servers(profile.config_bundle_channel)
    Enum.reject(list((profile.spec || %{})["mcpServers"]), &(&1 in projected))
  end

  # -- the chain ----------------------------------------------------------------

  @doc """
  Whether `name` may extend `parent`: the parent exists, `name` is not among its
  ancestors, and the chain stays within `max_depth/0` with every profile below `name`
  counted. A sentence saying which, where it may not.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, String.t()}
  def check(name, name), do: {:error, "#{name} cannot extend itself"}

  def check(name, parent) do
    case chain(parent) do
      {:error, {:missing, ^parent}} ->
        {:error,
         "#{name} extends #{parent}, which is not a profile on this plane: create #{parent} " <>
           "first, or extend another"}

      {:error, reason} ->
        {:error, sentence(reason)}

      {:ok, above} ->
        fits(name, parent, Enum.map(above, &elem(&1, 0)))
    end
  end

  # `names` is the chain from the top down to the parent: `name` must not be in it, and the
  # chain with `name` and every generation below it must not be longer than allowed.
  defp fits(name, parent, names) do
    below = height(name)
    length = length(names) + 1 + below

    cond do
      name in names ->
        {:error,
         "#{name} cannot extend #{parent}, because #{parent} already extends #{name} " <>
           "(#{Enum.join(names, " → ")}): a profile cannot be its own ancestor"}

      length > @max_depth ->
        under = if below > 0, do: " with the #{below} below it", else: ""
        more = if below > 0, do: " → …", else: ""

        {:error,
         "#{name}#{under} extending #{parent} would make a chain of #{length} profiles " <>
           "(#{Enum.join(names ++ [name], " → ")}#{more}), and a chain is at most " <>
           "#{@max_depth}: extend a profile nearer the one that extends nothing"}

      true ->
        :ok
    end
  end

  @doc """
  The profiles from the one that extends nothing down to `name`, each with what it wrote.

  `overrides` stands in for rows by name, `%{name => %{extends: parent, written: map}}`,
  which is how a write is resolved before it is made.
  """
  @spec chain(String.t(), map()) :: {:ok, [{String.t(), map()}]} | {:error, term()}
  def chain(name, overrides \\ %{}), do: walk(name, overrides, [])

  defp walk(name, overrides, below) do
    cond do
      Enum.any?(below, &(elem(&1, 0) == name)) ->
        {:error, {:cycle, Enum.map(below, &elem(&1, 0))}}

      length(below) >= @max_depth ->
        {:error, {:too_deep, Enum.map(below, &elem(&1, 0))}}

      true ->
        case node(name, overrides) do
          nil ->
            {:error, {:missing, name}}

          %{extends: nil, written: written} ->
            {:ok, [{name, written} | below]}

          %{extends: parent, written: written} ->
            walk(parent, overrides, [{name, written} | below])
        end
    end
  end

  defp node(name, overrides) do
    case Map.fetch(overrides, name) do
      {:ok, node} ->
        %{extends: presence(node[:extends]), written: node[:written] || %{}}

      :error ->
        case Repo.get(Profile, name) do
          nil -> nil
          profile -> %{extends: profile.extends, written: written(profile)}
        end
    end
  end

  defp sentence({:missing, name}),
    do: "#{name} is extended in this chain and is not a profile on this plane any more"

  defp sentence({:cycle, names}),
    do: "#{Enum.join(names, " → ")} extend each other in a circle"

  defp sentence({:too_deep, names}),
    do: "#{Enum.join(names, " → ")} is more than #{@max_depth} profiles long"

  @doc "The profiles that name `name` as the one they extend."
  @spec children(String.t()) :: [String.t()]
  def children(name) do
    Repo.all(from(p in Profile, where: p.extends == ^name, select: p.name, order_by: p.name))
  end

  @doc """
  Every profile below `name`, each after the one it extends: the order in which they are
  resolved again when `name` changes.
  """
  @spec descendants(String.t()) :: [String.t()]
  def descendants(name), do: breadth([name], [], MapSet.new([name]))

  defp breadth([], found, _seen), do: found

  defp breadth([name | rest], found, seen) do
    new = Enum.reject(children(name), &MapSet.member?(seen, &1))
    breadth(rest ++ new, found ++ new, Enum.into(new, seen))
  end

  # How many generations there are below a profile.
  defp height(name) do
    case children(name) do
      [] -> 0
      children -> 1 + Enum.max(Enum.map(children, &height/1))
    end
  end

  # -- resolving ------------------------------------------------------------------

  @doc """
  The profile in effect for `name`: its attributes as the row holds them, where each
  field came from, and what the resolution has to report. `overrides` as for `chain/2`.
  """
  @spec resolve(String.t(), map()) :: {:ok, resolved()} | {:error, String.t()}
  def resolve(name, overrides \\ %{}) do
    case chain(name, overrides) do
      {:ok, chain} ->
        {resolved, channels} =
          Enum.reduce(chain, {empty(), []}, fn {profile, written}, {parent, channels} ->
            merged = merge(parent, written, profile)
            servers = list(map(written["spec"])["mcpServers"])
            {merged, channels ++ [{profile, channel_in(merged), servers}]}
          end)

        names = Enum.map(chain, &elem(&1, 0))
        {:ok, resolved |> Map.put(:chain, names) |> with_bundle(name, channels)}

      {:error, reason} ->
        {:error, sentence(reason)}
    end
  end

  defp channel_in(%{attrs: attrs}), do: presence(attrs["spec"]["configBundleChannel"]) || "stable"

  # The bundle in effect and the servers the resource says. A chain on one channel whose
  # profiles wrote no servers has that channel's bundle as it is; any other has the bundle
  # composed from its channels and its profiles' own servers, on a channel of the profile's
  # own. Either way the resource's servers are the bundle's, each from the profile that gave
  # it, so the resource and the pods' bundle say the same servers, and a publish composes
  # them again rather than overwriting what a profile wrote.
  defp with_bundle(resolved, name, channels) do
    layers = Effective.layers(channels)
    composed = Effective.compose(layers)

    bundle =
      if Effective.composed?(layers) do
        Map.put(composed, :channel, Effective.channel(name))
      else
        [channel] = Effective.channels(layers)
        current = Bundles.current(channel)
        Map.merge(composed, %{channel: channel, content: nil, hash: current && current.hash})
      end

    sources =
      for %{kind: "mcp_servers"} = entry <- composed.entries,
          into: %{},
          do: {entry.name, entry.from}

    %{attrs: attrs, from: from} = resolved
    servers = blank_to_nil(composed.servers)
    spec = put_set(Map.delete(attrs["spec"], "mcpServers"), "mcpServers", servers)
    from = put_set(Map.delete(from, "spec.mcpServers"), "spec.mcpServers", blank_to_nil(sources))

    %{
      resolved
      | attrs: Map.put(attrs, "spec", spec),
        from: from,
        problems: resolved.problems ++ composed.problems
    }
    |> Map.put(:bundle, bundle)
  end

  @doc """
  Write a profile's row again as it now resolves, after something above it changed. Its
  `own` is untouched; only what it has in effect moves, its bundle in effect with it, which
  its pods are told of unless `announce: false`.
  """
  @spec rewrite(String.t(), keyword()) :: {:ok, Profile.t()} | {:error, term()}
  def rewrite(name, opts \\ []) do
    with {:ok, resolved} <- resolve(name),
         {:ok, profile} <- Fleet.put_profile(resolved |> row_attrs() |> Map.put("name", name)) do
      Bundles.publish_effective(profile, opts)
      {:ok, profile}
    end
  end

  @doc """
  Write a profile's servers and bundle in effect again, after a channel in its chain
  published: `rewrite/2` for one that extends another, and for one that extends nothing,
  its servers and channel only, the rest of its row as it is. Its own servers are kept
  apart from then on, where a row from before had them only in its spec.
  """
  @spec refresh(String.t(), keyword()) :: {:ok, Profile.t()} | {:error, term()}
  def refresh(name, opts \\ []) do
    case Fleet.get_profile(name) do
      nil ->
        {:error, :not_found}

      %Profile{extends: parent} when is_binary(parent) ->
        rewrite(name, opts)

      profile ->
        with {:ok, resolved} <- resolve(name),
             {:ok, profile} <- Fleet.put_profile(refreshed(profile, resolved)) do
          Bundles.publish_effective(profile, opts)
          {:ok, profile}
        end
    end
  end

  defp refreshed(profile, %{attrs: attrs, bundle: bundle}) do
    # None is said as none: a publish that leaves the channel with nothing is a change.
    servers = attrs["spec"]["mcpServers"] || []

    %{
      "name" => profile.name,
      "spec" => Map.put(profile.spec || %{}, "mcpServers", servers),
      "config_bundle_channel" => bundle.channel,
      "own_servers" => own_servers(profile)
    }
  end

  @doc """
  What the row of a resolved profile is written with: the fields a parent gives, every one
  of them, so a ceiling the parent took away goes from the child as well, and the channel
  column from the spec it resolved to.
  """
  @spec row_attrs(resolved()) :: map()
  def row_attrs(%{attrs: attrs} = resolved) do
    spec = attrs["spec"] || %{}

    channel =
      case resolved do
        %{bundle: %{channel: channel}} -> channel
        _unresolved -> presence(spec["configBundleChannel"]) || "stable"
      end

    @written
    |> Map.new(&{&1, attrs[&1]})
    |> Map.put("spec", spec)
    |> Map.put("warm_workers", attrs["warm_workers"] || 0)
    |> Map.put("config_bundle_channel", channel)
  end

  @doc """
  Every field of a resolved profile with the profile it came from, one entry per value: a
  list's items and the MCP servers each have their own, since they can come from several.
  """
  @spec fields(resolved()) :: [%{path: String.t(), value: term(), from: String.t()}]
  def fields(%{attrs: attrs, from: from}) do
    from
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      {path, %{} = items} ->
        for value <- ordered(attrs, path, items),
            do: %{path: path, value: value, from: items[value]}

      {path, source} ->
        [%{path: path, value: get_in(attrs, String.split(path, ".")), from: source}]
    end)
  end

  @doc """
  The per-tool rules a profile's sessions obey, each with the profile that wrote it: every
  profile's in its chain, the one that extends nothing first, as
  `%{"action" => "deny", "rule" => "shell(curl)", "profile" => "standard"}`.

  Kept apart by profile rather than merged into one list, because on the pods each
  profile's rules are a scope of their own: of every scope's rules that match a call the
  strictest holds, so a child's `allow` cannot loosen its parent's `ask`, which it would if
  the two were one list and the child's the more specific. A chain the plane cannot walk
  any more gives the profile's own rules alone.
  """
  @spec rules(Profile.t()) :: [map()]
  def rules(%Profile{name: name} = profile) do
    chain =
      case chain(name) do
        {:ok, chain} -> chain
        {:error, _reason} -> [{name, written(profile)}]
      end

    for {from, written} <- chain,
        set = map(map(written["spec"])["permissions"]),
        action <- ~w(deny ask allow),
        rule <- Enum.uniq(list(set[action])),
        is_binary(rule),
        do: %{"action" => action, "rule" => rule, "profile" => from}
  end

  @doc """
  Why what `name` wrote cannot stand under its parent's budget, or `nil`: a profile that
  extends another can only lower its budget, and one written above what it has from above
  is refused rather than quietly lowered, because whoever wrote it believes the profile's
  sessions may spend that much, and they may not. A parent lowered below a child's is not
  refused; the lower is in effect, and the view says whose it is.
  """
  @spec budget_problem(String.t(), map(), resolved()) :: String.t() | nil
  def budget_problem(name, own, %{attrs: attrs, from: from}) do
    wrote = own["budget_micros"]
    ceiling = attrs["budget_micros"]
    source = from["budget_micros"]

    if is_integer(wrote) and is_integer(ceiling) and source != name and ceiling < wrote do
      "#{name} has a monthly budget of #{dollars(ceiling)} from #{source}, and a profile " <>
        "that extends another can only lower its budget: set #{name}'s at or below " <>
        "#{dollars(ceiling)}, or raise #{source}'s"
    end
  end

  defp dollars(micros) do
    cents = div(micros + 5_000, 10_000)

    "$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp ordered(attrs, "spec.mcpServers", _items),
    do: for(server <- attrs["spec"]["mcpServers"] || [], do: server["name"])

  defp ordered(attrs, path, _items), do: get_in(attrs, String.split(path, ".")) || []

  defp empty, do: %{attrs: %{"spec" => %{}}, from: %{}, problems: []}

  @doc """
  Lay what `name` wrote over its parent's resolved profile, by the rules in the moduledoc.
  The one that extends nothing is laid over nothing, and so is all its own.
  """
  @spec merge(map(), map(), String.t()) :: map()
  def merge(parent, written, name) do
    written = written || %{}

    {attrs, from} =
      Enum.reduce(@top, {%{}, %{}}, fn {key, rule}, {attrs, from} ->
        {value, source} =
          field(rule, parent.attrs[key], parent.from[key], written[key], name)

        {put_set(attrs, key, value), put_set(from, key, source)}
      end)

    plane_written = plane_written()
    rules = spec_rules()
    parent_spec = parent.attrs["spec"] || %{}
    own_spec = Map.drop(map(written["spec"]), plane_written)

    keys =
      (Map.keys(parent_spec) ++ Map.keys(own_spec))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in plane_written))

    {spec, from, problems} =
      Enum.reduce(keys, {%{}, from, []}, fn key, {spec, from, problems} ->
        path = "spec." <> key

        {value, from, found} =
          spec_field(
            Map.get(rules, key, :replaced),
            path,
            parent_spec[key],
            own_spec[key],
            parent.from,
            from,
            name
          )

        {put_set(spec, key, value), from, problems ++ found}
      end)

    attrs = Map.put(attrs, "spec", spec)

    %{
      attrs: attrs,
      from: from,
      problems: parent.problems ++ problems ++ key_problems(parent, attrs, from, own_spec, name)
    }
  end

  defp plane_written do
    if Provision.mode() == :gitops, do: @gitops_plane_written, else: @plane_written
  end

  defp spec_rules do
    if Provision.mode() == :gitops,
      do: Map.put(@spec_rules, "storage", {:each, %{}}),
      else: @spec_rules
  end

  defp spec_field({:each, rules}, path, parent, own, parent_from, from, name)
       when (is_map(parent) or is_nil(parent)) and (is_map(own) or is_nil(own)) do
    parent = parent || %{}
    own = own || %{}

    Enum.reduce(Enum.uniq(Map.keys(parent) ++ Map.keys(own)), {%{}, from, []}, fn key,
                                                                                  {value, from,
                                                                                   problems} ->
      sub = path <> "." <> key

      {got, source} =
        field(Map.get(rules, key, :replaced), parent[key], parent_from[sub], own[key], name)

      {put_set(value, key, got), put_set(from, sub, source), problems}
    end)
    |> then(fn {value, from, problems} -> {blank_to_nil(value), from, problems} end)
  end

  defp spec_field({:each, _rules}, path, parent, own, parent_from, from, name),
    do: spec_field(:replaced, path, parent, own, parent_from, from, name)

  # The rule as one value, composed by the module both the plane and the pods read it
  # with: the child's where only it has one, the parent's where only it has, both
  # narrowed into one otherwise, written as a profile could have written it so the row's
  # own check reads it. A child that wrote one is where the composed rule came from.
  defp spec_field(:agent_rule, path, parent, own, parent_from, from, name) do
    {value, source} =
      case {AgentRule.from_json(parent), AgentRule.from_json(own)} do
        {nil, nil} -> {nil, nil}
        {_above, nil} -> {parent, parent_from[path]}
        {above, mine} -> {AgentRule.json(AgentRule.compose(above, mine)), name}
      end

    {value, put_set(from, path, source), []}
  end

  defp spec_field(rule, path, parent, own, parent_from, from, name) do
    {value, source} = field(rule, parent, parent_from[path], own, name)
    {value, put_set(from, path, source), []}
  end

  defp field(:replaced, parent, parent_from, own, name) do
    if set?(own), do: {own, name}, else: {parent, parent_from}
  end

  defp field(:own, _parent, _parent_from, own, name) do
    if set?(own), do: {own, name}, else: {nil, nil}
  end

  defp field(:dropped, _parent, _parent_from, _own, _name), do: {nil, nil}

  defp field(:narrow, parent, parent_from, own, name) do
    cond do
      not set?(own) -> {parent, parent_from}
      not set?(parent) -> {own, name}
      is_integer(own) and is_integer(parent) and parent < own -> {parent, parent_from}
      true -> {own, name}
    end
  end

  defp field({:restrict, held}, parent, parent_from, own, name) do
    cond do
      parent == held -> {held, parent_from}
      set?(own) -> {own, name}
      true -> {parent, parent_from}
    end
  end

  defp field(:added, parent, parent_from, own, name) do
    parent = list(parent)
    sources = parent_from || %{}
    added = Enum.uniq(list(own)) -- parent

    {blank_to_nil(parent ++ added),
     blank_to_nil(Map.merge(Map.take(sources, parent), Map.new(added, &{&1, name})))}
  end

  # A model endpoint the parent gives comes without the parent's key, which is the parent's
  # own: a child that names no key of its own calls it without one.
  defp key_problems(parent, attrs, from, own_spec, name) do
    inherited = from["spec.llm.endpoint"]
    parent_key = get_in(parent.attrs, ["spec", "llm", "secretRef"])

    if is_binary(inherited) and inherited != name and set?(parent_key) and
         not set?(get_in(own_spec, ["llm", "secretRef"])) and
         get_in(attrs, ["spec", "llm", "endpoint"]) do
      [
        "#{name} uses the model endpoint #{inherited} gives it, and the key for it is " <>
          "#{parent.from["spec.llm.secretRef"] || inherited}'s own, which is not inherited: " <>
          "set llm.secretRef to a Secret of #{name}'s, or its pods call the endpoint without one"
      ]
    else
      []
    end
  end

  # -- small things -----------------------------------------------------------------

  defp set?(value), do: value not in [nil, "", [], %{}]

  defp put_set(map, _key, nil), do: map
  defp put_set(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value), do: if(set?(value), do: value, else: nil)

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil
end
