defmodule Troupe.Gateway.CollaborationTest do
  @moduledoc """
  Stage 4, done items 1 and 2: several harnesses attached to one session.

  The claim being tested is narrow and load-bearing: **the log order is the single
  order**. There is no sequencer, no clock and no merge — every input becomes a message
  in the session actor's mailbox, and the order that mailbox takes them in is the order
  everybody sees. Two clients hammering the same session is the way to find out whether
  that is true or merely intended.

  The second done item is a negative one, and the more important of the two: presence
  must reach other clients and must never reach the log. It is on the spec's Forbidden
  list, so it is asserted from both ends — what the other client saw, and what the
  durable log contains afterwards.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Session.Log

  @ada "ada@example.test"
  @bob "bob@example.test"

  @inputs 100

  describe "one order, two harnesses" do
    @tag timeout: 180_000
    test "200 concurrent inputs land in one order that both clients agree on", context do
      # Two hundred turns needs a turn budget that allows two hundred turns; the default
      # forty is a guard against a runaway agent, not against a busy conversation.
      %{session: session} =
        start_session(context,
          default: {:text, "ok"},
          config: [auto_approve: true, max_turns: 1_000]
        )

      # Each client gets its own collector, because "both observe the identical order"
      # is a claim about two independent receivers and not about one list read twice.
      ada_events = collector(context, @ada, session.id)
      bob_events = collector(context, @bob, session.id)

      commands = send_concurrently(context, session.id)

      # Every input is accepted exactly once, and the run is over when the last one is.
      expected = MapSet.new(commands, & &1.command_id)

      ada_seen = await_accepted(ada_events, expected)
      bob_seen = await_accepted(bob_events, expected)

      accepted = Enum.filter(ada_seen, &(&1.type == "input_accepted"))

      assert length(accepted) == 2 * @inputs,
             "expected #{2 * @inputs} input_accepted, got #{length(accepted)}"

      assert Enum.map(accepted, & &1.data["command_id"]) |> Enum.uniq() |> length() ==
               2 * @inputs,
             "a command_id was accepted twice, which is a lost idempotency guarantee"

      # The single order. Compared over durable events only — ephemerals are droppable by
      # design — and over the part both have reached: one client being a few events
      # behind the other is lag, not disagreement. Disagreement would be a difference
      # inside the prefix they have both seen.
      ada_order = durable_order(ada_seen)
      bob_order = durable_order(bob_seen)
      common = min(length(ada_order), length(bob_order))

      assert common >= 2 * @inputs, "only #{common} durable events reached both clients"
      assert Enum.take(ada_order, common) == Enum.take(bob_order, common)

      # And it is one contiguous run of sequence numbers, so neither client is agreeing
      # about an order it has holes in.
      seqs = ada_order |> Enum.take(common) |> Enum.map(&elem(&1, 0))
      assert seqs == Enum.to_list(hd(seqs)..List.last(seqs))

      # And the author of each input is the client that sent it, not whoever the
      # session happens to belong to.
      by_command = Map.new(accepted, &{&1.data["command_id"], &1.data["author"]})

      for %{command_id: id, author: author} <- commands do
        assert Map.fetch!(by_command, id) == author,
               "#{id} was attributed to #{inspect(Map.get(by_command, id))}, not #{author}"
      end

      # Optimistic render reconciles: every command_id a client sent came back, and
      # the acknowledgement it got named the same command.
      for %{command_id: id, ack: ack} <- commands do
        assert ack["command_id"] == id
        assert ack["accepted"] == true
      end
    end

    test "an input sent while the agent is busy is queued, visibly, exactly once", context do
      # One slow turn, so the second input has somewhere to wait.
      %{session: session} = start_session(context, delay_ms: 400, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      first = Client.command_id()
      second = Client.command_id()

      {:ok, _} = input(ada, session.id, "the slow one", first)
      # Sent while the first turn is still running, which is what makes it queue.
      Process.sleep(100)
      {:ok, _} = input(ada, session.id, "the queued one", second)

      events =
        collect("session:#{session.id}", fn event ->
          event.type == "input_accepted" and event.data["command_id"] == second
        end)

      queued = Enum.filter(events, &(&1.type == "input_queued"))

      assert Enum.map(queued, & &1.data["command_id"]) == [second],
             "expected exactly one input_queued, for the second input"

      assert hd(queued).data["author"] == @ada
      assert hd(queued).data["text"] == "the queued one"

      # Queued before accepted: the person who typed it saw it waiting, then saw it taken.
      assert position(events, "input_queued", second) < position(events, "input_accepted", second)
    end

    test "any control client can cancel a turn, whoever started it", context do
      %{session: session} = start_session(context, delay_ms: 2_000, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      {:ok, _} = input(ada, session.id, "something long", Client.command_id())

      assert {:ok, %{"accepted" => true}} =
               Client.call(bob, "turn.cancel", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id
               })

      events = collect("session:#{session.id}", &(&1.type == "cancelled"))
      assert Enum.any?(events, &(&1.type == "cancelled")), "bob's cancel never reached the agent"
    end

    test "an observer cannot steer", context do
      %{session: session} = start_session(context, default: {:text, "ok"})
      watcher = attach(context, @bob <> "#observe")

      assert {:error, error} = input(watcher, session.id, "let me in", Client.command_id())
      assert error.message == "forbidden"
    end
  end

  describe "presence" do
    test "reaches other clients and never appears in the durable log", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      assert {:ok, %{"accepted" => true}} =
               Client.call(ada, "presence.set", %{
                 "session_id" => session.id,
                 "state" => "typing",
                 "agent" => ["root"]
               })

      # Bob's own subscription announced Bob arriving, so the assertion names the one
      # under test rather than the first presence event to turn up.
      assert_receive {:troupe_event, _topic, _id,
                      %Event{type: "presence", data: %{"state" => "typing"}} = event},
                     5_000

      assert event.data["subject"] == @ada
      assert event.data["agent"] == ["root"]

      # The whole point of the done item: no seq, so it cannot be in a replay...
      assert event.seq == nil
      assert event.ephemeral?

      # ...and it cannot be in a replay, because it has no seq to replay from. Checked
      # over every presence event a fresh client sees while replaying from the
      # beginning — the live ones its own arrival produces included.
      seen = replayed(context, session.id)
      presence = Enum.filter(seen, &(&1.type == "presence"))

      assert presence != [], "no presence events at all; this assertion is proving nothing"

      for event <- presence do
        assert event.seq == nil, "a presence event carried a seq, so a replay would contain it"
        assert event.ephemeral?
      end

      # And from the server's own store, which is the log a new pod would read.
      types = session.id |> Log.replay() |> Enum.map(& &1.type)
      refute "presence" in types, "presence reached the durable log, which the spec forbids"
    end

    test "a client that goes away leaves, and the others are told", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)
      {:ok, _} = Client.subscribe(ada, "session:#{session.id}", from_seq: 0)

      assert_receive {:troupe_event, _t, _i, %Event{type: "presence", data: %{"state" => "joined"}}},
                     5_000

      Client.close(ada)

      assert_receive {:troupe_event, _t, _i, %Event{type: "presence", data: %{"state" => "left"}} = left},
                     5_000

      assert left.data["subject"] == @ada
    end
  end

  describe "approvals with two people watching" do
    test "first response wins and the loser is told who got there first", context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"write_file", %{"path" => "a.txt", "content" => "hi"}}]}],
          default: {:text, "done"},
          config: [auto_approve: false]
        )

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      {:ok, _} = input(ada, session.id, "write the file", Client.command_id())

      assert_receive {:troupe_event, _t, _i, %Event{type: "approval_requested"} = request}, 10_000
      call_id = request.data["call_id"]

      {:ok, _} = respond(ada, session.id, call_id, "allow")
      {:ok, _} = respond(bob, session.id, call_id, "deny")

      events = collect("session:#{session.id}", &(&1.type == "approval_resolved"))

      decided = Enum.find(events, &(&1.type == "approval_decided"))
      resolved = Enum.find(events, &(&1.type == "approval_resolved"))

      assert decided.data["decision"] == "allow", "the second answer changed the decision"
      assert resolved.data["call_id"] == call_id
      assert resolved.data["resolved_by"] == @ada
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp input(client, session_id, text, command_id) do
    Client.call(client, "input.send", %{
      "command_id" => command_id,
      "session_id" => session_id,
      "text" => text
    })
  end

  defp respond(client, session_id, call_id, decision) do
    Client.call(client, "approval.respond", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "call_id" => call_id,
      "decision" => decision
    })
  end

  # Each client's events are collected in a process of its own, so what each one saw is
  # genuinely independent rather than two views of one mailbox.
  defp collector(context, subject, session_id) do
    test = self()
    topic = "session:#{session_id}"

    pid =
      spawn_link(fn ->
        send(test, {:ready, self()})
        gather(topic, [])
      end)

    receive do
      {:ready, ^pid} -> :ok
    after
      5_000 -> flunk("collector never started")
    end

    client = attach(context, subject, owner: pid)
    {:ok, _} = Client.subscribe(client, topic, from_seq: 0)
    pid
  end

  defp gather(topic, acc) do
    receive do
      {:troupe_event, ^topic, _id, event} ->
        gather(topic, [event | acc])

      {:events, from, reference} ->
        send(from, {:events, reference, Enum.reverse(acc)})
        gather(topic, acc)
    end
  end

  defp events_of(collector) do
    reference = make_ref()
    send(collector, {:events, self(), reference})

    receive do
      {:events, ^reference, events} -> events
    after
      5_000 -> flunk("collector did not answer")
    end
  end

  defp await_accepted(collector, expected) do
    deadline = System.monotonic_time(:millisecond) + 120_000
    do_await_accepted(collector, expected, deadline)
  end

  defp do_await_accepted(collector, expected, deadline) do
    events = events_of(collector)

    seen =
      for %{type: "input_accepted", data: data} <- events, into: MapSet.new(), do: data["command_id"]

    cond do
      MapSet.subset?(expected, seen) ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("only #{MapSet.size(seen)} of #{MapSet.size(expected)} inputs were accepted")

      true ->
        Process.sleep(50)
        do_await_accepted(collector, expected, deadline)
    end
  end

  # Two clients, each sending its own hundred as fast as it can, on its own connection.
  defp send_concurrently(context, session_id) do
    [@ada, @bob]
    |> Task.async_stream(
      fn subject ->
        client = attach(context, subject)

        for n <- 1..@inputs do
          command_id = "#{subject}-#{n}"
          {:ok, ack} = input(client, session_id, "#{subject} says #{n}", command_id)
          %{command_id: command_id, author: subject, ack: ack}
        end
      end,
      timeout: 120_000,
      max_concurrency: 2
    )
    |> Enum.flat_map(fn {:ok, sent} -> sent end)
  end

  defp durable_order(events) do
    for %{seq: seq} = event when is_integer(seq) <- events, do: {seq, event.type}
  end

  # A fresh client, replaying from the beginning into a process of its own, which is
  # what a reconnecting harness does and the only honest way to ask what is in the log.
  defp replayed(context, session_id) do
    collector = collector(context, "replay@example.test", session_id)
    eventually(fn -> events_of(collector) != [] end)
    Process.sleep(200)
    events_of(collector)
  end

  defp position(events, type, command_id) do
    Enum.find_index(events, &(&1.type == type and &1.data["command_id"] == command_id))
  end
end
