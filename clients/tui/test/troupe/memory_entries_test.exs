defmodule Troupe.MemoryEntriesTest do
  @moduledoc """
  Memory as entries (root #55), read from each level's text: a `## Topic` section is one
  entry, the closest level's entry on a topic replacing the lower ones', and an entry written
  or forgotten keeps the rest of the document as it was.
  """

  use ExUnit.Case, async: true

  alias Troupe.Client.MemoryEntries

  @documents [
    %{"scope" => "user", "version" => 3, "text" => "## tone\nShort answers."},
    %{
      "scope" => "organisation",
      "version" => 1,
      "text" => "Who we are.\n\n## Tone\nPlain English.\n\n## Prices\nThe rate card."
    },
    %{"scope" => "team", "name" => "sales", "version" => 2, "text" => "## Prices\nThe framework."},
    %{"scope" => "team", "name" => "design", "version" => 1, "text" => "## Consent\nAsk first."}
  ]

  test "levels lowest first, each its entries, and text before any topic kept as one of no topic" do
    levels = MemoryEntries.levels(@documents)
    assert Enum.map(levels, & &1.id) == ["organisation", "team:design", "team:sales", "user"]
    [org | _] = levels

    assert [%{topic: nil, body: "Who we are."}, %{topic: "Tone", key: "tone"}, %{topic: "Prices"}] =
             org.entries
  end

  test "in effect for a team: the closest level wins a topic, naming what it replaces" do
    levels = MemoryEntries.levels(@documents)
    effect = MemoryEntries.in_effect(levels, "team:sales")

    assert [untitled, tone, prices] = effect
    assert untitled.entry.body == "Who we are." and untitled.replaces == []
    assert tone.from.id == "user"
    assert [%{from: %{id: "organisation"}}] = tone.replaces
    assert prices.from.id == "team:sales"
    assert [%{from: %{id: "organisation"}}] = prices.replaces
    refute Enum.any?(effect, &(&1.entry.topic == "Consent"))
  end

  test "a clash where the level has the topic, or a lower one does" do
    levels = MemoryEntries.levels(@documents)
    own = List.last(levels)
    assert {:here, ^own} = MemoryEntries.clash(levels, own, " TONE ")
    assert {:lower, %{id: "organisation"}} = MemoryEntries.clash(levels, own, "prices")
    assert nil == MemoryEntries.clash(levels, own, "lunch")
  end

  test "an entry written in its place or last, renamed, and forgotten, the rest kept" do
    text = "Intro.\n\n## A\none\n\n## B\ntwo"
    assert MemoryEntries.put(text, "a", "uno") == "Intro.\n\n## a\nuno\n\n## B\ntwo"
    assert MemoryEntries.put(text, "C", "three") == text <> "\n\n## C\nthree"
    assert MemoryEntries.put(text, "Bee", "two", "B") == "Intro.\n\n## A\none\n\n## Bee\ntwo"
    assert MemoryEntries.forget(text, "a") == "Intro.\n\n## B\ntwo"
  end
end
