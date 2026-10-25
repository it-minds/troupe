defmodule Troupe.Policy do
  @moduledoc """
  What a `WorkerProfile` is allowed to ask for, and what to say when it asks for more.

  `TroupePolicy` is cluster-scoped and owned by cluster admins. The plane cannot write
  it, which is the whole point: the plane is internet-facing, and the worst a
  compromised one can do is submit profiles that still have to pass this.

  Checked twice, deliberately. A `ValidatingAdmissionPolicy` runs the same rules in CEL
  at admission, so a bad profile never enters the API server and the person who
  submitted it gets an error immediately. These run again in the operator, which is the
  copy that still holds when admission is unavailable, when the policy tightened after
  a profile was already admitted, or when someone edits a resource while the policy CRD
  is absent. Neither check covers the other's case.
  """

  alias Troupe.WorkerProfile, as: Profile

  defstruct allowed_image_repositories: [],
            max_replicas: 10,
            max_sessions_per_pod: 16,
            max_cpu_millis: 4_000,
            max_memory_bytes: 8 * 1024 * 1024 * 1024,
            allowed_egress: [],
            allowed_storage_classes: [],
            org_volume: nil,
            namespace_prefix: "troupe-w-",
            workers_domain: "workers.example.test"

  @type t :: %__MODULE__{}

  @type violation ::
          {:image_not_allowed, String.t()}
          | {:replicas_above_maximum, pos_integer(), pos_integer()}
          | {:sessions_per_pod_above_maximum, pos_integer(), pos_integer()}
          | {:cpu_above_maximum, pos_integer(), pos_integer()}
          | {:memory_above_maximum, pos_integer(), pos_integer()}
          | {:egress_not_allowed, String.t()}
          | {:egress_not_a_pattern, String.t()}
          | {:allowed_egress_not_a_pattern, String.t()}
          | {:storage_class_not_allowed, String.t()}
          | {:org_volume_not_offered, nil}

  @doc "Parse a `TroupePolicy` resource."
  @spec from_resource(map()) :: t()
  def from_resource(resource) do
    spec = Map.get(resource, "spec", %{})

    %__MODULE__{
      allowed_image_repositories: Map.get(spec, "allowedImageRepositories", []),
      max_replicas: Map.get(spec, "maxReplicas", 10),
      max_sessions_per_pod: Map.get(spec, "maxSessionsPerPod", 16),
      max_cpu_millis: cpu_millis(get_in(spec, ["maxResources", "cpu"]) || "4"),
      max_memory_bytes: memory_bytes(get_in(spec, ["maxResources", "memory"]) || "8Gi"),
      allowed_egress: Map.get(spec, "allowedEgress", []),
      allowed_storage_classes: Map.get(spec, "allowedStorageClasses", []),
      org_volume: Map.get(spec, "orgVolume"),
      namespace_prefix: Map.get(spec, "namespacePrefix", "troupe-w-"),
      workers_domain: Map.get(spec, "workersDomain", "workers.example.test")
    }
  end

  @doc """
  Every way a profile exceeds the policy. Empty means it may be created.

  Every violation, not the first: an admin fixing a profile wants the whole list, and
  reporting them one at a time turns one correction into four round trips.
  """
  @spec violations(Profile.t(), t()) :: [violation()]
  def violations(%Profile{} = profile, %__MODULE__{} = policy) do
    List.flatten([
      image_violation(profile, policy),
      replicas_violation(profile, policy),
      sessions_violation(profile, policy),
      resource_violations(profile, policy),
      egress_violations(profile, policy),
      storage_violations(profile, policy),
      org_violation(profile, policy)
    ])
  end

  defp image_violation(profile, policy) do
    if allowed_image?(profile.image, policy.allowed_image_repositories) do
      []
    else
      [{:image_not_allowed, profile.image}]
    end
  end

  # Compared on the repository, with the tag or digest stripped: policy is about where
  # an image comes from, and pinning a version is the profile's business.
  defp allowed_image?(image, allowed) do
    repository = repository_of(image)
    Enum.any?(allowed, &(&1 == repository or String.starts_with?(repository, &1 <> "/")))
  end

  defp repository_of(image) do
    image
    |> String.split("@", parts: 2)
    |> hd()
    |> then(fn without_digest ->
      case String.split(without_digest, ":") do
        [repository] -> repository
        parts -> parts |> Enum.drop(-1) |> Enum.join(":")
      end
    end)
  end

  defp replicas_violation(%Profile{replicas: replicas}, %{max_replicas: max})
       when replicas > max,
       do: [{:replicas_above_maximum, replicas, max}]

  defp replicas_violation(_profile, _policy), do: []

  defp sessions_violation(%Profile{sessions_per_pod: n}, %{max_sessions_per_pod: max})
       when n > max,
       do: [{:sessions_per_pod_above_maximum, n, max}]

  defp sessions_violation(_profile, _policy), do: []

  defp resource_violations(profile, policy) do
    cpu = cpu_millis(get_in(profile.resources, ["limits", "cpu"]) || "0")
    memory = memory_bytes(get_in(profile.resources, ["limits", "memory"]) || "0")

    cpu_violation =
      if cpu > policy.max_cpu_millis,
        do: [{:cpu_above_maximum, cpu, policy.max_cpu_millis}],
        else: []

    memory_violation =
      if memory > policy.max_memory_bytes,
        do: [{:memory_above_maximum, memory, policy.max_memory_bytes}],
        else: []

    cpu_violation ++ memory_violation
  end

  # Every destination the profile asks for has to be covered by a policy pattern. The
  # LLM endpoint and the MCP servers count: a profile that could name any endpoint
  # could send a team's code anywhere.
  #
  # An entry that is not a pattern is refused for what it is, on either side. In the
  # profile, it is refused whatever the policy holds. In the policy, it admits nothing, and
  # every profile is refused naming it until it is taken out: a policy whose author wrote
  # something they took for a pattern says nothing anybody can know, which is what a
  # missing policy says too, and that also admits nothing.
  defp egress_violations(profile, policy) do
    unreadable = Enum.reject(policy.allowed_egress, &pattern?/1)
    {destinations, refused} = Enum.split_with(Profile.egress_destinations(profile), &pattern?/1)
    outside = Enum.reject(destinations, &matches_any?(&1, policy.allowed_egress))

    Enum.map(unreadable, &{:allowed_egress_not_a_pattern, &1}) ++
      Enum.map(refused, &{:egress_not_a_pattern, &1}) ++
      Enum.map(outside, &{:egress_not_allowed, &1})
  end

  @doc """
  Whether an egress entry is a pattern: an exact hostname, or `*.` and a domain, whose star
  is the whole of the first label and the only star there is.

  Nothing else. A bare `*` and `**.example.com` are the two that matter most: the operator
  writes a wildcard as a Cilium `matchPattern`, where a bare `*` is every name and `**.`
  any number of labels. `*.*`, `a.*.example.com`, `*example.com` and `a*.example.com` would
  each mean something the policy check here does not, and a domain with an empty label
  names nothing. A policy's `allowedEgress` and a profile's egress are held to this alike.
  """
  @spec pattern?(String.t()) :: boolean()
  def pattern?("*." <> domain) do
    domain != "" and not String.contains?(domain, "*") and
      domain |> String.split(".") |> Enum.all?(&(&1 != ""))
  end

  def pattern?(entry) when is_binary(entry), do: not String.contains?(entry, "*")
  def pattern?(_entry), do: false

  @doc """
  Whether a hostname is covered by a policy pattern.

  `*.example.com` matches one label, as it does everywhere else that syntax appears —
  `a.example.com` but not `a.b.example.com`, and never the bare domain. A pattern with
  no star is an exact hostname. An entry that is not a pattern (`pattern?/1`) covers
  nothing, and is covered by nothing.

  A profile's own entry may be a wildcard too. It is compared as the string it is, so
  `*.example.com` passes only a policy that carries that same pattern, never one that
  merely covers some of the names it would reach. The operator renders such an entry as
  a Cilium `matchPattern`, whose `*` is also a single label, so what was admitted here
  and what the network allows are the same set of names.

  An entry written `host:port` is its host and its port, compared apart
  (`host_and_port/1`): the host as above, and a pattern with no port covers any port, one
  with a port that port alone. So `api.example.com:8443` passes a policy holding
  `api.example.com` or `*.example.com`, and the operator admits the host on that port, with
  Cilium as without.
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(entry, pattern) do
    {host, port} = host_and_port(entry)
    {covering, only} = host_and_port(pattern)

    pattern?(entry) and pattern?(pattern) and covers?(host, covering) and only in [nil, port]
  end

  @doc """
  An egress entry's host and port, apart: `api.example.com:8443` is
  `{"api.example.com", 8443}`, `[2001:db8::1]:8443` is `{"2001:db8::1", 8443}`, and an
  entry with no port, an IPv6 address among them, is itself and `nil`. A port is one to
  five digits after the one colon, or after the bracket; anything else is not a port, and
  the entry is taken as written. The admission rule reads an entry the same way.
  """
  @spec host_and_port(String.t()) :: {String.t(), :inet.port_number() | nil}
  def host_and_port(entry) when is_binary(entry) do
    with [host, port] <- split_port(entry),
         true <- Regex.match?(~r/\A[0-9]{1,5}\z/, port) do
      {host, String.to_integer(port)}
    else
      _no_port -> {entry, nil}
    end
  end

  defp split_port("[" <> rest), do: :binary.split(rest, "]:")

  defp split_port(entry) do
    case String.split(entry, ":") do
      [_host, _port] = parts -> parts
      _none_or_v6 -> [entry]
    end
  end

  defp covers?(host, "*." <> domain) do
    case String.split(host, ".", parts: 2) do
      [label, ^domain] -> label != ""
      _ -> false
    end
  end

  defp covers?(host, pattern), do: host == pattern

  defp matches_any?(host, patterns), do: Enum.any?(patterns, &matches?(host, &1))

  defp storage_violations(profile, policy) do
    profile.teams
    |> Enum.map(& &1.storage_class)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in policy.allowed_storage_classes))
    |> Enum.map(&{:storage_class_not_allowed, &1})
  end

  defp org_violation(%Profile{org_mount: true}, %__MODULE__{org_volume: nil}) do
    [{:org_volume_not_offered, nil}]
  end

  defp org_violation(_profile, _policy), do: []

  @doc "One violation, in a sentence an admin can act on."
  @spec describe(violation()) :: String.t()
  def describe({:image_not_allowed, image}),
    do: "image #{image} is not from an allowed repository"

  def describe({:replicas_above_maximum, asked, max}),
    do: "replicas #{asked} is above the maximum of #{max}"

  def describe({:sessions_per_pod_above_maximum, asked, max}),
    do: "sessionsPerPod #{asked} is above the maximum of #{max}"

  def describe({:cpu_above_maximum, asked, max}),
    do: "cpu limit #{asked}m is above the maximum of #{max}m"

  def describe({:memory_above_maximum, asked, max}),
    do: "memory limit #{asked} bytes is above the maximum of #{max}"

  def describe({:egress_not_allowed, host}),
    do: "egress to #{host} is outside the allowed patterns"

  def describe({:egress_not_a_pattern, entry}),
    do: "egress entry #{entry} is not a hostname or a one-label wildcard such as *.example.com"

  def describe({:allowed_egress_not_a_pattern, entry}),
    do:
      "the TroupePolicy's allowedEgress entry #{entry} is not a hostname or a one-label " <>
        "wildcard such as *.example.com, and the policy admits no profile until it is removed"

  def describe({:storage_class_not_allowed, class}),
    do: "storage class #{class} is not allowed"

  def describe({:org_volume_not_offered, _}),
    do: "orgMount is set but the policy offers no org volume"

  @doc ~S"""
  Kubernetes CPU quantity as millicores: `"500m"`, `"2"`, `"1.5"`.
  """
  @spec cpu_millis(String.t() | number()) :: non_neg_integer()
  def cpu_millis(value) when is_number(value), do: round(value * 1000)

  def cpu_millis(value) when is_binary(value) do
    case Integer.parse(value) do
      {millis, "m"} -> millis
      {whole, ""} -> whole * 1000
      {_whole, "." <> _} -> value |> String.to_float() |> round_millis()
      _ -> 0
    end
  end

  defp round_millis(float), do: round(float * 1000)

  @doc ~S"""
  Kubernetes memory quantity as bytes: `"512Mi"`, `"2Gi"`, `"1000000"`.
  """
  @spec memory_bytes(String.t() | number()) :: non_neg_integer()
  def memory_bytes(value) when is_number(value), do: round(value)

  def memory_bytes(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      {number, suffix} -> number * multiplier(suffix)
      :error -> 0
    end
  end

  defp multiplier("Ki"), do: 1024
  defp multiplier("Mi"), do: 1024 * 1024
  defp multiplier("Gi"), do: 1024 * 1024 * 1024
  defp multiplier("Ti"), do: 1024 * 1024 * 1024 * 1024
  defp multiplier("K"), do: 1000
  defp multiplier("M"), do: 1_000_000
  defp multiplier("G"), do: 1_000_000_000
  defp multiplier("T"), do: 1_000_000_000_000
  defp multiplier(_), do: 1
end
