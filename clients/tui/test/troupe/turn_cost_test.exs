defmodule Troupe.TurnCostTest do
  @moduledoc """
  What a turn cost, shown when it ends (issue #389, Decision 139).

  The window's `↑ sent` is cumulative, and that is how "every turn costs 9M" was read: a
  person could not tell one expensive turn from a long session of cheap ones. The harness
  writes what each turn cost on the event that ends it (root Decision 769), and the window
  says it once, in one line under the turn, apart from the session's total and never as a
  stream of numbers while the turn runs.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  # 100 fresh tokens, 1,000 from the cache and one out, three times.
  @turn %{
    "calls" => 3,
    "input_tokens" => 300,
    "cache_read" => 3_000,
    "cache_write" => 0,
    "output_tokens" => 3,
    "cost_micros" => 37_500,
    "unpriced" => 0
  }

  test "a turn that ends says what its calls cost, in one line under it" do
    window = fold(turn("go", 3) ++ [ended(@turn)])

    assert last_line(window) ==
             {:system, "turn: 3 calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04"}
  end

  test "the line is the turn's and the window's count is the session's" do
    second = %{
      @turn
      | "calls" => 1,
        "input_tokens" => 100,
        "cache_read" => 1_000,
        "output_tokens" => 1
    }

    window = fold(turn("go", 3) ++ [ended(@turn)] ++ turn("again", 1) ++ [ended(second)])

    assert last_line(window) ==
             {:system, "turn: 1 call · ↑ 100 sent · 1.0k cached · ↓ 1 received · $0.04"}

    assert Model.tokens(window) == "↑400 ↓4"
    assert length(turn_lines(window)) == 2
  end

  test "nothing is said while the turn runs" do
    window = fold(turn("go", 3))
    assert turn_lines(window) == []
  end

  test "a cancelled turn and a finished agent say what they cost too" do
    cancelled = fold(turn("go", 1) ++ [wire("cancelled", %{"turn" => %{@turn | "calls" => 1}})])
    assert [{:system, "turn: 1 call ·" <> _}] = turn_lines(cancelled)

    done =
      fold(
        turn("go", 2) ++
          [
            wire("agent_done", %{
              "reason" => "finished",
              "summary" => "ok",
              "turn" => %{@turn | "calls" => 2}
            })
          ]
      )

    assert [{:system, "turn: 2 calls ·" <> _}] = turn_lines(done)
  end

  test "a turn nobody priced says so rather than that it was free" do
    window =
      fold(turn("go", 2) ++ [ended(%{@turn | "calls" => 2, "cost_micros" => 0, "unpriced" => 2})])

    assert {:system, "turn: 2 calls ·" <> rest} = last_line(window)
    assert String.ends_with?(rest, "· no price")

    some = fold(turn("go", 3) ++ [ended(%{@turn | "unpriced" => 1, "cost_micros" => 5_000})])
    assert {:system, line} = last_line(some)
    assert String.ends_with?(line, "· under a cent, 1 call unpriced")
  end

  test "the call that wrote a compaction's summary counts in the session's tokens too" do
    compacted =
      wire("compacted", %{
        "summary" => "the gist",
        "conversation" => [],
        "usage" => %{
          "input_tokens" => 900,
          "cache_read" => 0,
          "cache_write" => 0,
          "output_tokens" => 40
        },
        "gateway" => %{"cost_micros" => 2_000}
      })

    window = fold(turn("go", 2) ++ [compacted, ended(%{@turn | "calls" => 3})])

    assert Model.tokens(window) == "↑1.1k ↓42"
    assert window.agents["root"].usage.input == 1_100
    assert {:system, "turn: 3 calls ·" <> _} = last_line(window)

    # A compaction from before it said what the call used adds nothing.
    old =
      fold(turn("go", 1) ++ [wire("compacted", %{"summary" => "the gist", "conversation" => []})])

    assert Model.tokens(old) == "↑100 ↓1"
  end

  test "a log written before turns were counted ends its turns as it did" do
    window = fold(turn("go", 1) ++ [wire("turn_ended", %{})])
    assert turn_lines(window) == []
    assert window.state == :done_unread
  end

  defp turn(text, calls) do
    [wire("user_input", %{"source" => "user", "text" => text})] ++
      Enum.map(1..calls, fn n ->
        wire("llm_response", %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "step #{n}"}]
          },
          "usage" => %{
            "input_tokens" => 100,
            "cache_read" => 1_000,
            "cache_write" => 0,
            "output_tokens" => 1
          },
          "gateway" => %{"cost_micros" => 12_500}
        })
      end)
  end

  defp ended(turn), do: wire("turn_ended", %{"turn" => turn})

  defp wire(type, data),
    do: %{"type" => type, "agent" => ["root"], "data" => data, "ts" => "2026-10-04T10:00:00Z"}

  defp fold(wire_events) do
    {events, _memory} =
      wire_events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} -> Map.put(event, "seq", seq) end)
      |> Enum.flat_map_reduce(Translate.memory(), &Translate.durable("s-1", &1, &2))

    [window] = "s-1" |> Model.rebuild("/w", events) |> Model.windows()
    window
  end

  defp transcript(window), do: window.agents["root"].transcript

  defp last_line(window), do: List.last(transcript(window))

  defp turn_lines(window),
    do: Enum.filter(transcript(window), &match?({:system, "turn: " <> _}, &1))
end
