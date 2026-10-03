defmodule Troupe.Plane.Reach do
  @moduledoc """
  A profile's own endpoint its pods cannot reach is refused where it is set up (Decision
  749): in `admin.profile.put`, which the profile editor calls, and in publishing the
  bundle that names a channel's MCP servers.

  Which endpoints those are is `Troupe.WorkerProfile.Reach`'s to say, the same sentences
  the operator writes on a profile nothing here could refuse, one a repository holds. Since
  the operator admits an endpoint on its own port, or as its one address (Decision 752),
  they are the ones at a loopback or link-local address, which no rule admits.

  ## With Cilium or without

  The same ones in both modes (Decision 758): without Cilium the NetworkPolicy has no rule
  for them, and with it the `CiliumNetworkPolicy` leaves them out, even where the
  TroupePolicy's `allowedEgress` names them. So the plane does not need to know which
  mode the operator runs in, and a plane run without the chart refuses them as well.

  ## Only pods

  A profile whose workers are machines (`ssh`) has no NetworkPolicy, and a machine reaches
  whatever its own network lets it (Decision 738). So a profile is checked when its
  workers are pods, and a bundle when a channel it is published to has a profile whose
  workers are.
  """

  alias Troupe.Plane.{Bundles, Fleet, Provision}
  alias Troupe.Plane.Fleet.{Profile, Provisioner}
  alias Troupe.Protocol.Bundle, as: Document
  alias Troupe.Protocol.Error
  alias Troupe.WorkerProfile.Reach

  @doc """
  Refuse a profile `admin.profile.put` would save whose pods could not reach an endpoint it
  names, with every such endpoint in a sentence (`unreachable`) and why and what to do
  (`reason`, which the editor shows).

  What the put sets up is checked: its LLM endpoint, its MCP servers, its `egress.fqdns`,
  and the servers its channel's bundle gives its pods. A put without a spec changes none of
  them.
  """
  @spec check(map()) :: :ok | {:error, Error.t()}
  def check(attrs) do
    with %{} = spec <- get(attrs, "spec"),
         true <- pods?(attrs),
         [_ | _] = found <- Reach.unreachable(endpoints(spec)) do
      {:error, Error.new(:invalid_params, %{reason: Reach.explain(found), unreachable: found})}
    else
      _reached -> :ok
    end
  end

  @doc """
  Refuse to publish a bundle naming an MCP server the pods of a profile following `channel`
  could not reach, saying whose pods.
  """
  @spec bundle(String.t(), Document.t()) :: :ok | {:error, {:invalid_bundle, [String.t()]}}
  def bundle(channel, parsed) do
    servers = for server <- Map.get(parsed, :mcp_servers, []), do: {:mcp, server.name, server.url}

    with [_ | _] = pods <- Enum.filter(Bundles.profiles_on(channel), &pods?/1),
         [_ | _] = found <- Reach.unreachable(servers) do
      whose = "The pods of #{Enum.join(pods, ", ")} follow #{channel}, and "
      {:error, {:invalid_bundle, [whose <> Reach.explain(found)]}}
    else
      _reached -> :ok
    end
  end

  # What the put names, and the servers its channel's current bundle names: the pods are
  # handed those with the bundle whatever the spec says, and the resource gets them at the
  # next publish.
  defp endpoints(spec) do
    channel = presence(spec["configBundleChannel"]) || "stable"
    servers = list(spec["mcpServers"]) ++ Bundles.mcp_servers(channel)

    llm =
      case spec["llm"] do
        %{"endpoint" => endpoint} when is_binary(endpoint) and endpoint != "" ->
          [{:llm, endpoint}]

        _none ->
          []
      end

    fqdns =
      case spec["egress"] do
        %{"fqdns" => fqdns} -> for entry <- list(fqdns), is_binary(entry), do: {:fqdn, entry}
        _none -> []
      end

    llm ++
      for(
        %{"url" => url} = server <- servers,
        is_binary(url),
        do: {:mcp, to_string(server["name"]), url}
      ) ++
      fqdns
  end

  # A put names its provisioner or keeps the one the row has; a profile it does not name is
  # Kubernetes's, as `Provisioner.for/1` says.
  defp pods?(%{} = attrs) do
    name = get(attrs, "name")
    row = if is_binary(name), do: Fleet.get_profile(name)
    provisioner = get(attrs, "provisioner") || (row && row.provisioner)
    Provisioner.for(provisioner) == Provisioner.Kubernetes
  end

  defp pods?(name) when is_binary(name) do
    case Fleet.get_profile(name) do
      %Profile{} = profile -> Provision.in_cluster?(profile)
      nil -> false
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))

  defp list(value) when is_list(value), do: value
  defp list(_other), do: []

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_blank), do: nil
end
