defmodule Troupe.Protocol.WordsTest do
  @moduledoc """
  Durations, counts and lists as every app writes them: one spelling of a minute.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Words

  describe "duration/1" do
    test "under a minute it is seconds, a tenth kept only when there is one" do
      assert Words.duration(0) == "0 s"
      assert Words.duration(1_000) == "1 s"
      assert Words.duration(2_000) == "2 s"
      assert Words.duration(1_500) == "1.5 s"
      assert Words.duration(40) == "0 s"
      assert Words.duration(59_000) == "59 s"
      assert Words.duration(59_900) == "59.9 s"
    end

    test "from a minute up it is hours, minutes and seconds, a part that is nought left out" do
      assert Words.duration(59_950) == "1 min"
      assert Words.duration(60_000) == "1 min"
      assert Words.duration(90_000) == "1 min 30 s"
      assert Words.duration(15 * 60_000) == "15 min"
      assert Words.duration(3_600_000) == "1 h"
      assert Words.duration(3_660_000) == "1 h 1 min"
      assert Words.duration(3_661_000) == "1 h 1 min 1 s"
      assert Words.duration(5_400_000) == "1 h 30 min"
    end

    test "a float is read as whole milliseconds and less than nothing as nothing" do
      assert Words.duration(1_500.7) == "1.5 s"
      assert Words.duration(-5) == "0 s"
    end
  end

  describe "duration/2 short" do
    test "is the terminal's compact form, whole seconds" do
      assert Words.duration(0, :short) == "0s"
      assert Words.duration(999, :short) == "0s"
      assert Words.duration(14_500, :short) == "14s"
      assert Words.duration(59_000, :short) == "59s"
      assert Words.duration(60_000, :short) == "1m"
      assert Words.duration(242_000, :short) == "4m 2s"
      assert Words.duration(3_660_000, :short) == "1h 1m"
    end
  end

  describe "ago/2" do
    @now ~U[2026-11-17 12:00:00Z]

    test "says how long ago in the largest unit that fits" do
      assert Words.ago(DateTime.add(@now, -59), @now) == "just now"
      assert Words.ago(DateTime.add(@now, -60), @now) == "1 min ago"
      assert Words.ago(DateTime.add(@now, -3 * 60), @now) == "3 min ago"
      assert Words.ago(DateTime.add(@now, -2 * 3600), @now) == "2 h ago"
      assert Words.ago(DateTime.add(@now, -30 * 3600), @now) == "yesterday"
      assert Words.ago(DateTime.add(@now, -4 * 86_400), @now) == "4 days ago"
    end

    test "is the date from thirty days on" do
      assert Words.ago(~U[2026-10-01 08:00:00Z], @now) == "2026-10-01"
    end
  end

  describe "count/3 and plural/3" do
    test "a regular noun takes an s for every count but one" do
      assert Words.count(0, "file") == "0 files"
      assert Words.count(1, "file") == "1 file"
      assert Words.count(2, "file") == "2 files"
      assert Words.plural(1, "line") == "line"
      assert Words.plural(3, "line") == "lines"
    end

    test "an irregular one gives both forms" do
      assert Words.count(1, "push", "pushes") == "1 push"
      assert Words.count(2, "push", "pushes") == "2 pushes"
      assert Words.plural(2, "entry", "entries") == "entries"
    end
  end

  describe "and_list/1" do
    test "joins as a sentence lists" do
      assert Words.and_list([]) == ""
      assert Words.and_list(["a"]) == "a"
      assert Words.and_list(["a", "b"]) == "a and b"
      assert Words.and_list(["a", "b", "c"]) == "a, b and c"
    end
  end
end
