defmodule Troupe.Client.MemoryEntries do
  @moduledoc """
  Memory as entries (root #55): each `## Topic` section of a level's document is one entry,
  and on a topic the closest level's entry replaces the lower ones' — the person's own over
  their team's, a team's over the organisation's. What `/memory` lists level by level, and
  what is in effect for a session in each of the person's teams.

  Read from each document's text here, and saved as the whole text over the version it was
  edited from, until the plane answers entries itself. Text before a document's first topic
  is kept as it is, an entry of no topic.
  """

  @type level :: %{
          id: String.t(),
          scope: String.t(),
          name: String.t() | nil,
          rank: non_neg_integer(),
          version: non_neg_integer(),
          text: String.t(),
          changed_by: String.t() | nil,
          changed_at: String.t() | nil,
          entries: [entry()]
        }

  @type entry :: %{topic: String.t() | nil, key: String.t(), body: String.t()}

  @doc """
  The levels the person reads, lowest first: the organisation's, each of their teams' by name,
  and their own (`user`), each with its entries. `documents` is `me.memory`'s (or the copy's).
  """
  @spec levels([map()]) :: [level()]
  def levels(documents) do
    docs = List.wrap(documents)
    org = Enum.find(docs, &(&1["scope"] == "organisation"))
    teams = docs |> Enum.filter(&(&1["scope"] in ["team", "profile"])) |> Enum.sort_by(& &1["name"])
    own = Enum.find(docs, &(&1["scope"] == "user"))

    [level(org || %{"scope" => "organisation"}, 0)] ++
      Enum.map(teams, &level(&1, 1)) ++ [level(own || %{"scope" => "user"}, 2)]
  end

  defp level(doc, rank) do
    text = doc["text"] || ""

    %{
      id: id(doc),
      scope: doc["scope"],
      name: doc["name"],
      rank: rank,
      version: doc["version"] || 0,
      text: text,
      changed_by: doc["changed_by"],
      changed_at: doc["changed_at"],
      entries: entries(text)
    }
  end

  defp id(%{"scope" => "organisation"}), do: "organisation"
  defp id(%{"scope" => "user"}), do: "user"
  defp id(%{"scope" => scope, "name" => name}), do: "#{scope}:#{name}"

  @doc "A document's entries, in order: each `## Topic` section, and the text before the first."
  @spec entries(String.t()) :: [entry()]
  def entries(text) do
    {preamble, sections} = split(text)

    lead =
      if String.trim(preamble) == "",
        do: [],
        else: [%{topic: nil, key: "", body: String.trim(preamble)}]

    lead ++
      Enum.map(sections, fn {topic, body} ->
        %{topic: topic, key: key(topic), body: String.trim(body)}
      end)
  end

  @doc "How two topics are told apart: their words, case and spacing aside."
  @spec key(String.t() | nil) :: String.t()
  def key(nil), do: ""
  def key(topic), do: topic |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")

  @doc "The text with the entry on `topic` written as `body`: in its place if there is one, else last."
  @spec put(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def put(text, topic, body, was \\ nil) do
    {preamble, sections} = split(text)
    old = key(was || topic)
    entry = {String.trim(topic), String.trim(body)}

    sections =
      if Enum.any?(sections, fn {t, _} -> key(t) == old end),
        do: Enum.map(sections, fn {t, b} -> if key(t) == old, do: entry, else: {t, b} end),
        else: sections ++ [entry]

    join(preamble, sections)
  end

  @doc "The text without the entry on `topic`."
  @spec forget(String.t(), String.t()) :: String.t()
  def forget(text, topic) do
    {preamble, sections} = split(text)
    join(preamble, Enum.reject(sections, fn {t, _} -> key(t) == key(topic) end))
  end

  @doc """
  What a new session in `team` starts knowing, topic by topic: the closest level's entry,
  `from` that level, with the lower levels' entries it `replaces`.
  """
  @spec in_effect([level()], String.t() | nil) :: [map()]
  def in_effect(levels, team) do
    chain = Enum.filter(levels, &(&1.rank != 1 or &1.id == team))

    chain
    |> Enum.flat_map(fn level -> Enum.map(level.entries, &{&1, level}) end)
    # Text under no topic replaces nothing: each level's is its own.
    |> Enum.group_by(fn {entry, level} ->
      if entry.key == "", do: {:untitled, level.id}, else: entry.key
    end)
    |> Enum.map(fn {_key, stack} ->
      [{winner, from} | under] = Enum.sort_by(stack, fn {_entry, level} -> -level.rank end)

      %{
        entry: winner,
        from: from,
        replaces: Enum.map(under, fn {entry, level} -> %{entry: entry, from: level} end)
      }
    end)
    |> Enum.sort_by(&first_seen(chain, &1))
  end

  # Topics in the order the levels first name them, lowest first.
  defp first_seen(levels, %{entry: entry, from: from}) do
    levels
    |> Enum.flat_map(fn level -> Enum.map(level.entries, &{&1, level}) end)
    |> Enum.find_index(fn {e, level} ->
      if entry.key == "", do: e == entry and level.id == from.id, else: e.key == entry.key
    end)
  end

  @doc """
  Whether a new entry on `topic` at `level` clashes: `{:here, level}` where that level has one
  already, `{:lower, level}` where it would replace a lower level's, or `nil`.
  """
  @spec clash([level()], level(), String.t()) :: {:here | :lower, level()} | nil
  def clash(levels, level, topic) do
    k = key(topic)
    has = fn l -> Enum.any?(l.entries, &(&1.key == k)) end

    cond do
      k == "" -> nil
      has.(level) -> {:here, level}
      lower = Enum.find(levels, &(&1.rank < level.rank and has.(&1))) -> {:lower, lower}
      true -> nil
    end
  end

  # The text before the first `## ` heading, and each section as its topic and body.
  defp split(text) do
    lines = String.split(String.replace(text || "", "\r\n", "\n"), "\n")

    {preamble, sections} =
      Enum.reduce(lines, {[], []}, fn line, {pre, sections} ->
        case Regex.run(~r/^##\s+(.+?)\s*$/, line) do
          [_, topic] -> {pre, [{topic, []} | sections]}
          nil when sections == [] -> {[line | pre], sections}
          nil -> {pre, [{elem(hd(sections), 0), [line | elem(hd(sections), 1)]} | tl(sections)]}
        end
      end)

    {preamble |> Enum.reverse() |> Enum.join("\n"),
     sections
     |> Enum.reverse()
     |> Enum.map(fn {t, body} -> {t, body |> Enum.reverse() |> Enum.join("\n")} end)}
  end

  defp join(preamble, sections) do
    parts =
      if(String.trim(preamble) == "", do: [], else: [String.trim(preamble)]) ++
        Enum.map(sections, fn {t, b} -> String.trim_trailing("## #{t}\n#{String.trim(b)}") end)

    Enum.join(parts, "\n\n")
  end
end
