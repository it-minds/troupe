defmodule Troupe.CompactClientTest do
  @moduledoc """
  `/compact` from the client's side: the session's conversation compacted now, between
  turns, through the daemon's `session.compact`. The compaction is the daemon's, written as
  `compacted` with `reason: "manual"`; the client answers on the notice line, and a refusal
  is the session's own sentence.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  test "/compact on a conversation with nothing old enough to summarise says why not" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    type(pid, "/compact")
    press(pid, "enter")

    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "there is too little to compact yet")) end)
    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end

  test "/compact summarises the older turns and the transcript says it was asked for" do
    turns = ["one", "two", "three", "four"]
    script = Enum.map(turns ++ ["summary"], &{:text_and_tools, "answer " <> &1, []})
    {sid, _, _} = start_session!(script: script)

    for turn <- turns do
      say!(sid, turn)
      await_state("root", :idle, 10_000)
    end

    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    type(pid, "/compact")
    press(pid, "enter")

    eventually(fn -> Enum.any?(notices(pid), &(&1 == "compacting the conversation")) end)

    eventually(
      fn ->
        Enum.any?(
          Client.events(sid),
          &(&1.type == :remote_note and &1.data.text == "context compacted, as /compact asked")
        )
      end,
      10_000
    )
  end

  defp notices(pid), do: user_state(pid).model.notices
end
