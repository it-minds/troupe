Code.require_file("../../support/fake_openai.exs", __DIR__)

defmodule Troupe.Agent.BoundThinkingTest do
  @moduledoc """
  Anthropic's newest models bind a thinking block to the conversation it was made in: the
  model, the tools, the system prompt and every message before it (Decision 805). Troupe
  hands each block back, so what goes in front of one must not change after it, or an
  account the check is enforced for refuses every later call once and it is sent again
  without its thinking (issue #465).

  Two prefix changes that a stable system prompt (Decision 863) does not remove, against
  the stand-in as Claude Sonnet 5.5 asked with `thinking_binding: error` for the refusal an
  enforced account gets: the task list's tools offered at a long turn's eleventh call
  (issue #590, Decision 867), and the tail a compaction keeps, whose blocks were made in
  front of what the summary replaced (D92).
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Bench.Prefix
  alias Troupe.Test.FakeOpenAI

  @model "claude-sonnet-5-5"

  setup context do
    for n <- 1..20, do: write_file(context, "notes/#{n}.txt", "note #{n}\n")
    :ok
  end

  test "a turn of twelve calls on build is never refused, and its tools never change", context do
    reads = Enum.map(1..11, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]})
    stand_in = stand_in([{"read the notes", reads ++ [{:text, "Read all eleven."}]}])

    %{session: session} = start_session(context, config_overrides: overrides(stand_in))
    turn(session.id, "read the notes, one at a time")

    requests = FakeOpenAI.requests(stand_in)
    assert length(requests) == 12, inspect(Enum.map(requests, & &1.status))
    assert Enum.all?(requests, &(&1.status == 200 and &1.thinking == :kept))

    assert %{"model_calls" => 12, "tools_changes" => 0, "thinking_resent" => 0} =
             Prefix.count(Troupe.events(session.id))
  end

  test "Troupe.Bench.Prefix counts no tools change over a turn of twenty calls", context do
    reads = Enum.map(1..19, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]})
    stand_in = stand_in([{"read the notes", reads ++ [{:text, "Read them all."}]}])

    %{session: session} = start_session(context, config_overrides: overrides(stand_in))
    turn(session.id, "read the notes, one at a time")

    assert %{
             "model_calls" => 20,
             "system_changes" => 0,
             "tools_changes" => 0,
             "thinking_resent" => 0
           } = Prefix.count(Troupe.events(session.id))
  end

  # D92: a compaction keeps the last few messages as they were, thinking and all, behind a
  # summary of what came before. Each kept block was made in front of the messages the
  # summary replaced, so it is bound to a conversation the request no longer has.
  test "after a compaction in the middle of a turn no call is refused", context do
    reads = Enum.map(1..8, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]})
    stand_in = stand_in([{"read the notes", reads ++ [{:text, "Read them all."}]}])

    # The first call's prompt is about 4,000 of the stand-in's tokens (four bytes a token),
    # and each read adds about a hundred: the threshold falls a few calls in.
    overrides = overrides(stand_in) ++ [context_window: 5_400, compact_at: 0.8]
    %{session: session} = start_session(context, config_overrides: overrides)
    sid = session.id
    turn(sid, "read the notes, one at a time")
    Troupe.send_input(sid, "and again")
    await_event(sid, :turn_ended, 10_000)

    assert [compacted | _] = events_of_type(sid, "compacted")
    refute Enum.any?(compacted.data["conversation"], &thinking?/1)

    # The summariser's call among them: what it reads is written out as text, without the
    # blocks, which its conversation never held.
    requests = FakeOpenAI.requests(stand_in)
    refused = Enum.filter(requests, &(&1.status != 200))
    assert refused == [], "refused: #{inspect(Enum.map(refused, & &1.mismatch))}"
    assert %{"thinking_resent" => 0} = Prefix.count(Troupe.events(sid))
  end

  # Claude Opus 5 thinks unasked but does not bind its thinking (Decision 805), so the tail
  # a compaction keeps goes on with its reasoning. (The stand-in binds every model's, and
  # refuses those blocks once each; Anthropic's API does not, for this one.)
  test "a model that does not bind its thinking keeps the tail's", context do
    reads = Enum.map(1..8, &{:tools, [{"read_file", %{"path" => "notes/#{&1}.txt"}}]})
    stand_in = stand_in([{"read the notes", reads ++ [{:text, "Read them all."}]}])

    overrides =
      Keyword.drop(overrides(stand_in), [:thinking_binding, :model]) ++
        [model: "claude-opus-5", context_window: 5_400, compact_at: 0.8]

    %{session: session} = start_session(context, config_overrides: overrides)
    turn(session.id, "read the notes, one at a time")

    assert [compacted | _] = events_of_type(session.id, "compacted")
    assert Enum.any?(compacted.data["conversation"], &thinking?/1)
  end

  defp thinking?(message), do: Enum.any?(message["content"], &(&1["type"] == "reasoning"))

  defp stand_in(scripts) do
    stand_in = FakeOpenAI.start(scripts: scripts, first_token_ms: 0, done_ms: 0)
    on_exit(fn -> FakeOpenAI.stop(stand_in) end)
    stand_in
  end

  defp overrides(stand_in) do
    [
      provider: "anthropic",
      base_url: stand_in.url,
      api_key: "test-key",
      model: @model,
      thinking_binding: "error"
    ]
  end

  defp turn(sid, text) do
    Troupe.subscribe(sid)
    Troupe.send_input(sid, text)
    await_event(sid, :turn_ended, 15_000)
  end
end
