defmodule Troupe.Agent.CompactionTest do
  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Message, Text, ToolResult}
  alias Troupe.Session.Blobs

  @overflow {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

  test "crossing the context threshold summarises older turns and keeps working", context do
    # A tiny window so the fake's reported usage crosses the threshold immediately.
    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: [context_window: 120, compact_at: 0.5],
        steps: [
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"todo_read", %{}}]},
          {:tools, [{"todo_read", %{}}]},
          {:text, "here is a summary of everything that happened earlier"},
          {:text, "carrying on"}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "do several things")
    await_state(session.id, [:idle], 10_000)

    # Which scripted answer the summariser consumes depends on how many turns ran
    # before the threshold was crossed, so the assertion is on the shape: a summary
    # was produced, and it came from the summariser call.
    assert [compacted | _] = events_of_type(session.id, "compacted")
    assert is_binary(compacted.data["summary"])
    assert compacted.data["summary"] != ""

    conversation = Troupe.snapshot(session.id).conversation

    # The summary replaced the older turns rather than being appended to them.
    assert length(conversation) < 8
    assert Enum.any?(conversation, &(Message.text(&1) =~ "Summary of earlier work"))

    # The summariser call carries the summariser system prompt, not the agent's.
    summariser =
      fake
      |> Fake.requests()
      |> Enum.find(&(&1.system =~ "compress a coding session"))

    assert summariser, "expected a summariser request"
    assert summariser.tools == []
  end

  test "nothing old enough to summarise does not loop", context do
    %{session: session} =
      start_session(context,
        config_overrides: [context_window: 10, compact_at: 0.1],
        steps: [{:text, "short answer"}, {:text, "another"}]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hi")
    await_state(session.id, [:idle], 10_000)

    # With a two-message conversation there is nothing to drop, so the agent must
    # settle rather than compact repeatedly.
    assert events_of_type(session.id, "compacted") == []
    assert Troupe.snapshot(session.id).state == :idle
  end

  # Decision 771. The threshold is never crossed here; a prompt the provider refuses as too
  # long is what compacts, so the test says when. Two short turns come first, so the kept
  # part starts at the second one's input and the read and its answer are behind the
  # compaction.
  describe "a large tool result a compaction left behind" do
    setup context do
      lines = Enum.map_join(1..400, "\n", &"line #{&1} #{String.duplicate("x", 60)}")
      write_file(context, "big.txt", lines)
      :ok
    end

    test "goes to the model as a one-line stub naming read_output, which returns it whole",
         context do
      %{session: session, fake: fake} = start_session(context, steps: read_then_overflow())
      Troupe.subscribe(session.id)
      Enum.each(["first", "second", "read big.txt", "carry on"], &turn(session.id, &1))

      read = read_result(fake)
      assert byte_size(read.content) > Blobs.inline_limit()

      assert [%{data: %{"reason" => "context_overflow"}}] =
               events_of_type(session.id, "compacted")

      # The request after the compaction carries the stub, and nothing of the body.
      after_compaction = fake |> Fake.requests() |> List.last()
      stub = result_in(after_compaction, read.tool_use_id)
      id = Blobs.digest(read.content)

      refute stub.content =~ "\n"
      assert stub.content =~ "read_file"
      assert stub.content =~ ~s|read_output(id: "#{id}"|
      refute Enum.any?(texts(after_compaction), &(&1 =~ "line 400 "))

      # `read_output` returns what the model saw before, whole.
      Fake.push(fake, [
        {:tools, [{"read_output", %{"id" => id, "limit" => 1_000}}]},
        {:text, "seen it again"}
      ])

      turn(session.id, "show it again")

      paged = fake |> Fake.requests() |> List.last()
      assert [%ToolResult{content: whole} = again] = List.last(paged.messages).content
      assert whole == read.content
      assert result_in(paged, read.tool_use_id).content == stub.content

      # A result in the part since the compaction is sent whole on every later call, the
      # model's answer to it notwithstanding.
      turn(session.id, "anything else")
      later = fake |> Fake.requests() |> List.last()
      assert result_in(later, again.tool_use_id).content == read.content
    end

    test "a result the model has not answered yet is sent whole", context do
      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:tools, [{"read_file", %{"path" => "big.txt"}}]},
        @overflow,
        {:text, "summary of the first turn"},
        {:text, "read it"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three", "read big.txt"], &turn(session.id, &1))

      assert [_] = events_of_type(session.id, "compacted")
      [_, _, _, _, overflowed, _summariser, resent] = Fake.requests(fake)

      # The read was the last thing in the conversation when it was compacted, so the
      # request sent again after it carries the result exactly as the refused one did.
      assert [%ToolResult{} = read] = List.last(overflowed.messages).content
      assert byte_size(read.content) > Blobs.inline_limit()
      assert result_in(resent, read.tool_use_id).content == read.content
    end

    test "a restarted agent sends the same stub, and the log still holds the whole result",
         context do
      %{session: session, fake: fake} = start_session(context, steps: read_then_overflow())
      Troupe.subscribe(session.id)
      Enum.each(["first", "second", "read big.txt", "carry on"], &turn(session.id, &1))

      read = read_result(fake)
      before_restart = fake |> Fake.requests() |> List.last()
      conversation = Troupe.snapshot(session.id).conversation

      agent = Registry.agent_pid(session.id, ["root"])
      ref = Process.monitor(agent)
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000

      # The restarted agent says so and then publishes :idle from `init`, before any input.
      await_event(session.id, :agent_restarted)
      await_state(session.id, [:idle])

      # The fold of the log is the conversation the agent had, and the boundary with it.
      assert Troupe.snapshot(session.id).conversation == conversation
      turn(session.id, "after a restart")

      after_restart = fake |> Fake.requests() |> List.last()

      assert Enum.take(after_restart.messages, length(before_restart.messages)) ==
               before_restart.messages

      assert result_in(after_restart, read.tool_use_id).content =~ "read_output(id: "

      # The stub is in what was sent, not in what was kept: the log has the result whole.
      logged =
        session.id
        |> events_of_type("tool_results")
        |> Enum.flat_map(& &1.data["results"])
        |> Enum.flat_map(& &1["content"])
        |> Enum.find(&(&1["tool_use_id"] == read.tool_use_id))

      assert %{"blob" => blob} = logged["content"]
      assert blob == Blobs.digest(read.content)
      assert [compacted] = events_of_type(session.id, "compacted")
      assert Jason.encode!(compacted.data["conversation"]) =~ "line 400 "
    end
  end

  defp read_then_overflow do
    [
      {:text, "first answer"},
      {:text, "second answer"},
      {:tools, [{"read_file", %{"path" => "big.txt"}}]},
      {:text, "read it"},
      @overflow,
      {:text, "summary of the first turn"},
      {:text, "carried on"}
    ]
  end

  defp turn(session_id, text) do
    Troupe.send_input(session_id, text)
    await_state(session_id, [:idle], 10_000)
  end

  # The read's result as the model first saw it: the last message of the request after it.
  defp read_result(fake) do
    fake
    |> Fake.requests()
    |> Enum.find_value(fn request ->
      case List.last(request.messages) do
        %Message{content: [%ToolResult{} = result]} -> result
        _ -> nil
      end
    end)
  end

  defp result_in(request, tool_use_id) do
    Enum.find_value(request.messages, fn %Message{content: blocks} ->
      Enum.find(blocks, &match?(%ToolResult{tool_use_id: ^tool_use_id}, &1))
    end)
  end

  # Every text a request carries, tool results included.
  defp texts(request) do
    request.messages
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(fn
      %ToolResult{content: text} -> [text]
      %Text{text: text} -> [text]
      _other -> []
    end)
  end
end
