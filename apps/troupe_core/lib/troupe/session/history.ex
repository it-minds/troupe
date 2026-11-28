defmodule Troupe.Session.History do
  @moduledoc """
  Where a page of history is cut: the rule `session.events` with `before` answers by.

  The page begins where a turn begins, after the root's rest (`Checkpoint.rest?/1`) or at
  the session's start, so it never holds a reply without the line it answers, and the next
  page, asked before its first seq, ends at that rest. Where the last `limit` events begin
  mid-turn, the page starts after the first rest in them; where they hold none but their
  last (a turn longer than the page), it reaches back to the rest before that turn, up to
  5,000 events.

  Pure but for `read`, which answers the durable events after a seq and before another,
  oldest first: the plane's is the session's log (`Troupe.events_between/3`), a fake
  plane's the list it holds. Either way the rule is this one, and only the events from the
  one before the page's first to `before` are read.
  """

  alias Troupe.Protocol.Event
  alias Troupe.Session.Checkpoint

  # The most events one page carries when a single turn is longer than the page asked
  # for: ten of the largest page, so an answer stays a bounded read and frame. A turn
  # longer still is answered in pieces this long, cut where the count falls.
  @turn_cap 5_000

  @typedoc "The durable events after the first seq and before the second, oldest first."
  @type read :: (non_neg_integer(), pos_integer() -> [Event.t()])

  @doc """
  About `limit` durable events before `before`, oldest first, cut at a turn as the
  moduledoc says, and whether there are more before those.
  """
  @spec page(read(), pos_integer(), pos_integer()) :: {[Event.t()], boolean()}
  def page(read, before, limit) do
    lowest = max(before - limit, 1)
    # The page's raw events, and the one just before them, which says whether they begin a turn.
    {head, page} =
      read.(max(lowest - 2, 0), before)
      |> Enum.split_with(&(&1.seq < lowest))

    if lowest == 1 or Enum.any?(head, &Checkpoint.rest?/1) do
      {page, lowest > 1}
    else
      case page |> Enum.drop(-1) |> Enum.find_index(&Checkpoint.rest?/1) do
        nil -> whole_turn(read, page, lowest, limit)
        index -> {Enum.drop(page, index + 1), true}
      end
    end
  end

  # A page with no rest in it but its last: reach back a window at a time, each twice the
  # last, to the rest the turn began after, the session's start, or the cap.
  defp whole_turn(read, page, lowest, window) do
    room = @turn_cap - length(page)
    from = max(lowest - 1 - min(window, room), 0)
    earlier = read.(from, lowest)

    case earlier |> Enum.reverse() |> Enum.find_index(&Checkpoint.rest?/1) do
      nil when from == 0 ->
        {earlier ++ page, false}

      nil when room <= window ->
        {earlier ++ page, true}

      nil ->
        whole_turn(read, earlier ++ page, from + 1, window * 2)

      index ->
        {Enum.take(earlier, -index) ++ page, true}
    end
  end
end
