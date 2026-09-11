defmodule Troupe.MemoryTest do
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
  - 2026-09-01 code-1: the ledger is a fold over the log.
  """

  test "parse reads frontmatter and keeps sections in order" do
    brief = brief!(@full)

    assert brief.head == "2703d22"
    assert brief.files == 200
    assert DateTime.to_iso8601(brief.built_at) == "2026-09-01T10:00:00Z"
    assert Enum.map(brief.sections, &elem(&1, 0)) == ~w(Overview Layout Gotchas Notes)
    assert Memory.section(brief, "Overview") =~ "actor-model"
  end

  test "render/parse is a fixpoint, including unknown sections" do
    once = @full |> brief!() |> Memory.render()
    assert brief!(once) == brief!(Memory.render(brief!(once)))
    assert once =~ "## Gotchas"
    assert once =~ "built_at: 2026-09-01T10:00:00Z"
  end

  test "a file with no frontmatter parses, round-trips and reads as stale" do
    brief = brief!("## Overview\nJust prose.\n")

    assert brief.built_at == nil
    assert Memory.section(brief, "Overview") == "Just prose."
    refute Memory.render(brief) =~ "---"
    assert brief!(Memory.render(brief)) == brief
    assert Memory.stale?(brief)
  end

  test "text before the first heading survives a round trip" do
    brief = brief!("Loose intro.\n\n## Overview\nBody.\n")

    assert [{"", "Loose intro."}, {"Overview", "Body."}] = brief.sections
    assert brief!(Memory.render(brief)) == brief
  end

  test "put_section replaces in place and preserves order, or appends" do
    brief = @full |> brief!() |> Memory.put_section("overview", "  Rewritten.  ")

    assert Memory.section(brief, "Overview") == "Rewritten."
    assert Enum.map(brief.sections, &elem(&1, 0)) == ~w(Overview Layout Gotchas Notes)

    appended = Memory.put_section(brief, "commands", "mix test")
    assert List.last(appended.sections) == {"Commands", "mix test"}
  end

  test "add_note prepends, dedupes on text and caps the list" do
    brief = Memory.add_note(Memory.empty(), "code-1", "locks are advisory")
    assert Memory.section(brief, "Notes") =~ "code-1: locks are advisory"

    again = Memory.add_note(brief, "code-2", "locks are advisory")
    assert length(String.split(Memory.section(again, "Notes"), "\n")) == 1
    assert Memory.section(again, "Notes") =~ "code-2"

    many = Enum.reduce(1..60, Memory.empty(), &Memory.add_note(&2, "code-1", "note #{&1}"))
    notes = String.split(Memory.section(many, "Notes"), "\n")
    assert length(notes) == 40
    assert hd(notes) =~ "note 60"
  end

  test "add_note squishes whitespace so one note stays one line" do
    brief = Memory.add_note(Memory.empty(), "code-1", "wrapped\n  over   lines")
    assert Memory.section(brief, "Notes") =~ "code-1: wrapped over lines"
    assert length(String.split(Memory.section(brief, "Notes"), "\n")) == 1
  end

  test "stale? triggers on absence, age and file drift but not on a new commit" do
    fresh = @full |> brief!() |> Memory.stamp("abc1234", 200)

    assert Memory.stale?(nil)
    assert Memory.stale?(Memory.empty())
    refute Memory.stale?(fresh, files: 200)
    refute Memory.stale?(fresh, files: 210), "10 files is within the absolute floor"
    assert Memory.stale?(fresh, files: 260)
    assert Memory.stale?(fresh, files: 100)

    small = Memory.stamp(Memory.put_section(Memory.empty(), "Overview", "x"), nil, 1)
    refute Memory.stale?(small, files: 2), "writing the brief must not invalidate it"
    assert Memory.stale?(small, files: 40)

    old = %Memory{fresh | built_at: DateTime.add(DateTime.utc_now(), -8, :day)}
    assert Memory.stale?(old, files: 200)
    refute Memory.stale?(old, files: 200, max_age_days: 30)
  end

  test "to_prompt renders a capped, clearly non-authoritative block" do
    brief = brief!(@full)

    assert Memory.to_prompt(nil) == ""
    assert Memory.to_prompt(Memory.empty()) == ""

    text = Memory.to_prompt(brief)
    assert text =~ "# Project brief"
    assert text =~ "authoritative"
    assert text =~ "## Overview"

    assert Memory.to_prompt(brief, max_chars: 40) =~ "(brief truncated)"
  end

  test "unterminated frontmatter is an error, not a crash" do
    assert {:error, :unterminated_frontmatter} = Memory.parse("---\nbuilt_at: x\n## Overview\n")
  end
end
