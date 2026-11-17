defmodule Troupe.Protocol.TextTest do
  @moduledoc """
  A cut to a byte size never leaves half a character behind.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Text

  test "text within the size is kept as it is" do
    assert Text.cut("", 4) == ""
    assert Text.cut("abc", 3) == "abc"
    assert Text.cut("abc", 10) == "abc"
  end

  test "a cut between characters keeps every byte before it" do
    assert Text.cut("abcdef", 3) == "abc"
    assert Text.cut("abc", 0) == ""
  end

  test "a cut inside a multibyte character drops the whole character" do
    # "é" is two bytes, "€" three, "😀" four.
    assert Text.cut("aé", 2) == "a"
    assert Text.cut("a€b", 3) == "a"
    assert Text.cut("a€b", 4) == "a€"
    assert Text.cut("😀😀", 7) == "😀"
  end

  test "a binary that is not UTF-8 is kept up to its first invalid byte" do
    assert Text.cut(<<"ab", 0xFF, "cd">>, 5) == "ab"
    assert Text.cut(<<0xFF, "ab">>, 3) == ""
  end
end
