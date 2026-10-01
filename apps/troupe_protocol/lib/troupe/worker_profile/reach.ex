defmodule Troupe.WorkerProfile.Reach do
  @moduledoc """
  Which of a profile's own endpoints its workers cannot reach without Cilium.

  Without Cilium a worker's NetworkPolicy reaches outside the cluster through one rule,
  public IPv4 addresses on 443 and 80 (`Troupe.Operator.Resources`), and a host in the
  cluster named as a Service (`*.svc`) through its namespace, on its port. The
  installation's own OpenBao and object store get rules of their own (Decision 724); a
  profile's endpoints get nothing more. So an LLM gateway on 8443, or an MCP server at an
  address on the office network, is one its workers never reach, and nothing said so until
  a session's first call failed (issue #268).

  This says which, one sentence per endpoint, for the plane to refuse such a profile where
  it is set up and for the operator to report one nothing could refuse (Decision 749).

  It judges what the URL says and nothing more: a port other than 443 and 80, and a host
  that is an address outside what the public rule reaches. A name on 443 is taken at its
  word. A NetworkPolicy cannot name a host, and what a name resolves to is not known where
  it is typed, so a name that resolves to a private address is not reached either, and
  nothing here can say so.

  With Cilium none of this applies: the `CiliumNetworkPolicy` admits each endpoint by name
  or by address, on any port.
  """

  alias Troupe.WorkerProfile, as: Profile

  # What the public rule leaves out of `0.0.0.0/0`, as the operator writes it, and what
  # each is called in a sentence.
  @excepted [
    {"10.0.0.0/8", "private"},
    {"172.16.0.0/12", "private"},
    {"192.168.0.0/16", "private"},
    {"169.254.0.0/16", "link-local"}
  ]

  # Not left out of the rule, and never reached through it either: from a pod it is the
  # pod itself.
  @loopback {"127.0.0.0/8", "loopback"}

  @public_ports [443, 80]

  @typedoc "One endpoint a profile names, as `unreachable/1` takes it."
  @type endpoint ::
          {:llm, String.t()} | {:mcp, String.t(), String.t()} | {:fqdn, String.t()}

  @doc """
  The ranges the worker NetworkPolicy's public rule excepts from `0.0.0.0/0` without
  Cilium: the rule and this check read the same list.
  """
  @spec excepted() :: [String.t()]
  def excepted, do: Enum.map(@excepted, &elem(&1, 0))

  @doc """
  The endpoints a profile names that a worker without Cilium cannot reach, a sentence each:
  `"llm.endpoint https://gateway.example.test:8443/v1 is on port 8443"`.

  The LLM endpoint, each MCP server and each `egress.fqdns` entry, of a profile or as a list
  of `t:endpoint/0`. A `*.svc` host is reached on any port, as the operator admits the LLM
  endpoint and the MCP servers in the cluster by their namespace.
  """
  @spec unreachable(Profile.t() | [endpoint()]) :: [String.t()]
  def unreachable(%Profile{} = profile), do: profile |> endpoints() |> unreachable()

  def unreachable(endpoints) when is_list(endpoints),
    do: endpoints |> Enum.flat_map(&problem/1) |> Enum.uniq()

  @doc "A profile's endpoints, as `unreachable/1` takes them."
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
      ": without Cilium a worker's NetworkPolicy reaches outside the cluster only public " <>
      "IPv4 addresses, on 443 and 80. Set operator.ciliumAvailable on a cluster that runs " <>
      "Cilium, which admits an endpoint by name or address on any port; serve the endpoint " <>
      "at a public address on 443 or 80; or, for one in the cluster, name its Service " <>
      "(<service>.<namespace>.svc), which is reached on its own port."
  end

  # -- one endpoint -------------------------------------------------------------

  defp problem({:llm, url}), do: url_problem("llm.endpoint #{url}", url)
  defp problem({:mcp, name, url}), do: url_problem("MCP server #{name} at #{url}", url)

  # A host, and maybe a port: a profile's own hosts are names, and one written with a port
  # says which it means.
  defp problem({:fqdn, entry}) do
    {host, port} = host_and_port(entry)
    sentence("egress.fqdns entry #{entry}", address(host), port)
  end

  defp url_problem(label, url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        if in_cluster?(host), do: [], else: sentence(label, address(host), port)

      _unreadable ->
        []
    end
  end

  defp sentence(label, address, port) do
    where = where(address)
    port = if port in [nil | @public_ports], do: nil, else: port

    case {where, port} do
      {nil, nil} -> []
      {nil, port} -> ["#{label} is on port #{port}"]
      {where, nil} -> ["#{label} is #{where}"]
      {where, port} -> ["#{label} is #{where}, on port #{port}"]
    end
  end

  # Where an address is, when the public rule does not reach it: `nil` for a name, and for
  # an address it does reach.
  defp where(nil), do: nil

  defp where({text, {_a, _b, _c, _d} = address}) do
    case Enum.find([@loopback | @excepted], fn {block, _kind} -> within?(address, block) end) do
      nil -> nil
      {_block, kind} -> "at #{text}, a #{kind} address"
    end
  end

  # The public rule is an IPv4 block and nothing else, so no IPv6 address is reached.
  defp where({text, _ipv6}), do: "at #{text}, an IPv6 address"

  defp address(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> {host, address}
      {:error, _name} -> nil
    end
  end

  defp within?(address, block) do
    [network, bits] = String.split(block, "/")
    {:ok, network} = :inet.parse_strict_address(String.to_charlist(network))
    host_bits = 32 - String.to_integer(bits)
    Bitwise.bsr(number(address), host_bits) == Bitwise.bsr(number(network), host_bits)
  end

  defp number({a, b, c, d}), do: :binary.decode_unsigned(<<a, b, c, d>>)

  # `openbao.troupe-system.svc`, with or without `.cluster.local`: a Service, which the
  # operator admits by its namespace on its port, as `Troupe.Operator.Resources` reads it.
  defp in_cluster?(host),
    do: match?([_service, _namespace, "svc" | _rest], String.split(host, "."))

  defp host_and_port(entry) do
    with nil <- address(entry),
         {:ok, %URI{host: host, port: port}} when is_binary(host) and host != "" <-
           URI.new("//" <> entry) do
      {host, port}
    else
      _address_or_unreadable -> {entry, nil}
    end
  end
end
