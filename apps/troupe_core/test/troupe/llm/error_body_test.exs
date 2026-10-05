defmodule Troupe.LLM.ErrorBodyTest do
  @moduledoc """
  A provider's error over a real connection reaches the agent with what it said (#436,
  Decision 791). Req hands the body of every response to the adapter's `into` function,
  whatever its status, so an error's body went to the event-stream parser and the adapter
  read an empty one: a context overflow was a bare 400 and never compacted (Decision 659),
  and every 4xx a person saw said only "the provider answered 400".
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Message
  alias Troupe.Test.ErrorStandIn

  # What each provider answers a prompt longer than the model's context window.
  @anthropic_overflow %{
    "type" => "error",
    "error" => %{
      "type" => "invalid_request_error",
      "message" => "prompt is too long: 208310 tokens > 200000 maximum"
    }
  }

  @openai_overflow %{
    "error" => %{
      "message" =>
        "This model's maximum context length is 128000 tokens. However, your messages " <>
          "resulted in 130412 tokens. Please reduce the length of the messages.",
      "type" => "invalid_request_error",
      "param" => "messages",
      "code" => "context_length_exceeded"
    }
  }

  # The key the session's requests carry, as long as a real one.
  @key "sk-stand-in-0123456789abcdef"

  describe "a context overflow over the wire" do
    test "Anthropic's prompt is too long is compacted and the turn sent again", context do
      assert_compacts(context, "anthropic", "claude-sonnet-5", @anthropic_overflow)
    end

    test "an OpenAI-compatible server's context_length_exceeded is compacted and sent again",
         context do
      assert_compacts(context, "openai", "gpt-test", @openai_overflow)
    end
  end

  describe "a 400 with a message" do
    test "from Anthropic is said to the person in the provider's words", context do
      body = %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "tools.0.input_schema: JSON schema is invalid"
        }
      }

      assert failed(context, "anthropic", "claude-sonnet-5", {:status, 400, body}) ==
               "the provider answered 400 (tools.0.input_schema: JSON schema is invalid)"
    end

    test "from an OpenAI-compatible server likewise", context do
      body = %{
        "error" => %{
          "message" => "Invalid schema for function 'read_file': 'path' is not of type 'object'.",
          "type" => "invalid_request_error",
          "param" => "tools[0].function.parameters",
          "code" => "invalid_function_parameters"
        }
      }

      assert failed(context, "openai", "gpt-test", {:status, 400, body}) ==
               "the provider answered 400 (Invalid schema for function 'read_file': " <>
                 "'path' is not of type 'object'.)"
    end
  end

  # What the person reads also goes into the conversation, and so to the provider again,
  # and into the session's log.
  test "a key the provider says back is not repeated, and the message is trimmed", context do
    body = %{
      "error" => %{
        "message" => "  Incorrect API key provided: #{@key}.\n",
        "type" => "invalid_request_error",
        "code" => "invalid_api_key"
      }
    }

    reason = failed(context, "openai", "gpt-test", {:status, 401, body})

    refute reason =~ @key

    assert reason ==
             "the provider rejected the credentials (Incorrect API key provided: sk-s...ef.)"
  end

  # Four reads make a conversation long enough to compact; the fifth call is refused as too
  # long, and a conversation with the summary in it is answered.
  defp assert_compacts(context, provider, model, overflow) do
    write_file(context, "notes.txt", "the parser reads a tab as two spaces\n")

    script = fn _n, body ->
      cond do
        summariser?(body) -> {:text, "summary of the reads"}
        Jason.encode!(body) =~ "summary of the reads" -> {:text, "done"}
        answers(body) < 4 -> {:tool, "read_file", %{"path" => "notes.txt"}}
        true -> {:status, 400, overflow}
      end
    end

    sid = run(context, provider, model, script)
    await_state(sid, [:idle], 15_000)

    assert events_of_type(sid, "llm_error") == []
    assert [%{data: %{"reason" => "context_overflow"}}] = events_of_type(sid, "compacted")
    assert Message.text(List.last(Troupe.snapshot(sid).conversation)) == "done"

    # Four reads, the call refused, the summary, and the same turn sent again, shorter.
    calls = ErrorStandIn.drain()
    assert length(calls) == 7
    {5, _path, refused} = Enum.at(calls, 4)
    {7, _path, resent} = Enum.at(calls, 6)
    assert length(resent["messages"]) < length(refused["messages"])
  end

  defp failed(context, provider, model, answer) do
    sid = run(context, provider, model, fn _n, _body -> answer end)
    error = await_event(sid, :llm_error, 15_000)
    await_state(sid, [:idle], 15_000)
    error.data["reason"]
  end

  defp run(context, provider, model, script) do
    stand_in = ErrorStandIn.start(script: script)
    on_exit(fn -> ErrorStandIn.stop(stand_in) end)

    %{session: session} =
      start_session(context,
        config_overrides: [
          provider: provider,
          model: model,
          base_url: stand_in.base_url,
          api_key: @key
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "read the notes four times")
    session.id
  end

  defp summariser?(body) do
    system =
      case body["system"] do
        nil -> body["messages"] |> List.first() |> Map.get("content")
        text when is_binary(text) -> text
        blocks -> Enum.map_join(blocks, & &1["text"])
      end

    is_binary(system) and system =~ "compress a coding session"
  end

  defp answers(body), do: Enum.count(body["messages"], &(&1["role"] == "assistant"))
end
