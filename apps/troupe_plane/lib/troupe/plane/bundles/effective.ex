defmodule Troupe.Plane.Bundles.Effective do
  @moduledoc """
  The one bundle a profile that extends another has in effect.

  A profile follows a channel, and a profile that extends another follows its parent's
  where it names none. One that names a channel of its own has two bundles over it, its
  parent's and its own channel's, and its pods load one: the parent's, with what its own
  channel publishes added. This composes them, layer by layer from the profile that extends
  nothing, and the plane publishes the result as a version of a channel of the profile's
  own (`channel/1`), so everything that follows a profile's channel (the push, the pin a
  session records, `bundle.fetch` by hash, adoption) works on it as on any other, and the
  worker still fetches, checks and loads one document by one hash.

  ## The rules

  Agents, skills, MCP servers and ACP agents are **added** by name: the parent's, then the
  child's the parent lacks. A child's entry with a parent's name replaces it only where it
  says `"override": true` (an agent may say it in its frontmatter instead, as it does to
  replace a built-in); otherwise the parent's is kept and the clash is reported. The flag is
  the child's channel's document's, so a publish of that channel carries it again with the
  entry, and nothing outside the document has to remember it. A child cannot take an entry
  away: if a team should have less, the standard is too wide.

  A layer is a channel, named by the first profile in the chain that follows it. A child
  on its parent's channel adds no layer and has the parent's bundle as it is; it needs no
  channel of its own. A channel with nothing published is a layer with nothing in it.

  ## What is published

  The composed document is checked as any publish is and published on the profile's own
  channel only when its hash differs from that channel's current version: a publish to
  a channel in the chain that changes nothing in effect makes no new version and tells no
  pod anything. The flag goes from every entry in it: the document is what is in effect,
  and replaces nothing.
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

  @type layer :: %{profile: String.t(), channel: String.t()}
  @type entry :: %{kind: String.t(), name: String.t(), from: String.t(), channel: String.t()}
  @type composed :: %{
          layers: [layer()],
          content: map() | nil,
          hash: String.t() | nil,
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
  The layers of a chain: `[{profile, channel}]` from the one that extends nothing down,
  each profile with the channel it follows in effect, reduced to each channel once, under
  the first profile that follows it.
  """
  @spec layers([{String.t(), String.t()}]) :: [layer()]
  def layers(chain) do
    chain
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.map(fn {profile, channel} -> %{profile: profile, channel: channel} end)
  end

  @doc "Whether a chain's layers need a bundle composed for them: more than one channel."
  @spec composed?([layer()]) :: boolean()
  def composed?(layers), do: length(layers) > 1

  @doc """
  Compose the current bundles of a chain's layers. `content` is `nil` where no layer has
  anything published, which is a profile with no bundle in effect, as a channel with
  nothing published is.
  """
  @spec compose([layer()]) :: composed()
  def compose(layers) do
    documents =
      for layer <- layers, bundle = Bundles.current(layer.channel), not is_nil(bundle) do
        {layer, bundle.content}
      end

    case documents do
      [] ->
        %{layers: layers, content: nil, hash: nil, entries: [], problems: []}

      _some ->
        start = {Map.new(@kinds, &{&1, []}), %{}, []}

        {lists, from, problems} =
          Enum.reduce(documents, start, fn {layer, content}, acc -> lay(acc, layer, content) end)

        content =
          lists
          |> Map.new(fn {kind, entries} ->
            {kind, Enum.map(entries, &Map.delete(&1, "override"))}
          end)
          |> Map.put("schema", Document.schema())

        %{
          layers: layers,
          content: content,
          hash: Document.hash(content),
          entries:
            for(
              kind <- @kinds,
              entry <- content[kind],
              do: Map.put(from[{kind, entry["name"]}], :kind, kind)
            ),
          problems: problems
        }
    end
  end

  # One layer over what is below it, kind by kind. A schema-0 document is only the MCP
  # servers it ever had.
  defp lay(acc, layer, content) do
    Enum.reduce(@kinds, acc, fn kind, {lists, from, problems} ->
      entries = for %{"name" => name} = entry <- list(content[kind]), is_binary(name), do: entry

      Enum.reduce(entries, {lists, from, problems}, fn entry, {lists, from, problems} ->
        add(kind, entry, layer, {lists, from, problems})
      end)
    end)
  end

  defp add(kind, %{"name" => name} = entry, layer, {lists, from, problems}) do
    below = lists[kind]
    source = %{name: name, from: layer.profile, channel: layer.channel}

    case Enum.find(below, &(&1["name"] == name)) do
      nil ->
        {Map.put(lists, kind, below ++ [entry]), Map.put(from, {kind, name}, source), problems}

      existing ->
        cond do
          overrides?(kind, entry) ->
            replaced = Enum.map(below, &if(&1["name"] == name, do: entry, else: &1))
            {Map.put(lists, kind, replaced), Map.put(from, {kind, name}, source), problems}

          same?(existing, entry) ->
            {lists, from, problems}

          true ->
            theirs = from[{kind, name}].from

            clash =
              "#{layer.profile}'s #{@words[kind]} #{name} (on #{layer.channel}) has the name " <>
                "of one #{theirs} gives it, and #{theirs}'s is kept: say override: true on it " <>
                "in #{layer.channel}'s bundle to replace it"

            {lists, from, problems ++ [clash]}
        end
    end
  end

  defp overrides?(_kind, %{"override" => true}), do: true

  defp overrides?("agents", %{"name" => name, "definition" => text}) when is_binary(text) do
    case AgentDefinition.parse(name, text) do
      {:ok, parsed} -> parsed.override
      {:error, _reason} -> false
    end
  end

  defp overrides?(_kind, _entry), do: false

  defp same?(a, b), do: Map.delete(a, "override") == Map.delete(b, "override")

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
