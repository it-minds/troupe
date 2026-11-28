defmodule Troupe.Session.HistoryTest do
  @moduledoc """
  `Troupe.Session.History.page/3` over a list, as a fake plane calls it: the rule is the
  plane's, and the reader is all that differs.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Event
  alias Troupe.Session.History

  # Turns of `lengths` events each, every one ending at the root's rest, from seq 1.
  defp log(lengths) do
    lengths
    |> Enum.flat_map(fn n -> List.duplicate("llm_response", n - 1) ++ ["turn_ended"] end)
    |> Enum.with_index(1)
    |> Enum.map(fn {type, seq} -> %Event{seq: seq, agent: ["root"], type: type, data: %{}} end)
  end

  defp page(events, before, limit) do
    me = self()

    read = fn from, below ->
      send(me, {:read, from, below})
      Enum.filter(events, &(&1.seq > from and &1.seq < below))
    end

    {page, more} = History.page(read, before, limit)
    {Enum.map(page, & &1.seq), more}
  end

  test "a page whose event before it is a rest is the page asked for" do
    # Turns 1-5, 6-10, 11-15.
    assert page(log([5, 5, 5]), 16, 5) == {Enum.to_list(11..15), true}
    assert_received {:read, 9, 16}
  end

  test "a page that begins mid-turn starts after its first rest, shorter than asked" do
    assert page(log([5, 5, 5]), 16, 7) == {Enum.to_list(11..15), true}
  end

  test "a turn longer than the page comes whole, and the first turn says there is no more" do
    events = log([3, 12, 2])
    assert page(events, 18, 3) == {[16, 17], true}
    assert page(events, 16, 3) == {Enum.to_list(4..15), true}
    assert page(events, 4, 3) == {[1, 2, 3], false}
  end

  test "a turn longer than the cap is answered in pieces, saying there is more" do
    events = log([2, 6_000])
    {seqs, more} = page(events, 6_003, 10)
    assert length(seqs) == 5_000
    assert List.last(seqs) == 6_002
    assert more
  end
end
