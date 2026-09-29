defmodule Troupe.Tools.OutputTest do
  @moduledoc """
  A cut result says how much it left out, and the count is of what was actually left out:
  the cut goes back to a line boundary, and the bytes of the line it gave up count too.
  """

  use ExUnit.Case, async: true

  alias Troupe.Tools.Output

  @marker ~r/\[truncated: (\d+) more bytes\./
  @tail_marker ~r/\A\[truncated: (\d+) earlier bytes omitted\]\n\n/

  describe "cap/2" do
    test "counts the part of a line it cut back over as dropped" do
      # Ten lines of 11 bytes ("line 00...\n"); a limit of 25 lands in the third.
      text = Enum.map_join(0..9, "", &"line #{pad(&1)}...\n")
      capped = Output.cap(text, 25)

      [kept, _marker] = String.split(capped, "\n\n[truncated:")
      assert kept == "line 00...\nline 01..."
      assert [_, dropped] = Regex.run(@marker, capped)
      assert String.to_integer(dropped) == byte_size(text) - byte_size(kept)
    end

    test "a text with no newline in the kept part is cut at the limit" do
      text = String.duplicate("x", 100)
      capped = Output.cap(text, 40)

      assert String.starts_with?(capped, String.duplicate("x", 40) <> "\n\n")
      assert [_, "60"] = Regex.run(@marker, capped)
    end

    test "text that fits is untouched" do
      assert Output.cap("short\n", 40) == "short\n"
    end
  end

  describe "cap_tail/2" do
    test "counts the part of a line it cut forward over as dropped" do
      text = Enum.map_join(0..9, "", &"line #{pad(&1)}...\n")
      capped = Output.cap_tail(text, 25)

      assert [marker, dropped] = Regex.run(@tail_marker, capped)
      kept = String.replace_prefix(capped, marker, "")
      assert kept == "line 08...\nline 09...\n"
      assert String.to_integer(dropped) == byte_size(text) - byte_size(kept)
    end

    test "a text with no newline in the kept part keeps the last bytes" do
      text = String.duplicate("y", 100)
      capped = Output.cap_tail(text, 40)

      assert [_, "60"] = Regex.run(@tail_marker, capped)
      assert String.ends_with?(capped, "\n\n" <> String.duplicate("y", 40))
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
