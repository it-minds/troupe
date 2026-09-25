defmodule Troupe.Session.SessionIdTest do
  @moduledoc """
  A session id is a name and never a pattern.

  A dormant session is found by globbing `<state>/sessions/*/<id>/events.jsonl`, and the
  id went into that glob as it was given (#97): `*` matched whichever session's log came
  first on disk, and `?`, `[…]` or `{…}` matched a session whose id the caller did not
  have. The protocol edge now refuses anything that is not the shape
  `Troupe.Session.generate_id/0` gives. These check that shape, and that the lookups
  behind the edge read an id literally even if one reaches them some other way.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session
  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  test "every id the harness generates has the shape it is checked against" do
    for _ <- 1..500, do: assert(Session.valid_id?(Session.generate_id()))
  end

  test "a wildcard, a parent directory, a separator or any other shape is not a session id" do
    id = Session.generate_id()

    bad = [
      "*",
      id <> "*",
      String.slice(id, 0..-2//1) <> "?",
      "[" <> String.first(id) <> "]" <> String.slice(id, 1..-1//1),
      "{" <> id <> ",none}",
      "..",
      "../" <> id,
      "..\\" <> id,
      id <> "/",
      "/" <> id,
      id <> "\n",
      " " <> id,
      "",
      "s-1",
      nil,
      42
    ]

    assert Enum.filter(bad, &Session.valid_id?/1) == []
  end

  test "a lookup reads the id literally, so a pattern finds no session and a real id does",
       context do
    %{session: session} = start_session(context, steps: [{:text, "hi"}])
    :ok = Troupe.stop_session(session.id)
    id = session.id

    index =
      start_supervised!(%{
        id: Index,
        start:
          {GenServer, :start_link,
           [Index, [state_dir: context.state_dir, session_idle_ms: :infinity]]}
      })

    patterns = [
      "*",
      String.slice(id, 0..-2//1) <> "?",
      "[" <> String.first(id) <> "]" <> String.slice(id, 1..-1//1),
      "{" <> id <> ",none}"
    ]

    for pattern <- patterns do
      assert Log.locate(pattern, context.state_dir) == nil, "#{pattern} found a log"
      assert Log.read_session(pattern, context.state_dir) == []
      assert GenServer.call(index, {:get, pattern}) == nil, "#{pattern} found a session"
    end

    assert Log.locate(id, context.state_dir)
    assert %{id: ^id, state: :dormant} = GenServer.call(index, {:get, id})
  end
end
