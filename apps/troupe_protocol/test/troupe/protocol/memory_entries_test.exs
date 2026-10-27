defmodule Troupe.Protocol.MemoryEntriesTest do
  @moduledoc """
  A memory document read as entries (#55): its `## Topic` sections, the text before the
  first heading as General, written back as sections in order with each heading as given;
  and, among the levels a session reads, the closest level's entry on a topic in effect with
  the lower ones it replaces.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Memory.Entries

  @document """
  We are a consultancy.

  ## Tone

  Plain English, short sentences.

  ##   Dates and  Numbers ##

  ISO dates.
  Thousands with a space.

  ```
  ## not a heading
  ```

  ### Not a section either
  """

  test "a document's sections are its entries, General first, a heading in a code block the code's" do
    assert [
             %{"topic" => "General", "heading" => false, "body" => "We are a consultancy."},
             %{"topic" => "Tone", "heading" => true, "body" => "Plain English, short sentences."},
             %{"topic" => "Dates and  Numbers", "heading" => true, "body" => dates}
           ] = Entries.parse(@document)

    assert dates =~ "ISO dates.\nThousands with a space."
    assert dates =~ "## not a heading"
    assert dates =~ "### Not a section either"
    assert Entries.parse("") == []
    assert Entries.parse("\n\n## Only\n") == [%{"topic" => "Only", "heading" => true, "body" => ""}]
  end

  test "entries round-trip through their text, the heading's text kept as given" do
    canonical = "Opening words.\n\n## Tone\n\nShort.\n\n## Prices\n\n- Rate card.\n- No discounts."
    assert canonical |> Entries.parse() |> Entries.render() == canonical

    entries = [%{"topic" => "  Client  Names ", "body" => "\nUse their own spelling.\n\n"}]
    assert {:ok, cast} = Entries.cast(entries)
    assert Entries.render(cast) == "## Client  Names\n\nUse their own spelling."
    assert cast |> Entries.render() |> Entries.parse() |> Enum.map(& &1["topic"]) == ["Client  Names"]
  end

  test "entries sent for a save are checked" do
    assert {:ok, [%{"topic" => "General", "heading" => false}, %{"topic" => "Tone"}]} =
             Entries.cast([%{"body" => "Hello."}, %{"topic" => "Tone", "body" => "Short."}])

    assert {:error, "only the first entry may be without a topic" <> _} =
             Entries.cast([%{"topic" => "Tone", "body" => "x"}, %{"body" => "y"}])

    assert {:error, "entry 1's body has a ## heading" <> _} =
             Entries.cast([%{"topic" => "Tone", "body" => "x\n## Sneaky\ny"}])

    assert {:error, "entry 1's topic is one line"} = Entries.cast([%{"topic" => "a\nb", "body" => ""}])
    assert {:error, _} = Entries.cast("## Tone")
  end

  test "topics compare by their words, case and spacing aside" do
    assert Entries.key("  Dates and   NUMBERS ") == Entries.key("dates and numbers")
    refute Entries.key("Dates") == Entries.key("Date")
  end

  describe "in effect" do
    setup do
      %{
        levels: [
          level(:organisation, 0, "Opening.\n\n## Tone\n\nPlain English.\n\n## Prices\n\nRate card.\n\n## Dates\n\nISO."),
          level({:team, "sales"}, 1, "## Prices\n\nFramework agreement.\n\n## Proposals\n\nProblem first."),
          level({:profile, "base"}, 2, "## prices\n\nAsk the base."),
          level(:user, 9, "My own words.\n\n## TONE\n\nShort answers.")
        ]
      }
    end

    test "is one list: per topic the closest level's entry, with what it replaces, closest first", %{levels: levels} do
      effect = Enum.map(Entries.in_effect(levels), &{&1.level, &1.entry["topic"], Enum.map(&1.replaces, fn {l, e} -> {l, e["body"]} end)})

      assert effect == [
               {:organisation, "General", []},
               {:user, "TONE", [{:organisation, "Plain English."}]},
               {{:profile, "base"}, "prices", [{{:team, "sales"}, "Framework agreement."}, {:organisation, "Rate card."}]},
               {:organisation, "Dates", []},
               {{:team, "sales"}, "Proposals", []},
               {:user, "General", []}
             ]
    end

    test "each level's entries say whether they are kept or replaced, and by whom", %{levels: levels} do
      [{:organisation, organisation} | _rest] = Entries.resolve(levels)

      assert Enum.map(organisation, fn {e, mark} -> {e["topic"], mark_of(mark)} end) == [
               {"General", :kept},
               {"Tone", {:replaced, [:user]}},
               {"Prices", {:replaced, [{:profile, "base"}]}},
               {"Dates", :kept}
             ]
    end

    test "two levels of one rank replace neither of each other" do
      levels = [
        level(:organisation, 0, "## Tone\n\nPlain."),
        level({:team, "a"}, 1, "## Tone\n\nA's."),
        level({:team, "b"}, 1, "## Tone\n\nB's.")
      ]

      assert [
               %{level: {:team, "a"}, replaces: [{:organisation, _}]},
               %{level: {:team, "b"}, replaces: [{:organisation, _}]}
             ] = Entries.in_effect(levels)
    end
  end

  defp level(level, rank, text), do: %{level: level, rank: rank, entries: Entries.parse(text)}

  defp mark_of({:kept, _replaces}), do: :kept
  defp mark_of(replaced), do: replaced
end
