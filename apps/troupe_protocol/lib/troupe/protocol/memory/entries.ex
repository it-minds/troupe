defmodule Troupe.Protocol.Memory.Entries do
  @moduledoc """
  A memory document as entries (#55): each `## Topic` section of its Markdown is one entry,
  its topic the heading's text and its body the lines under it. Text before the first heading
  is the entry called "General", which has no heading of its own.

  The text stays what is kept, versioned and blamed (`Troupe.Protocol.Memory`); entries are
  a reading of it, and a list of entries is written back as sections in its order
  (`render/1`), each heading's text as it was given. Here because the plane, which answers
  entries and takes them for a save, and a session's prompt, built per topic, read one
  document the same way.

  **Closest wins per topic.** The levels a session reads are ranked, the organisation's
  lowest, then a team's, then a worker profile's chain (the one that extends nothing first),
  then the person's own. Where two levels have an entry on one topic, the closer one's is in
  effect and the lower ones' are replaced by it (`in_effect/1`, `resolve/1`). Topics compare
  by their words, case and spacing aside (`key/1`). Levels of one rank (two teams on a
  person's own machine) replace neither of each other. "General" is no topic: it is never
  replaced and replaces nothing, so an organisation's opening words stay whatever a person
  writes above their own first heading.
  """

  @general "General"
  @heading ~r/^##[ \t]+(.+?)[ \t]*#*[ \t]*$/
  @fence ~r/^[ \t]{0,3}(```|~~~)/

  @typedoc "One entry: `topic`, `body` and whether it has a heading (`false` for General)."
  @type entry :: %{String.t() => term()}

  @typedoc "A level as `resolve/1` and `in_effect/1` take it: who it is, its rank, its entries."
  @type level :: %{required(:level) => term(), required(:rank) => integer(), required(:entries) => [entry()]}

  @doc "The topic of the text before a document's first heading."
  @spec general() :: String.t()
  def general, do: @general

  @doc """
  The entries of a document's text, in order: `%{"topic", "body", "heading"}`. The body is
  the lines under the heading, blank lines at its start and end left off. A heading inside a
  fenced code block is the code's, not a section's.
  """
  @spec parse(String.t() | nil) :: [entry()]
  def parse(nil), do: []

  def parse(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> split(& &1)
    |> Enum.map(fn {topic, heading?, lines} ->
      body = if heading?, do: tl(lines), else: lines
      %{"topic" => topic, "body" => body_text(body), "heading" => heading?}
    end)
  end

  @doc "A section's body from the lines under its heading: blank lines at its start and end left off."
  @spec body_text([String.t()]) :: String.t()
  def body_text(lines), do: lines |> trim_blank() |> Enum.join("\n")

  @doc """
  Any list of a document's lines, grouped by section: `{topic, heading?, items}`, the
  heading's own item first where there is one. `text_of` reads an item's line, so the plane
  can group its blame's lines (each with who wrote it) as the text's are. A General with
  nothing in it but blank lines is left out.
  """
  @spec split([item], (item -> String.t())) :: [{String.t(), boolean(), [item]}] when item: term()
  def split(items, text_of) do
    {sections, current, _fenced} =
      Enum.reduce(items, {[], {@general, false, []}, false}, fn item, {done, {topic, heading?, acc}, fenced} ->
        line = text_of.(item)

        cond do
          Regex.match?(@fence, line) ->
            {done, {topic, heading?, [item | acc]}, not fenced}

          not fenced and Regex.match?(@heading, line) ->
            [_, title] = Regex.run(@heading, line)
            {[{topic, heading?, Enum.reverse(acc)} | done], {String.trim(title), true, [item]}, false}

          true ->
            {done, {topic, heading?, [item | acc]}, fenced}
        end
      end)

    {topic, heading?, acc} = current

    [{topic, heading?, Enum.reverse(acc)} | sections]
    |> Enum.reverse()
    |> Enum.reject(fn {_topic, heading?, items} ->
      not heading? and Enum.all?(items, &(String.trim(text_of.(&1)) == ""))
    end)
  end

  @doc """
  The text of a document holding these entries, in their order: each as `## <topic>`, a
  blank line and its body, a blank line between two; General as its body alone. The
  heading's text is the topic as given, its outer spaces aside.
  """
  @spec render([entry()]) :: String.t()
  def render(entries) when is_list(entries) do
    entries
    |> Enum.map(fn entry ->
      body = entry |> body() |> String.split("\n") |> trim_blank() |> Enum.join("\n")

      cond do
        not heading?(entry) -> body
        body == "" -> "## " <> String.trim(entry["topic"])
        true -> "## " <> String.trim(entry["topic"]) <> "\n\n" <> body
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Entries as a client sends them for a save, checked: a list of `%{"topic", "body"}`, each
  topic one line and each body free of `## ` headings (a heading in it would be an entry of
  its own when the text is read back). An entry with no topic, or with `heading: false`, is
  General, and only the first may be. The reason in words where not.
  """
  @spec cast(term()) :: {:ok, [entry()]} | {:error, String.t()}
  def cast(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case cast_one(entry, index) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cast} -> {:ok, Enum.reverse(cast)}
      error -> error
    end
  end

  def cast(_other), do: {:error, "entries is a list of {topic, body}"}

  defp cast_one(%{} = entry, index) do
    topic = entry["topic"]
    body = entry["body"] || ""
    general? = entry["heading"] == false or topic in [nil, ""]

    with :ok <- typed(topic, body, index),
         :ok <- placed(general?, topic, index),
         :ok <- headless(body, index) do
      if general?,
        do: {:ok, %{"topic" => @general, "body" => body, "heading" => false}},
        else: {:ok, %{"topic" => String.trim(topic), "body" => body, "heading" => true}}
    end
  end

  defp cast_one(_other, index), do: {:error, "entry #{index + 1} is {topic, body}"}

  defp typed(_topic, body, index) when not is_binary(body), do: {:error, "entry #{index + 1}'s body is text"}
  defp typed(topic, _body, index) when not (is_nil(topic) or is_binary(topic)), do: {:error, "entry #{index + 1}'s topic is text"}
  defp typed(_topic, _body, _index), do: :ok

  defp placed(true, _topic, index) when index > 0,
    do: {:error, "only the first entry may be without a topic: entry #{index + 1} has none"}

  defp placed(false, topic, index) do
    if String.contains?(topic, "\n"), do: {:error, "entry #{index + 1}'s topic is one line"}, else: :ok
  end

  defp placed(_general?, _topic, _index), do: :ok

  defp headless(body, index) do
    if body |> String.split("\n") |> Enum.any?(&Regex.match?(@heading, &1)),
      do: {:error, "entry #{index + 1}'s body has a ## heading in it; make that an entry of its own"},
      else: :ok
  end

  @doc "A topic as two entries are compared by it: its words, case and spacing aside."
  @spec key(String.t()) :: String.t()
  def key(topic) when is_binary(topic),
    do: topic |> String.split() |> Enum.join(" ") |> String.downcase()

  @doc """
  Each level's entries marked as they stand among the levels: `{level, [{entry, mark}]}`,
  in the order given, where `mark` is `{:kept, replaces}` (the lower levels' entries on its
  topic it replaces, `[{level, entry}]`, closest first) or `{:replaced, by}` (the closer
  levels whose entry on its topic is in effect).
  """
  @spec resolve([level()]) :: [{term(), [{entry(), {:kept, [{term(), entry()}]} | {:replaced, [term()]}}]}]
  def resolve(levels) when is_list(levels) do
    closest =
      for %{rank: rank, entries: entries} <- levels, entry <- entries, heading?(entry), reduce: %{} do
        acc -> Map.update(acc, key(entry["topic"]), rank, &max(&1, rank))
      end

    Enum.map(levels, fn %{level: level, rank: rank, entries: entries} ->
      {level, Enum.map(entries, &{&1, mark(&1, rank, closest, levels)})}
    end)
  end

  defp mark(entry, rank, closest, levels) do
    topic = if heading?(entry), do: key(entry["topic"])

    cond do
      is_nil(topic) ->
        {:kept, []}

      closest[topic] > rank ->
        by = for %{level: level, rank: r, entries: es} <- levels, r == closest[topic], on?(es, topic), do: level
        {:replaced, by}

      true ->
        replaced =
          for %{level: level, rank: r, entries: es} <- Enum.sort_by(levels, &(-&1.rank)),
              r < rank,
              entry <- es,
              heading?(entry) and key(entry["topic"]) == topic,
              do: {level, entry}

        {:kept, replaced}
    end
  end

  defp on?(entries, topic), do: Enum.any?(entries, &(heading?(&1) and key(&1["topic"]) == topic))

  @doc """
  What a session reading these levels starts knowing, as one list: every entry in effect,
  each `%{level, entry, replaces}`, a topic where it first comes in the levels' order (the
  organisation's first) and its closest level's entry there.
  """
  @spec in_effect([level()]) :: [%{level: term(), entry: entry(), replaces: [{term(), entry()}]}]
  def in_effect(levels) do
    # Each entry kept, by where it is: its level's place in the list and its own in the level.
    kept =
      for {{_level, marked}, at} <- Enum.with_index(resolve(levels)),
          {{entry, {:kept, replaces}}, index} <- Enum.with_index(marked),
          do: {{at, index}, entry, replaces}

    levels
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{entries: entries}, at} -> slots(entries, at) end)
    |> Enum.uniq()
    |> Enum.flat_map(fn slot ->
      for {where, entry, replaces} <- kept, in_slot?(slot, where, entry),
          do: %{level: Enum.at(levels, elem(where, 0)).level, entry: entry, replaces: replaces}
    end)
  end

  @doc """
  The rank of one of the documents a session reads, among them (`Troupe.Protocol.Memory`'s
  documents, in their order): the organisation's 0, a team's 1 (two teams one rank), a worker
  profile's 2 and up along its chain, the one that extends nothing first, and the person's
  own the closest of all.
  """
  @spec rank(map(), [map()]) :: integer()
  def rank(%{"scope" => "organisation"}, _documents), do: 0
  def rank(%{"scope" => "team"}, _documents), do: 1
  def rank(%{"scope" => "user"}, _documents), do: 1_000

  def rank(%{"scope" => "profile"} = document, documents),
    do: 2 + (documents |> Enum.filter(&(&1["scope"] == "profile")) |> Enum.find_index(&(&1 == document)))

  @doc "These documents as levels for `resolve/1` and `in_effect/1`, each named by its `scope` and `name`."
  @spec levels([map()]) :: [level()]
  def levels(documents) do
    Enum.map(documents, fn document ->
      %{
        level: %{"scope" => document["scope"], "name" => document["name"]},
        rank: rank(document, documents),
        entries: document["entries"] || parse(document["text"])
      }
    end)
  end

  @doc """
  `in_effect/1` as an answer carries it: each entry with its `level` and `replaces`, each
  of those `{level, topic, body}`.
  """
  @spec effect_json([%{level: term(), entry: entry(), replaces: [{term(), entry()}]}]) :: [map()]
  def effect_json(effect) do
    Enum.map(effect, fn %{level: level, entry: entry, replaces: replaces} ->
      entry
      |> Map.put("level", level)
      |> Map.put("replaces", Enum.map(replaces, fn {lower, e} -> %{"level" => lower, "topic" => e["topic"], "body" => e["body"]} end))
    end)
  end

  # Where each entry of a level goes in the one list: a topic's slot, or General's own.
  defp slots(entries, at) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      if heading?(entry), do: {:topic, key(entry["topic"])}, else: {:general, {at, index}}
    end)
  end

  defp in_slot?({:topic, topic}, _where, entry), do: heading?(entry) and key(entry["topic"]) == topic
  defp in_slot?({:general, where}, where, _entry), do: true
  defp in_slot?(_slot, _where, _entry), do: false

  defp heading?(%{"heading" => false}), do: false
  defp heading?(%{"topic" => topic}) when is_binary(topic), do: true
  defp heading?(_entry), do: false

  defp body(%{"body" => body}) when is_binary(body), do: body
  defp body(_entry), do: ""

  defp trim_blank(lines) do
    lines
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end
end
