defmodule Troupe.PromptCacheTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.{Anthropic, Fake, Message, Request}
  alias Troupe.Session.Log

  defp request(messages, opts \\ []) do
    %Request{
      model: "claude-opus-5",
      system: "stable system prompt",
      messages: messages,
      tools: [%{name: "read_file", description: "reads", input_schema: %{}}],
      cache: %{ttl: Keyword.get(opts, :ttl, "5m"), previous: Keyword.get(opts, :previous)}
    }
  end

  defp breakpoints(body) do
    system =
      case body.system do
        blocks when is_list(blocks) -> Enum.count(blocks, &Map.has_key?(&1, :cache_control))
        _string -> 0
      end

    messages =
      Enum.reduce(body.messages, 0, fn m, acc ->
        acc + Enum.count(m.content, &Map.has_key?(&1, :cache_control))
      end)

    system + messages
  end

  defp strip(body) do
    %{
      body
      | system: strip_system(body.system),
        messages:
          Enum.map(body.messages, fn m ->
            %{m | content: Enum.map(m.content, &Map.delete(&1, :cache_control))}
          end)
    }
  end

  defp strip_system(blocks) when is_list(blocks),
    do: Enum.map(blocks, &Map.delete(&1, :cache_control))

  defp strip_system(other), do: other

  defp turn(n) do
    [
      Message.assistant([Message.tool_use("t#{n}", "read_file", %{"path" => "a#{n}"})]),
      Message.user([Message.tool_result("t#{n}", "contents #{n}", false)])
    ]
  end

  test "the system block carries a breakpoint, so tools and system cache together" do
    body = Anthropic.encode(request([Message.user("go")]))

    assert [%{type: "text", text: "stable system prompt", cache_control: %{type: "ephemeral"}}] =
             body.system
  end

  test "the last stable block of the final message carries a breakpoint" do
    messages = [Message.user("go")] ++ turn(1)
    body = Anthropic.encode(request(messages))

    [last | _] = Enum.reverse(body.messages)
    assert [%{type: "tool_result", cache_control: %{type: "ephemeral"}}] = last.content
  end

  test "a volatile block sits after the breakpoint, never on it" do
    messages = [
      Message.user([Message.text_block("go"), Message.volatile_block("# task list\n- [pending] 1")])
    ]

    body = Anthropic.encode(request(messages))
    [only] = body.messages

    assert [%{type: "text", text: "go", cache_control: _}, volatile] = only.content
    refute Map.has_key?(volatile, :cache_control)
  end

  test "the previous request's position gets a second breakpoint, and never more than four" do
    messages = [Message.user("go")] ++ turn(1) ++ turn(2)
    body = Anthropic.encode(request(messages, previous: 2))

    assert breakpoints(body) == 3

    assert body.messages
           |> Enum.at(2)
           |> Map.fetch!(:content)
           |> hd()
           |> Map.has_key?(:cache_control)

    # A previous index equal to the last one is not marked twice.
    last = length(messages) - 1
    assert breakpoints(Anthropic.encode(request(messages, previous: last))) == 2
  end

  test "an out-of-range previous index is dropped rather than misplaced" do
    body = Anthropic.encode(request([Message.user("go")], previous: 42))
    assert breakpoints(body) == 2
  end

  test "a one-hour ttl is asked for on every breakpoint of a request or none" do
    messages = [Message.user("go")] ++ turn(1)
    body = Anthropic.encode(request(messages, ttl: "1h", previous: 0))

    controls =
      Enum.map(body.system, & &1.cache_control) ++
        Enum.flat_map(body.messages, fn m ->
          m.content |> Enum.map(&Map.get(&1, :cache_control)) |> Enum.reject(&is_nil/1)
        end)

    assert length(controls) == 3
    assert Enum.all?(controls, &(&1 == %{type: "ephemeral", ttl: "1h"}))
  end

  test "a compaction request pays no write premium it can never read back" do
    body = Anthropic.encode(%{request([Message.user("summarize")]) | purpose: :compaction})
    assert breakpoints(body) == 0
    assert body.system == "stable system prompt"
  end

  test "consecutive turns agree on tools, system and every earlier message" do
    first = Anthropic.encode(request([Message.user("go")] ++ turn(1), previous: 0))
    second = Anthropic.encode(request([Message.user("go")] ++ turn(1) ++ turn(2), previous: 2))

    assert breakpoints(first) <= 4
    assert breakpoints(second) <= 4

    a = strip(first)
    b = strip(second)

    assert a.tools == b.tools
    assert a.system == b.system
    assert a.model == b.model
    assert Enum.take(b.messages, length(a.messages)) == a.messages
  end

  describe "a live session" do
    test "the prompt prefix stays byte-identical across turns while tools run" do
      script = [
        {:tool, "read_file", %{"path" => "a.txt"}},
        {:tool, "read_file", %{"path" => "b.txt"}},
        {:finish, "done"}
      ]

      ws = tmp_workspace(%{"a.txt" => "alpha", "b.txt" => "beta"})
      {sid, fake, _ws} = start_session!(workspace: ws, script: script)

      {:ok, _} = Troupe.dispatch(sid, "code", "read both files")
      await_state("code-1", :done_unread, 10_000)

      requests = Fake.requests(fake) |> Enum.filter(&(&1.purpose == :turn))
      assert length(requests) >= 3

      [first | rest] = requests

      for next <- rest do
        assert next.tools == first.tools, "the tool list changed between turns"
        assert next.system == first.system, "the system prompt changed between turns"
        assert next.model == first.model
      end

      # History only grows, and only at the end: every earlier message is byte
      # identical, once the volatile tail each request rebuilds is removed.
      Enum.chunk_every(requests, 2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        a = stable(a.messages)
        b = stable(b.messages)
        assert Enum.take(b, length(a)) == a, "an earlier message was rewritten"
      end)

      # Per-turn state is not in the system prompt any more; that is what lets the
      # prefix above stay identical while the task list changes.
      refute first.system =~ "Current task list"
      assert first.system =~ "Large tool output"

      # The persisted log carries the usage the cache report is computed from.
      assert %{calls: calls} = Troupe.LLM.UsageLog.summary(Log.all(sid))
      assert calls >= 3
    end
  end

  defp stable(messages) do
    Enum.map(messages, fn %{role: role, content: content} ->
      %{role: role, content: Enum.reject(content, &Message.volatile?/1)}
    end)
  end
end
