defmodule Troupe.UsageTest do
  use ExUnit.Case, async: true

  alias Troupe.Agent.Budget
  alias Troupe.LLM.Provider
  alias Troupe.UI.TUI.Model

  defp anthropic_acc,
    do: %{
      blocks: %{},
      usage: Provider.empty_usage(),
      stop_reason: :end_turn,
      model: "claude-opus-5",
      reply_to: self(),
      ref: make_ref()
    }

  defp openai_acc,
    do: %{
      text: "",
      calls: %{},
      usage: Provider.empty_usage(),
      finish: nil,
      model: "gpt-5",
      reply_to: self(),
      ref: make_ref()
    }

  test "anthropic keeps its three input figures apart and disjoint" do
    start =
      Jason.encode!(%{
        "type" => "message_start",
        "message" => %{
          "model" => "claude-opus-5",
          "usage" => %{
            "input_tokens" => 120,
            "cache_read_input_tokens" => 148_000,
            "cache_creation_input_tokens" => 2_400
          }
        }
      })

    delta =
      Jason.encode!(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 3_100}
      })

    acc = Troupe.LLM.Anthropic.handle_event(nil, start, anthropic_acc())
    acc = Troupe.LLM.Anthropic.handle_event(nil, delta, acc)

    assert acc.usage == %{
             input_tokens: 120,
             output_tokens: 3_100,
             cache_read: 148_000,
             cache_write: 2_400
           }

    # the output count in message_delta must not wipe the input counts from message_start
    assert Provider.billed_input(acc.usage) == 2_520
    assert Provider.total_input(acc.usage) == 150_520
  end

  test "anthropic without caching reports no cache figures" do
    start =
      Jason.encode!(%{
        "type" => "message_start",
        "message" => %{"usage" => %{"input_tokens" => 90}}
      })

    acc = Troupe.LLM.Anthropic.handle_event(nil, start, anthropic_acc())
    assert acc.usage.cache_read == 0
    assert acc.usage.cache_write == 0
    assert Provider.billed_input(acc.usage) == 90
  end

  test "openai's prompt_tokens includes the cached ones, so they come back out of it" do
    chunk =
      Jason.encode!(%{
        "usage" => %{
          "prompt_tokens" => 150_000,
          "completion_tokens" => 3_100,
          "prompt_tokens_details" => %{"cached_tokens" => 148_000}
        }
      })

    acc = Troupe.LLM.OpenAI.handle_event(nil, chunk, openai_acc())

    assert acc.usage == %{
             input_tokens: 2_000,
             output_tokens: 3_100,
             cache_read: 148_000,
             cache_write: 0
           }

    # the prompt was still 150k long; only the price of it differs
    assert Provider.total_input(acc.usage) == 150_000
  end

  test "openai without a cache breakdown counts every prompt token as billed" do
    chunk = Jason.encode!(%{"usage" => %{"prompt_tokens" => 900, "completion_tokens" => 40}})
    acc = Troupe.LLM.OpenAI.handle_event(nil, chunk, openai_acc())
    assert acc.usage == %{input_tokens: 900, output_tokens: 40, cache_read: 0, cache_write: 0}
  end

  test "a budget spends on what was billed, not on what the cache served" do
    usage =
      Budget.add_usage(Budget.empty_usage(), %{
        turns: 1,
        input_tokens: 2_000,
        output_tokens: 3_100,
        cache_read: 148_000,
        cache_write: 2_400
      })

    assert usage == %{turns: 1, input_tokens: 4_400, output_tokens: 3_100}

    budget = %Budget{max_input_tokens: 100_000, max_output_tokens: 200_000, max_turns: 50}
    refute Budget.exhausted?(budget, usage, 0)
  end

  describe "display" do
    defp window(input, output, read, write),
      do: %{usage: %{input: input, output: output, cache_read: read, cache_write: write}}

    test "the compact form is sent and received, cache reads excluded" do
      assert Model.tokens(window(2_000, 3_100, 148_000, 2_400)) == "↑4.4k ↓3.1k"
      assert Model.tokens(window(120, 40, 0, 0)) == "↑120 ↓40"
    end

    test "the detail names what the cache served, and says nothing when it served nothing" do
      assert Model.token_detail(window(2_000, 3_100, 148_000, 2_400)) ==
               "↑ 4.4k sent · ↓ 3.1k received · 148.0k of the prompt came from cache"

      assert Model.token_detail(window(900, 40, 0, 0)) == "↑ 900 sent · ↓ 40 received"
    end

    test "the total still accounts for every token, cached input included" do
      assert Model.total_tokens(window(2_000, 3_100, 148_000, 2_400)) == 155_500
    end

    test "the side panel gets a line each, and no cache line when nothing was cached" do
      assert Model.token_lines(window(2_000, 3_100, 148_000, 2_400)) == [
               "↑ 4.4k sent",
               "↓ 3.1k received",
               "⟳ 148.0k from cache"
             ]

      assert Model.token_lines(window(900, 40, 0, 0)) == ["↑ 900 sent", "↓ 40 received"]
    end
  end

  test "a cached turn shows sent, received and cached in the activated pane" do
    import Troupe.TestHelpers
    import Troupe.TUIHelpers

    ws = tmp_workspace()

    cached = %{
      content: [Troupe.LLM.Message.text_block("read that for you")],
      usage: %{input_tokens: 2_000, output_tokens: 3_100, cache_read: 148_000, cache_write: 2_400},
      stop_reason: :end_turn
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: %{"code-1" => [cached]})
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read the docs")
    await_state("code-1", :done_unread)
    eventually(fn -> user_state(pid).model.windows["code-1"].usage.cache_read > 0 end)

    # the tile headline is the billed part only: 2k fresh + 2.4k cached-write
    assert screen_text(pid, session) =~ "↑4.4k ↓3.1k"

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "↑ 4.4k sent"
    assert text =~ "↓ 3.1k received"
    assert text =~ "⟳ 148.0k from cache"
  end
end
