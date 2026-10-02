defmodule Troupe.WorkerProfile.Reach do
  @moduledoc """
  What a worker without Cilium reaches of a profile's own endpoints, by which rule, and
  which of them it cannot reach at all.

  Without Cilium a worker's NetworkPolicy reaches outside the cluster through the public
  rule, public IPv4 addresses on 443 and 80 (`Troupe.Operator.Resources`), and a host in
  the cluster named as a Service (`*.svc`) through its namespace, on its port. An endpoint
  neither reaches gets a rule of its own (`admission/2`): a name on another port is the
  public rule's addresses on that port, since a NetworkPolicy cannot name a host, and an
  address is that one address on its port. The installation's own OpenBao and object
  store are admitted so (Decision 724), and so are a profile's LLM endpoint, MCP servers
  and `egress.fqdns` entries (Decision 752): `admitted/1` says which rules they need, and
  the operator writes them.

  Except at a loopback or a link-local address, in either family and however it is
  spelled. From a pod, loopback is the pod itself, and link-local is its node's, where a
  cloud's metadata service answers, so no rule admits a profile's endpoint there.
  `unreachable/1` says which, a sentence each, for the plane to refuse such a profile
  where it is set up and for the operator to report one nothing could refuse (Decision
  749). Both read one judgement of each endpoint, so what is refused is exactly what is
  not admitted.

  It judges what the URL says and nothing more. A name is taken at its word: what it
  resolves to is not known where it is typed, and a NetworkPolicy cannot follow it, so a
  name that resolves to a private address is not reached, the public rule leaving those
  ranges out, and nothing here can say so. Such an endpoint is given as its address.

  With Cilium none of this applies: the `CiliumNetworkPolicy` admits each endpoint by name
  or by address, on any port.
  """

  alias Troupe.WorkerProfile, as: Profile

  # What the public rule leaves out of `0.0.0.0/0`, as the operator writes it.
  @excepted ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]

  # What the public rule is open on, and so where a name with no port is reached.
  @public_ports [443, 80]

  # Where no rule admits a profile's endpoint, and what each is called in a sentence.
  @refused [
    {"127.0.0.0/8", "loopback"},
    {"::1/128", "loopback"},
    {"169.254.0.0/16", "link-local"},
    {"fe80::/10", "link-local"}
  ]

  @typedoc "One endpoint a profile names, as `admitted/1` and `unreachable/1` take it."
  @type endpoint ::
          {:llm, String.t()} | {:mcp, String.t(), String.t()} | {:fqdn, String.t()}

  @typedoc """
  A rule the NetworkPolicy adds beyond the public rule: the public rule's addresses
  (`:public`), or one address as a block of one (`"10.20.0.5/32"`), on the ports given.
  """
  @type admission :: {:public | String.t(), [:inet.port_number(), ...]}

  @doc """
  The ranges the worker NetworkPolicy's public rule excepts from `0.0.0.0/0` without
  Cilium: the rule and this judgement read the same list.
  """
  @spec excepted() :: [String.t()]
  def excepted, do: @excepted

  @doc "The ports the public rule is open on, which the rule reads from here as well."
  @spec public_ports() :: [:inet.port_number()]
  def public_ports, do: @public_ports

  @doc """
  The rules a worker without Cilium needs beyond the public rule to reach `host` on
  `ports`: none for a name on 443 and 80, the public rule's addresses on any other port
  for a name, and that one address on all of them for an address, of any kind.

  The installation's own endpoints are admitted by this alone. A profile's are judged
  first, and one at a loopback or link-local address is not admitted (`admitted/1`).
  """
  @spec admission(String.t(), [:inet.port_number()]) :: [admission()]
  def admission(host, ports) do
    case {address(host), ports -- @public_ports} do
      {{:ok, address}, _others} -> [{block(address), ports}]
      {:error, []} -> []
      {:error, others} -> [{:public, others}]
    end
  end

  @doc """
  The rules a worker without Cilium needs to reach the endpoints a profile names, each
  once: the LLM endpoint, each MCP server and each `egress.fqdns` entry, of a profile or
  as a list of `t:endpoint/0`. An endpoint `unreachable/1` names has none, and a `*.svc`
  host none here, since the operator admits it by its namespace.
  """
  @spec admitted(Profile.t() | [endpoint()]) :: [admission()]
  def admitted(%Profile{} = profile), do: profile |> endpoints() |> admitted()

  def admitted(endpoints) when is_list(endpoints) do
    for endpoint <- endpoints,
        {:admitted, admissions} <- [judge(endpoint)],
        admission <- admissions,
        uniq: true,
        do: admission
  end

  @doc """
  The endpoints a profile names that a worker without Cilium cannot reach, a sentence each:
  `"llm.endpoint http://127.0.0.1:4000/v1 is at 127.0.0.1, a loopback address"`.

  Taken as `admitted/1` takes them.
  """
  @spec unreachable(Profile.t() | [endpoint()]) :: [String.t()]
  def unreachable(%Profile{} = profile), do: profile |> endpoints() |> unreachable()

  def unreachable(endpoints) when is_list(endpoints) do
    for endpoint <- endpoints, {:refused, said} <- [judge(endpoint)], uniq: true, do: said
  end

  @doc "A profile's endpoints, as `admitted/1` and `unreachable/1` take them."
  @spec endpoints(Profile.t()) :: [endpoint()]
  def endpoints(%Profile{} = profile) do
    llm = if is_binary(profile.llm_endpoint), do: [{:llm, profile.llm_endpoint}], else: []

    llm ++
      for(
        server <- profile.mcp_servers,
        is_binary(server.url),
        do: {:mcp, server.name, server.url}
      ) ++
      for(entry <- profile.egress_fqdns, is_binary(entry), do: {:fqdn, entry})
  end

  @doc """
  What `unreachable/1` found, why, and what to do, as one message: the console shows it on
  a refusal and the operator writes it on the profile.
  """
  @spec explain([String.t(), ...]) :: String.t()
  def explain(problems) do
    Enum.join(problems, "; ") <>
      ": without Cilium a worker's NetworkPolicy admits a profile's endpoint on its own " <>
      "port, by name or as its one address, but no rule opens a loopback address, which " <>
      "from a pod is the pod itself, or a link-local one, which is the node's and where a " <>
      "cloud's metadata service answers. Give the endpoint as a pod reaches it: by name, " <>
      "at another address, or, for one in the cluster, as its Service " <>
      "(<service>.<namespace>.svc), which is reached on its own port."
  end

  # -- one endpoint -------------------------------------------------------------

  # The rules that admit one endpoint, or the sentence that says why none can.
  defp judge({:llm, url}), do: judge_url("llm.endpoint #{url}", url)
  defp judge({:mcp, name, url}), do: judge_url("MCP server #{name} at #{url}", url)

  # A host, and maybe a port: a profile's own hosts are names, and one written with a port
  # says which it means. One without is reached where a name is, on 443 and 80.
  defp judge({:fqdn, entry}) do
    {host, port} = host_and_port(entry)
    judge_host("egress.fqdns entry #{entry}", host, port)
  end

  defp judge_url(label, url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        if in_cluster?(host), do: {:admitted, []}, else: judge_host(label, host, port)

      _unreadable ->
        {:admitted, []}
    end
  end

  defp judge_host(label, host, port) do
    with {:ok, address} <- address(host),
         {_block, kind} <- Enum.find(@refused, fn {block, _kind} -> within?(address, block) end) do
      {:refused, "#{label} is at #{host}, a #{kind} address"}
    else
      _admitted -> {:admitted, admission(host, if(port, do: [port], else: @public_ports))}
    end
  end

  # Strictly: `:inet.parse_address/1` also takes `10.1` for an address, which nobody
  # writing an endpoint means by it. A v4 address in v6 spelling (`::ffff:169.254.169.254`)
  # is the v4 address it names, which is where a pod's connection to it goes.
  defp address(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, low}} ->
        <<a, b, c, d>> = <<high::16, low::16>>
        {:ok, {a, b, c, d}}

      {:ok, address} ->
        {:ok, address}

      {:error, _name} ->
        :error
    end
  end

  # The one address, as a block of one in its shortest form.
  defp block({_a, _b, _c, _d} = address), do: "#{:inet.ntoa(address)}/32"
  defp block(address), do: "#{:inet.ntoa(address)}/128"

  defp within?(address, block) do
    [network, size] = String.split(block, "/")
    {:ok, network} = :inet.parse_strict_address(String.to_charlist(network))
    size = String.to_integer(size)

    tuple_size(address) == tuple_size(network) and
      prefix(address, size) == prefix(network, size)
  end

  defp prefix(address, size) do
    <<prefix::bitstring-size(^size), _rest::bitstring>> = bits(address)
    prefix
  end

  defp bits({_a, _b, _c, _d} = address),
    do: for(part <- Tuple.to_list(address), into: <<>>, do: <<part>>)

  defp bits(address), do: for(part <- Tuple.to_list(address), into: <<>>, do: <<part::16>>)

  # `openbao.troupe-system.svc`, with or without `.cluster.local`: a Service, which the
  # operator admits by its namespace on its port, as `Troupe.Operator.Resources` reads it.
  defp in_cluster?(host),
    do: match?([_service, _namespace, "svc" | _rest], String.split(host, "."))

  defp host_and_port(entry) do
    with :error <- address(entry),
         {:ok, %URI{host: host, port: port}} when is_binary(host) and host != "" <-
           URI.new("//" <> entry) do
      {host, port}
    else
      _address_or_unreadable -> {entry, nil}
    end
  end
end
