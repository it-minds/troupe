defmodule Troupe.Agent.OverflowRecoveryTest do
  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Message, ToolResult}
  alias Troupe.Session.Blobs

  # #1006. A model with a window the fake measures in bytes of the messages: a prompt past
  # it is refused as a provider refuses one too long, and takes no step from the script.
  # Each big file is past the size a stub is for, and two of them are past the window on
  # their own, so what a compaction keeps, the turn's own calls and results, does not fit.
  @window 40_000
  @overflow {:error, {:http_status, 400, "prompt is too long: 270000 tokens > 262144 maximum"}}

  setup context do
    write_file(context, "a.txt", lines(400, "a"))
    write_file(context, "b.txt", lines(400, "b"))
    :ok
  end

  describe "a turn whose own tool results do not fit the window" do
    test "is compacted, then sent with its large results left for read_output", context do
      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:tools, [{"read_file", %{"path" => "a.txt"}}, {"read_file", %{"path" => "b.txt"}}]},
        {:text, "summary of the first turns"},
        {:text, "read both"}
      ]

      %{session: session, fake: fake} =
        start_session(context, steps: steps, window_bytes: @window)

      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three", "read a.txt and b.txt"], &turn(session.id, &1))

      assert events_of_type(session.id, "llm_error") == []

      assert [%{data: %{"reason" => "context_overflow"}}] =
               events_of_type(session.id, "compacted")

      assert Message.text(List.last(Troupe.snapshot(session.id).conversation)) == "read both"

      # Refused whole, refused again compacted, then taken with both results as stubs.
      [refused, _summariser, compacted, taken] = fake |> Fake.requests() |> Enum.take(-4)
      assert [%ToolResult{} = a, %ToolResult{} = b] = results(List.last(refused.messages))
      assert results(List.last(compacted.messages)) == [a, b]

      for result <- [a, b] do
        assert byte_size(result.content) > Blobs.inline_limit()
        stub = result_in(taken, result.tool_use_id)
        assert stub.content =~ "left out: the prompt was too long"
        assert stub.content =~ ~s|read_output(id: "#{Blobs.digest(result.content)}"|
      end

      # The request that was taken says where the boundary went, and a later turn keeps it.
      assert [behind] =
               session.id
               |> events_of_type("llm_request")
               |> Enum.flat_map(&List.wrap(&1.data["behind"]))

      assert behind == length(Troupe.snapshot(session.id).conversation) - 1

      turn(session.id, "go on")
      later = fake |> Fake.requests() |> List.last()
      assert result_in(later, a.tool_use_id).content =~ "read_output(id: "
    end

    test "a restarted agent folds the boundary the refused prompt moved", context do
      steps = [
        {:tools, [{"read_file", %{"path" => "a.txt"}}, {"read_file", %{"path" => "b.txt"}}]},
        {:text, "read both"}
      ]

      %{session: session, fake: fake} =
        start_session(context, steps: steps, window_bytes: @window)

      Troupe.subscribe(session.id)

      # Too short to compact: the results are left out at once, without a summary.
      turn(session.id, "read a.txt and b.txt")
      assert events_of_type(session.id, "compacted") == []
      assert events_of_type(session.id, "llm_error") == []
      before_restart = fake |> Fake.requests() |> List.last()

      restart(session.id)
      turn(session.id, "after a restart")

      after_restart = fake |> Fake.requests() |> List.last()

      assert Enum.take(after_restart.messages, length(before_restart.messages)) ==
               before_restart.messages

      assert events_of_type(session.id, "llm_error") == []
    end

    test "fails with what to do when even that does not fit", context do
      # Refused whole, compacted, and with the results left out.
      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:tools, [{"read_file", %{"path" => "a.txt"}}, {"read_file", %{"path" => "b.txt"}}]},
        @overflow,
        {:text, "summary of the first turns"},
        @overflow,
        @overflow,
        {:text, "never sent"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three", "read a.txt and b.txt"], &turn(session.id, &1))

      assert [%{data: %{"reason" => reason}}] = events_of_type(session.id, "llm_error")
      assert reason =~ "the conversation no longer fits the model's context window"

      assert reason =~
               "this turn's own tool results do not fit the model's context window, even " <>
                 "after compacting; fetch less per call (fewer records, a narrower query), " <>
                 "or start a new session"

      refute reason =~ "compact_at"

      # The stubbed resend was tried before failing, and the guards went with the turn.
      last = fake |> Fake.requests() |> List.last()
      assert [_, _] = stubs = results(List.last(last.messages))
      assert Enum.all?(stubs, &(&1.content =~ "read_output(id: "))
    end

    test "fails with what to do when no result is large enough to leave out", context do
      # Five results under the size a stub is for, over the window together.
      for n <- 1..5, do: write_file(context, "s#{n}.txt", lines(150, "s#{n}"))
      reads = Enum.map(1..5, &{"read_file", %{"path" => "s#{&1}.txt"}})

      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:tools, reads},
        {:text, "summary of the first turns"},
        {:text, "never sent"}
      ]

      %{session: session} = start_session(context, steps: steps, window_bytes: @window)
      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three", "read the five files"], &turn(session.id, &1))

      assert [%{data: %{"reason" => reason}}] = events_of_type(session.id, "llm_error")
      assert reason =~ "this turn's own tool results do not fit the model's context window"
      refute reason =~ "already compacted once this turn"
    end
  end

  describe "a compaction a person asks for" do
    test "summarises now and rests, written as manual with its command_id", context do
      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:text, "four"},
        {:text, "the summary"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three", "four"], &turn(session.id, &1))

      assert :ok = Troupe.compact(session.id, nil, command_id: "c-compact")
      await_event(session.id, :compacted)
      await_state(session.id, [:idle], 10_000)

      assert [
               %{
                 data: %{
                   "reason" => "manual",
                   "command_id" => "c-compact",
                   "summary" => "the summary"
                 }
               }
             ] =
               events_of_type(session.id, "compacted")

      assert fake |> Fake.requests() |> List.last() |> Map.fetch!(:system) =~
               "compress a coding session"

      assert [%Message{} = said | _] = Troupe.snapshot(session.id).conversation
      assert Message.text(said) =~ "the summary"
    end

    test "is refused while there is too little to compact", context do
      # Three turns are six messages, what a compaction keeps.
      %{session: session} =
        start_session(context, steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}])

      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three"], &turn(session.id, &1))

      assert {:error, :too_little} = Troupe.compact(session.id)
      assert events_of_type(session.id, "compacted") == []
    end

    test "is refused while a turn runs", context do
      %{session: session} = start_session(context, steps: [{:delay, 1_000, {:text, "slow"}}])
      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "take your time")
      await_state(session.id, [:thinking])

      assert {:error, :busy} = Troupe.compact(session.id)
      await_state(session.id, [:idle], 10_000)
    end

    # A cancel while it summarises leaves nothing of it for the next compaction to write.
    test "cancelled, leaves no reason or command_id to a compaction after it", context do
      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        {:text, "four"},
        {:delay, 60_000, {:text, "never read"}},
        @overflow,
        {:text, "the summary"},
        {:text, "carried on"}
      ]

      %{session: session} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["one", "two", "three", "four"], &turn(session.id, &1))

      assert :ok = Troupe.compact(session.id, nil, command_id: "c-compact")
      await_state(session.id, [:compacting])
      :ok = Troupe.cancel(session.id)
      await_state(session.id, [:idle], 10_000)

      turn(session.id, "five")

      assert [%{data: data, actor: actor}] = events_of_type(session.id, "compacted")
      assert data["reason"] == "context_overflow"
      refute Map.has_key?(data, "command_id")
      assert actor.kind == :system
    end
  end

  defp lines(count, tag),
    do: Enum.map_join(1..count, "\n", &"#{tag} line #{&1} #{String.duplicate("x", 60)}")

  defp turn(session_id, text) do
    Troupe.send_input(session_id, text)
    await_state(session_id, [:idle], 10_000)
  end

  defp restart(session_id) do
    agent = Registry.agent_pid(session_id, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
    await_event(session_id, :agent_restarted)
    await_state(session_id, [:idle])
  end

  defp results(%Message{content: blocks}), do: Enum.filter(blocks, &match?(%ToolResult{}, &1))

  defp result_in(request, tool_use_id) do
    Enum.find_value(request.messages, fn %Message{content: blocks} ->
      Enum.find(blocks, &match?(%ToolResult{tool_use_id: ^tool_use_id}, &1))
    end)
  end
end
