defmodule Troupe.MCP.Address do
  @moduledoc """
  Where the daemon sends a request for a person's own MCP server and for its sign-in
  (Decision 875): to an address its name was resolved to and checked at, and never to a
  link-local address, a cloud's metadata service or the unspecified address, however the
  URL spells it and whatever a name in it resolves to.

  The refused addresses are Decision 856's list, read from
  `Troupe.WorkerProfile.Reach.refusal/1`, so one added there is refused here as well, in
  every spelling `Reach.ipv4/1` reads. Loopback stays, for a server a person runs on their
  own machine, and so do the private ranges (`10/8`, `172.16/12`, `192.168/16`,
  `fc00::/7`), where an intranet's servers are.

  A name is resolved once for each request, in both families, and every address it
  answers is checked: one refused answer among good ones refuses the name. The request
  then goes to the first address, a v4 one when there is one, as the connection would have
  chosen: the URL names that address and the connection asks DNS nothing, so a name that
  answers one address to the check and another a moment later (a rebind with a short
  lifetime, a round robin) is not sent where no check looked. The name goes as the `Host`
  header and as Mint's `:hostname`, which is the TLS server name and the name the
  certificate is checked against. This is how the plane posts a trigger's `notify_url`
  (Decision 866).

  It does that as the request's adapter (`options/0`), so a redirect the request follows
  is resolved and checked again before anything is sent there.

  `:mcp_resolver` in `troupe_protocol`'s application environment, a function of a host
  name to its addresses, stands in for DNS where a test must say what a name answers.
  """

  alias Troupe.WorkerProfile.Reach

  defmodule Refused do
    @moduledoc """
    A request `Troupe.MCP.Address` did not send: the host as the URL names it, the
    address that is refused, what `Troupe.WorkerProfile.Reach.refusal/1` calls it, and
    whether the host is a name that resolved to it rather than the address itself.
    """

    defexception [:host, :address, :kind, resolved: false]

    @type t :: %__MODULE__{
            host: String.t(),
            address: String.t(),
            kind: String.t(),
            resolved: boolean()
          }

    @impl true
    def message(%__MODULE__{} = refused),
      do: "#{refused.host} #{said(refused)}, and is not called"

    @doc """
    What the host is, after its name: `is link-local` for an address written so,
    `resolves to 169.254.169.254, a link-local address` for a name.
    """
    @spec said(t()) :: String.t()
    def said(%__MODULE__{resolved: false, kind: kind}), do: "is #{literal(kind)}"

    def said(%__MODULE__{address: address, kind: kind}),
      do: "resolves to #{address}, #{article(kind)}"

    defp literal("link-local"), do: "link-local"
    defp literal(kind), do: article(kind)

    defp article("unspecified"), do: "the unspecified address"
    defp article(kind), do: "a #{kind} address"
  end

  @doc """
  The Req options that hold a request, and every redirect it follows, to the rule: this
  module as its adapter.
  """
  @spec options() :: keyword()
  def options, do: [adapter: __MODULE__]

  @doc """
  The address a request to `host` goes to: the first one it resolves to, once every one
  has passed. `{:error, %Refused{}}` when one is refused; the lookup's reason when it
  answers nothing. An address written as one is its own answer.
  """
  @spec target(String.t()) :: {:ok, :inet.ip_address()} | {:error, Refused.t() | term()}
  def target(host) when is_binary(host) do
    resolved = parse(host) == :error

    with {:ok, [first | _rest] = addresses} <- addresses(host) do
      case Enum.find_value(addresses, &refused(host, &1, resolved)) do
        nil -> {:ok, first}
        refused -> {:error, refused}
      end
    end
  end

  # Loopback is a person's own machine, where their server may run: allowed, as Decision
  # 741 has it. The rest of Decision 856's list is refused.
  defp refused(host, address, resolved) do
    case Reach.refusal(address) do
      kind when kind in [nil, "loopback"] ->
        nil

      kind ->
        %Refused{
          host: host,
          address: to_string(:inet.ntoa(address)),
          kind: kind,
          resolved: resolved
        }
    end
  end

  defp addresses(host) do
    case parse(host) do
      {:ok, address} -> {:ok, [address]}
      :error -> resolve(host)
    end
  end

  # What DNS answers for a name, in both families, v4 first. A name that answers in
  # neither is the v4 lookup's reason, which is what a connection would have said.
  defp resolve(host) do
    case Application.get_env(:troupe_protocol, :mcp_resolver) do
      fun when is_function(fun, 1) -> answered(fun.(host))
      _dns -> dns(host)
    end
  end

  defp answered([_ | _] = addresses), do: {:ok, addresses}
  defp answered([]), do: {:error, :nxdomain}
  defp answered({:error, reason}), do: {:error, reason}

  defp dns(host) do
    lookups = for family <- [:inet, :inet6], do: :inet.getaddrs(String.to_charlist(host), family)

    case for({:ok, list} <- lookups, address <- list, do: address) do
      [] -> hd(lookups)
      addresses -> {:ok, addresses}
    end
  end

  # As a connection reads an address: `:inet.parse_address/1` takes the older v4
  # spellings (`2852039166`) too, and a request goes to the address they name.
  defp parse(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _name} -> :error
    end
  end

  # -- the adapter ---------------------------------------------------------------

  @doc false
  # Req's adapter: the request goes to the address `target/1` gave, through Req's own
  # Finch adapter, or is not sent. What comes back is paired with the request as it was,
  # named, so a redirect is read against the name and comes back here to be checked.
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{url: %URI{host: host}} = request) do
    case target(host) do
      {:ok, address} ->
        {_pinned, result} = request |> pin(address) |> Req.Finch.run()
        {request, result}

      {:error, %Refused{} = refused} ->
        {request, refused}

      {:error, reason} ->
        {request, %Req.TransportError{reason: reason}}
    end
  end

  # The URL names the address that was checked, so the connection asks DNS nothing; a
  # literal in an older spelling is written as the address it was read as. A name still
  # goes as the `Host` header, the TLS server name and the name the certificate is
  # checked against.
  defp pin(
         %Req.Request{url: %URI{host: host, scheme: scheme, port: port} = url} = request,
         address
       ) do
    request = %{request | url: %{url | host: to_string(:inet.ntoa(address))}}

    case parse(host) do
      {:ok, _literal} ->
        request

      :error ->
        connect = Req.Request.get_option(request, :connect_options, [])

        request
        |> Req.Request.put_header(
          "host",
          if(port == URI.default_port(scheme), do: host, else: "#{host}:#{port}")
        )
        |> Req.Request.put_option(:connect_options, Keyword.put(connect, :hostname, host))
    end
  end
end
