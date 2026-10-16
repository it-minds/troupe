defmodule Troupe.Plane.Bundles.Effective do
  @moduledoc """
  The one bundle a profile has in effect, and the MCP servers its resource says.

  A profile follows a channel, and a profile that extends another follows its parent's
  where it names none. Over a profile, from the one that extends nothing down, are its
  chain's channels' bundles and each profile's own MCP servers, the ones its administrator
  wrote into its spec. Its pods load one bundle: those composed, layer by layer. Where that
  is more than one channel's document as it is, the plane publishes the result as a version
  of a channel of the profile's own (`channel/1`), so everything that follows a profile's
  channel (the push, the pin a session records, `bundle.fetch` by hash, adoption) works on
  it as on any other, and the worker still fetches, checks and loads one document by one
  hash. The resource's `mcpServers` are the same list, so the reach and identity checks
  read what the pods load, and a publish composes it again rather than overwriting a
  profile's own.

  ## The layers

  For each profile in the chain, in order: its channel, the first time the chain follows
  it, and then the servers it wrote itself. A channel with nothing published is a layer with
  nothing in it. A chain on one channel whose profiles wrote no servers has that channel's
  bundle as it is, and needs no channel of its own.

  ## The rules

  Agents, skills, MCP servers and ACP agents are **added** by name: the layers above, then
  this layer's that they lack. An entry with a name a layer above has replaces it only where
  it says `"override": true` (an agent may say it in its frontmatter instead, as it does to
  replace a built-in); otherwise the one above is kept and the clash is reported. For a
  channel the flag is in its document, so a publish of that channel carries it again with
  the entry; for a profile's own server it is on the server in the spec. A layer cannot take
  an entry away: if a team should have less, the standard is too wide.

  ## What is published

  The composed document is checked as any publish is and published on the profile's own
  channel only when its hash differs from that channel's current version: a publish to a
  channel in the chain that changes nothing in effect makes no new version and tells no pod
  anything. The flag goes from every entry in it: the document is what is in effect, and
  replaces nothing.
  """

  alias Troupe.Plane.Bundles
  alias Troupe.Protocol.AgentDefinition
  alias Troupe.Protocol.Bundle, as: Document

  @prefix "profile:"

  @kinds ~w(agents skills mcp_servers acp_agents)

  @words %{
    "agents" => "agent",
    "skills" => "skill",
    "mcp_servers" => "MCP server",
    "acp_agents" => "ACP agent"
  }

  @typedoc "A channel the chain follows, or the servers a profile wrote, each under its profile."
  @type layer ::
          %{profile: String.t(), channel: String.t()} | %{profile: String.t(), servers: [map()]}
  @type entry :: %{
          kind: String.t(),
          name: String.t(),
          from: String.t(),
          channel: String.t() | nil
        }
  @type composed :: %{
          layers: [layer()],
          own?: boolean(),
          content: map() | nil,
          hash: String.t() | nil,
          servers: [map()],
          entries: [entry()],
          problems: [String.t()]
        }

  @doc "The channel the plane publishes a profile's composed bundle on."
  @spec channel(String.t()) :: String.t()
  def channel(profile), do: @prefix <> profile

  @doc "Whether a channel is one the plane writes for a profile, which nobody publishes to."
  @spec reserved?(term()) :: boolean()
  def reserved?(channel) when is_binary(channel), do: String.starts_with?(channel, @prefix)
  def reserved?(_channel), do: false

  @doc """
  The layers of a chain: `[{profile, channel, servers}]` from the one that extends nothing
  down, each profile with the channel it follows in effect and the MCP servers it wrote. Each
  channel is a layer once, under the first profile that follows it; a profile's servers are
  a layer after its channel's, where it wrote any.
  """
  @spec layers([{String.t(), String.t(), [map()]}]) :: [layer()]
  def layers(chain) do
    {layers, _seen} =
      Enum.reduce(chain, {[], MapSet.new()}, fn {profile, channel, servers}, {layers, seen} ->
        channels =
          if MapSet.member?(seen, channel), do: [], else: [%{profile: profile, channel: channel}]

        own = if servers == [], do: [], else: [%{profile: profile, servers: servers}]
        {layers ++ channels ++ own, MapSet.put(seen, channel)}
      end)

    layers
  end

  @doc "The channels among a chain's layers, in order."
  @spec channels([layer()]) :: [String.t()]
  def channels(layers), do: for(%{channel: channel} <- layers, do: channel)

  @doc """
  Whether a chain's layers need a bundle composed for them: more than one channel, or a
  profile's own servers. Otherwise its pods load its one channel's bundle as it is.
  """
  @spec composed?([layer()]) :: boolean()
  def composed?(layers) do
    length(channels(layers)) > 1 or Enum.any?(layers, &Map.has_key?(&1, :servers))
  end

  @doc """
  Compose the current bundles and the own servers of a chain's layers. `content` is `nil`
  where no layer has anything, which is a profile with no bundle in effect, as a channel
  with nothing published is. `servers` is the resource's `mcpServers`: a channel's in the
  resource's shape, a profile's own as it wrote them.
  """
  @spec compose([layer()]) :: composed()
  def compose(layers) do
    documents =
      for layer <- layers, content = content_of(layer), not is_nil(content), do: {layer, content}

    own? = Enum.any?(layers, &Map.has_key?(&1, :servers))

    case documents do
      [] ->
        %{
          layers: layers,
          own?: own?,
          content: nil,
          hash: nil,
          servers: [],
          entries: [],
          problems: []
        }

      _some ->
        start = {Map.new(@kinds, &{&1, []}), %{}, []}

        {lists, from, problems} =
          Enum.reduce(documents, start, fn {layer, content}, acc -> lay(acc, layer, content) end)

        content =
          lists
          |> Map.new(fn {kind, entries} -> {kind, Enum.map(entries, &strip/1)} end)
          |> Map.put("schema", Document.schema())

        sources = for kind <- @kinds, entry <- content[kind], do: from[{kind, entry["name"]}]

        %{
          layers: layers,
          own?: own?,
          content: content,
          hash: Document.hash(content),
          servers: for(%{kind: "mcp_servers"} = source <- sources, do: spec_server(source)),
          entries: Enum.map(sources, &Map.drop(&1, [:spec])),
          problems: problems ++ invalid(content)
        }
    end
  end

  defp content_of(%{channel: channel}) do
    case Bundles.current(channel) do
      nil -> nil
      bundle -> bundle.content
    end
  end

  defp content_of(%{servers: servers}),
    do: %{"mcp_servers" => Enum.map(servers, &Map.put(document_server(&1), "spec", &1))}

  # A composition a worker would refuse is said, not published: a profile's own server
  # with a URL a bundle may not have, say.
  defp invalid(content) do
    case Bundles.validate(content) do
      {:ok, _parsed} -> []
      {:error, {:invalid_bundle, messages}} -> ["the bundle in effect is not valid: " | messages]
    end
  end

  # One layer over what is above it, kind by kind. A schema-0 document is only the MCP
  # servers it ever had.
  defp lay(acc, layer, content) do
    Enum.reduce(@kinds, acc, fn kind, acc ->
      entries = for %{"name" => name} = entry <- list(content[kind]), is_binary(name), do: entry
      Enum.reduce(entries, acc, &add(kind, &1, layer, &2))
    end)
  end

  defp add(kind, %{"name" => name} = entry, layer, {lists, from, problems}) do
    above = lists[kind]

    source = %{
      kind: kind,
      name: name,
      from: layer.profile,
      channel: Map.get(layer, :channel),
      spec: entry["spec"]
    }

    entry = Map.delete(entry, "spec")

    existing = Enum.find(above, &(&1["name"] == name))

    cond do
      is_nil(existing) ->
        {Map.put(lists, kind, above ++ [entry]), Map.put(from, {kind, name}, source), problems}

      overrides?(kind, entry) ->
        replaced = Enum.map(above, &replace_named(&1, name, entry))
        {Map.put(lists, kind, replaced), Map.put(from, {kind, name}, source), problems}

      strip(existing) == strip(entry) ->
        {lists, from, problems}

      true ->
        {lists, from, problems ++ [clash(kind, name, layer, from[{kind, name}].from)]}
    end
  end

  defp replace_named(%{"name" => name}, name, entry), do: entry
  defp replace_named(other, _name, _entry), do: other

  defp clash(kind, name, %{channel: channel, profile: profile}, theirs) do
    "#{profile}'s #{@words[kind]} #{name} (on #{channel}) has the name of one #{theirs} " <>
      "gives it, and #{theirs}'s is kept: say override: true on it in #{channel}'s bundle " <>
      "to replace it"
  end

  defp clash(kind, name, %{profile: profile}, theirs) do
    "#{profile}'s #{@words[kind]} #{name} has the name of one #{theirs} gives it, and " <>
      "#{theirs}'s is kept: say override: true on #{profile}'s to replace it"
  end

  defp overrides?(_kind, %{"override" => true}), do: true

  defp overrides?("agents", %{"name" => name, "definition" => text}) when is_binary(text) do
    case AgentDefinition.parse(name, text) do
      {:ok, parsed} -> parsed.override
      {:error, _reason} -> false
    end
  end

  defp overrides?(_kind, _entry), do: false

  defp strip(entry), do: Map.delete(entry, "override")

  # The resource's entry for a server: a profile's own as it wrote it, and a channel's as
  # the projection of its bundle writes it.
  defp spec_server(%{spec: %{} = written}), do: strip(written)

  defp spec_server(%{name: name, channel: channel}) do
    content = %{"schema" => Document.schema(), "mcp_servers" => [server_in(channel, name)]}

    case Bundles.mcp_servers_of(content) do
      [server] -> server
      _unreadable -> %{"name" => name}
    end
  end

  defp server_in(channel, name) do
    channel
    |> Bundles.current()
    |> Map.fetch!(:content)
    |> Map.get("mcp_servers", [])
    |> Enum.find(&(&1["name"] == name))
    |> strip()
  end

  # A server as a profile's spec says it, as a bundle's document says it: the same server,
  # so a worker given the composed bundle calls it as the resource's own entry describes.
  defp document_server(server) do
    %{"name" => server["name"], "url" => server["url"]}
    |> put_set("header", server["header"])
    |> put_set("timeout_ms", server["timeoutMs"])
    |> put_set("override", server["override"])
    |> credential(server)
  end

  defp credential(entry, %{"credentialMode" => "person"} = server),
    do:
      entry
      |> Map.put("credential_mode", "person")
      |> put_set("credential_ref", server["credentialSlot"])

  defp credential(entry, %{"credentialMode" => "client_credentials"}),
    do: Map.put(entry, "credential_mode", "client_credentials")

  defp credential(entry, server), do: put_set(entry, "credential_ref", server["credentialRef"])

  defp put_set(map, _key, nil), do: map
  defp put_set(map, key, value), do: Map.put(map, key, value)

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
