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
  | `mcpServers` | **added** by name. A child's server with a parent's name replaces it only with `override: true`; otherwise the parent's is kept, and the clash is reported |
  | `max_sessions` | **narrow only**: the lower of the two, where either sets one |
  | `personalTools`, `repositoryOverridesBundle` | **restrict only**: a parent's `forbid` or `false` holds whatever the child says; otherwise the child's, or the parent's |
  | `image`, `size_class`, `provisioner`, every `llm` field but `secretRef`, `storage.storageClassName`, `configBundleChannel`, and any other spec field | **replaced** where the child sets it, the parent's where it does not |
  | `llm.secretRef`, `mcpIdentities` | **never inherited**: credentials are each profile's own, in its own namespace |
  | `warm_workers` | **never inherited**: how many of the child's own workers stay up |

  A child cannot take away what its parent has: an empty value is one it did not set. And a
  child's grants are its own, because the resource's `teams` is projected from the grants
  on its own name.

  A chain is at most four profiles long, counting from the one that extends nothing.
  """

  import Ecto.Query

  alias Troupe.Plane.{Fleet, Repo}
  alias Troupe.Plane.Fleet.Profile

  @max_depth 4

  # What `own` keeps: what a parent can give, as `admin.profile.put` takes it.
  @written ~w(image size_class max_sessions warm_workers provisioner spec)

  # What the plane writes into a resource itself, which neither a parent nor a child gives.
  @plane_written ~w(replicas sessionsPerPod resources teams image)

  @top [
    {"image", :replaced},
    {"size_class", :replaced},
    {"provisioner", :replaced},
    {"max_sessions", :narrow},
    {"warm_workers", :own}
  ]

  @spec_rules %{
    "llm" => {:each, %{"secretRef" => :own}},
    "egress" => {:each, %{"fqdns" => :added, "gitHosts" => :added}},
    # The size is the class's, written by the plane; only the storage class is anybody's.
    "storage" => {:each, %{"size" => :dropped}},
    "mcpServers" => :servers,
    "mcpIdentities" => :own,
    "personalTools" => {:restrict, "forbid"},
    "repositoryOverridesBundle" => {:restrict, false}
  }

  @type resolved :: %{attrs: map(), from: map(), problems: [String.t()], chain: [String.t()]}

  @doc "How many profiles a chain may hold, the one that extends nothing included."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "The fields of a profile a parent can give and `own` keeps."
  @spec written_keys() :: [String.t()]
  def written_keys, do: @written

  @doc """
  A profile as its administrator wrote it: `own` for one that extends another, and the
  row's own columns for one that does not.
  """
  @spec written(Profile.t()) :: map()
  def written(%Profile{extends: parent, own: own}) when is_binary(parent), do: own || %{}

  def written(%Profile{} = profile) do
    %{
      "image" => profile.image,
      "size_class" => profile.size_class,
      "max_sessions" => profile.max_sessions,
      "warm_workers" => profile.warm_workers,
      "provisioner" => profile.provisioner,
      "spec" => profile.spec || %{}
    }
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
        resolved =
          Enum.reduce(chain, empty(), fn {profile, written}, parent ->
            merge(parent, written, profile)
          end)

        {:ok, Map.put(resolved, :chain, Enum.map(chain, &elem(&1, 0)))}

      {:error, reason} ->
        {:error, sentence(reason)}
    end
  end

  @doc """
  Write a profile's row again as it now resolves, after something above it changed. Its
  `own` is untouched; only what it has in effect moves.
  """
  @spec rewrite(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def rewrite(name) do
    with {:ok, resolved} <- resolve(name) do
      Fleet.put_profile(resolved |> row_attrs() |> Map.put("name", name))
    end
  end

  @doc """
  What the row of a resolved profile is written with: the fields a parent gives, every one
  of them, so a ceiling the parent took away goes from the child as well, and the channel
  column from the spec it resolved to.
  """
  @spec row_attrs(resolved()) :: map()
  def row_attrs(%{attrs: attrs}) do
    spec = attrs["spec"] || %{}

    @written
    |> Map.new(&{&1, attrs[&1]})
    |> Map.put("spec", spec)
    |> Map.put("warm_workers", attrs["warm_workers"] || 0)
    |> Map.put("config_bundle_channel", presence(spec["configBundleChannel"]) || "stable")
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

    parent_spec = parent.attrs["spec"] || %{}
    own_spec = Map.drop(map(written["spec"]), @plane_written)

    keys =
      (Map.keys(parent_spec) ++ Map.keys(own_spec))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @plane_written))

    {spec, from, problems} =
      Enum.reduce(keys, {%{}, from, []}, fn key, {spec, from, problems} ->
        path = "spec." <> key

        {value, from, found} =
          spec_field(
            Map.get(@spec_rules, key, :replaced),
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

  defp spec_field(:servers, path, parent, own, parent_from, from, name) do
    {servers, sources, problems} =
      servers(list(parent), parent_from[path] || %{}, list(own), name)

    {blank_to_nil(servers), put_set(from, path, blank_to_nil(sources)), problems}
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

  # The parent's servers, then the child's: one with a parent's name takes its place only
  # when it says `override: true`, which the resource has no field for and does not get.
  defp servers(parent, parent_sources, own, name) do
    names = Enum.map(parent, & &1["name"])
    start = {Enum.map(parent, &strip/1), Map.take(parent_sources, names), []}

    Enum.reduce(own, start, &add_server(&1, &2, MapSet.new(names), parent_sources, name))
  end

  defp add_server(
         %{"name" => server} = entry,
         {kept, sources, problems},
         known,
         parent_sources,
         name
       ) do
    cond do
      not MapSet.member?(known, server) ->
        {kept ++ [strip(entry)], Map.put(sources, server, name), problems}

      entry["override"] == true ->
        {Enum.map(kept, &if(&1["name"] == server, do: strip(entry), else: &1)),
         Map.put(sources, server, name), problems}

      strip(entry) == Enum.find(kept, &(&1["name"] == server)) ->
        {kept, sources, problems}

      true ->
        theirs = parent_sources[server]

        clash =
          "#{name}'s MCP server #{server} has the name of one #{theirs} gives it, and " <>
            "#{theirs}'s is kept: say override: true on #{name}'s to replace it"

        {kept, sources, problems ++ [clash]}
    end
  end

  defp add_server(_unnamed, acc, _known, _parent_sources, _name), do: acc

  defp strip(entry), do: Map.delete(entry, "override")

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
