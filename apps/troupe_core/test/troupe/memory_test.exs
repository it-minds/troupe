defmodule Troupe.MemoryTest do
  @moduledoc """
  The brief's text: lossless parsing, the view generated from facts and read back item by
  item, the prompt's core and its cap, staleness. Pure, no disk.
  """

  use ExUnit.Case, async: true

  alias Troupe.Memory

  defp brief!(text) do
    {:ok, brief} = Memory.parse(text)
    brief
  end

  @full """
  ---
  built_at: 2026-09-01T10:00:00Z
  head: 2703d22
  files: 200
  ---

  ## Overview
  Troupe is an actor-model coding-agent harness.

  ## Layout
  - `lib/troupe/session/` — per-session actors.

  ## Gotchas
  Hand-written, and not a title the librarian knows.

  ## Notes
  - 2026-09-01 root: the ledger is a fold over the log.
  """

  test "parse reads frontmatter and keeps sections in order" do
    brief = brief!(@full)

    assert brief.head == "2703d22"
    assert brief.files == 200
    assert DateTime.to_iso8601(brief.built_at) == "2026-09-01T10:00:00Z"
    assert Memory.titles(brief) == ~w(Overview Layout Gotchas Notes)
    assert Memory.section(brief, "overview") =~ "actor-model"
  end

  test "render/parse is a fixpoint, including unknown sections" do
    once = @full |> brief!() |> Memory.render()
    assert brief!(once) == brief!(Memory.render(brief!(once)))
    assert once =~ "## Gotchas"
    assert once =~ "built_at: 2026-09-01T10:00:00Z"
  end

  # A short hash of digits and one `e` is a number to YAML (`4572e29` is 4.572e32), and one
  # of digits with a leading zero loses it: the brief writes its head quoted, and a head an
  # older build wrote bare reads back as the text on its line.
  test "the head is written quoted, and one written bare reads as it was written" do
    rendered =
      Memory.view([%{"id" => "f_1", "kind" => "note", "claim" => "x"}], %{head: "4572e29"})

    assert rendered =~ ~s(\nhead: "4572e29"\n)
    assert brief!(rendered).head == "4572e29"
    assert brief!(Memory.render(brief!(rendered))).head == "4572e29"

    for bare <- ~w(4572e29 0012345 1234567 2703d22 1e10 true) do
      old = String.replace(@full, "head: 2703d22", "head: #{bare}")
      assert brief!(old).head == bare
      assert Memory.render(brief!(old)) =~ ~s(\nhead: "#{bare}"\n)
    end

    assert brief!(String.replace(@full, "head: 2703d22", "head: 4572e29 # short")).head ==
             "4572e29"

    # What is not one word on its line cannot be told from what YAML made of it: no head,
    # which decides nothing, and the next refresh writes it again.
    assert brief!(String.replace(@full, "head: 2703d22", "head: [4572e29]")).head == nil
    assert brief!(String.replace(@full, "head: 2703d22", "head:")).head == nil
  end

  test "a file with no frontmatter parses, round-trips, and was never built" do
    brief = brief!("## Overview\nJust prose.\n")

    assert brief.built_at == nil
    assert Memory.section(brief, "Overview") == "Just prose."
    refute Memory.render(brief) =~ "---"
    assert brief!(Memory.render(brief)) == brief
    assert Memory.stale?(brief.built_at, [])
  end

  test "text before the first heading survives a round trip" do
    brief = brief!("Loose intro.\n\n## Overview\nBody.\n")
    assert [{"", "Loose intro."}, {"Overview", "Body."}] = brief.sections
    assert brief!(Memory.render(brief)) == brief
  end

  test "a brief's items are facts by its titles, an unknown title leading its notes" do
    assert Memory.units(brief!(@full)) == [
             {"overview", "Troupe is an actor-model coding-agent harness."},
             {"layout", "`lib/troupe/session/` — per-session actors."},
             {"note", "Gotchas: Hand-written, and not a title the librarian knows."},
             {"note", "2026-09-01 root: the ledger is a fold over the log."}
           ]

    assert Memory.claims("Intro:\n\n```sh\nmix check\n```\n\nAfter.") ==
             ["Intro:\n\n```sh\nmix check\n```", "After."]

    assert Memory.claims("- one\n  more of one\n* two\n\n3. three") == [
             "one\nmore of one",
             "two",
             "three"
           ]

    assert Memory.units(brief!("Loose.\n\n## commands\n- `make`\n")) == [
             {"note", "Loose."},
             {"command", "`make`"}
           ]
  end

  test "the view is generated, says so, and knows when it was edited" do
    facts = [
      %{
        "id" => "f_2",
        "kind" => "command",
        "claim" => "`make`",
        "created_at" => "2026-10-10T00:00:01Z"
      },
      %{
        "id" => "f_1",
        "kind" => "overview",
        "claim" => "A tool.",
        "created_at" => "2026-10-10T00:00:02Z"
      },
      %{
        "id" => "f_3",
        "kind" => "note",
        "claim" => "locks are advisory",
        "created_at" => "2026-10-09T08:00:00Z",
        "evidence" => %{"by" => "agent:root/explore#1"}
      }
    ]

    built = ~U[2026-10-10 09:00:00Z]
    view = Memory.view(facts, %{built_at: built, head: "abc1234", survey: 1})

    assert view =~
             ~r/\A---\nbuilt_at: 2026-10-10T09:00:00Z\nhead: "abc1234"\nsurvey: 1\ngenerated: "sha256:[0-9a-f]{64}"\n---\n\n/

    assert view =~ "\n\n> Generated by Troupe from `.troupe/memory/facts.jsonl`"

    assert view =~
             "## Overview\n- A tool.\n\n## Commands\n- `make`\n\n## Notes\n- 2026-10-09 root/explore#1: locks are advisory\n"

    assert Memory.view([], %{}) == nil

    assert Memory.generated(view) == :generated
    assert Memory.generated(String.replace(view, "\n", "\r\n")) == :generated
    assert Memory.generated(String.replace(view, "- A tool.", "- A tool, edited.")) == :edited
    assert Memory.generated(@full) == :unstamped

    # Read back, the header is not a fact and every item is the one written.
    assert Memory.units(brief!(view)) == [
             {"overview", "A tool."},
             {"command", "`make`"},
             {"note", "2026-10-09 root/explore#1: locks are advisory"}
           ]
  end

  test "the prompt carries the core, clearly checked rather than authoritative" do
    assert Memory.to_prompt(nil) == ""
    assert Memory.to_prompt(%{facts: [], others: %{}}) == ""

    core = %{
      facts: [
        %{"kind" => "command", "claim" => "`make check`", "status" => "current"},
        %{
          "kind" => "convention",
          "claim" => "Tabs.",
          "status" => "moved",
          "changed" => ["Makefile"]
        }
      ],
      others: %{"layout" => 3}
    }

    text = Memory.to_prompt(core)
    assert text =~ "# Project brief"
    assert text =~ "Each\nwas checked when it was written down."
    assert text =~ "If a command here fails, read the error"
    refute text =~ "treat it as correct"

    assert text =~
             "## Commands\n- `make check`\n\n## Conventions\n- Tabs. (may no longer be true: `Makefile` changed"

    assert text =~ "3 more facts about this repository (3 layout)"
  end

  test "stale? triggers on a brief never built, on age, and on a core fact moved since, not " <>
         "on a new commit" do
    now = DateTime.utc_now()
    moved = %{"kind" => "command", "status" => "moved", "changed_at" => DateTime.to_iso8601(now)}

    assert Memory.stale?(nil, [])
    refute Memory.stale?(now, [])
    refute Memory.stale?(now, [%{"kind" => "command", "status" => "current"}])
    assert Memory.stale?(DateTime.add(now, -60), [moved])
    refute Memory.stale?(DateTime.add(now, 60), [moved]), "a check since the change"
    assert Memory.stale?(now, [%{moved | "status" => "missing", "changed_at" => nil}])

    old = DateTime.add(now, -8, :day)
    assert Memory.stale?(old, [])
    refute Memory.stale?(old, [], max_age_days: 30)
  end
end
