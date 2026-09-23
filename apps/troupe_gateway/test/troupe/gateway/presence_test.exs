defmodule Troupe.Gateway.PresenceTest do
  @moduledoc """
  Presence as a topic of its own, beside `fleet` and `session:<id>`.

  Who is looking at a session is true while somebody is there and worthless a minute
  later. It has no sequence, it is never written down, and a subscriber who missed some of
  it has missed nothing — three properties the session's own stream has none of, which is
  the case for it being a separate subscription rather than a kind of event on that one.

  The done item that matters is the last: **with the outbound queue saturated, presence
  stops entirely and the event order is still identical on both clients.** Presence riding
  the session topic is presence a client cannot decline and a server cannot shed without
  touching the session's own stream. On a topic of its own, shedding it is a decision about
  one subscription, and the durable order of everything else is exactly what it would have
  been — which is the difference between a pressure valve and a data loss.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Gateway.{Connection, Connections}
  alias Troupe.Session.Log

  @ada "ada@example.test"
  @bob "bob@example.test"
  @stalled "cyd@example.test"

  @moduletag timeout: 120_000

  describe "a topic of its own" do
    test "presence arrives there and nowhere else", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)

      # Bob watches the session only. Under the old shape this is where presence arrived.
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)

      {:ok, _} =
        Client.call(ada, "presence.set", %{
          "session_id" => session.id,
          "state" => "typing",
          "agent" => ["root"]
        })

      # Something durable, after it, so the absence below is an absence rather than a race
      # with a message that had not arrived yet.
      {:ok, _} =
        Client.call(ada, "input.send", %{
          "command_id" => Client.command_id(),
          "session_id" => session.id,
          "text" => "hello"
        })

      assert_receive {:troupe_event, _topic, _id, %Event{type: "input_accepted"}}, 10_000

      refute_received {:troupe_event, _t, _i, %Event{type: "presence"}}

      # And on the presence topic it is exactly what it always was.
      {:ok, subscribed} = Client.subscribe(bob, "presence:#{session.id}")

      # Nothing to be at a point in, and the answer says so rather than handing back a
      # number that means nothing here.
      assert subscribed["head_seq"] == 0
      assert subscribed["cursored"] == false

      {:ok, _} =
        Client.call(ada, "presence.set", %{
          "session_id" => session.id,
          "state" => "typing",
          "agent" => ["root"]
        })

      assert_receive {:troupe_event, topic, _id,
                      %Event{type: "presence", data: %{"state" => "typing"}} = event},
                     5_000

      assert topic == "presence:#{session.id}"
      assert event.data["subject"] == @ada
      assert event.data["agent"] == ["root"]
      assert is_nil(event.seq)
      assert event.ephemeral?
    end

    test "two clients see each other within 500 ms", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "presence:#{session.id}")

      # Ada's own subscription announces her arriving, so the clock starts before it and
      # the measurement includes the round trip a real client pays.
      started = System.monotonic_time(:millisecond)
      {:ok, _} = Client.subscribe(ada, "presence:#{session.id}")

      assert_receive {:troupe_event, _t, _i,
                      %Event{
                        type: "presence",
                        data: %{"state" => "joined", "subject" => @ada}
                      }},
                     2_000

      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 500,
             "presence took #{elapsed}ms to cross, and the budget is 500ms"
    end

    test "is not delivered twice to somebody watching both", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "session:#{session.id}", from_seq: 0)
      {:ok, _} = Client.subscribe(bob, "presence:#{session.id}")

      {:ok, _} =
        Client.call(ada, "presence.set", %{"session_id" => session.id, "state" => "typing"})

      assert_receive {:troupe_event, _t, _i,
                      %Event{type: "presence", data: %{"subject" => @ada, "state" => "typing"}}},
                     5_000

      # Once, not once per subscription. A client subscribed to both would otherwise see
      # every join twice and have to deduplicate something the server already knows about.
      refute_receive {:troupe_event, _t, _i,
                      %Event{type: "presence", data: %{"subject" => @ada, "state" => "typing"}}},
                     500
    end

    test "still never reaches the durable log", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "presence:#{session.id}")

      for state <- ~w(typing idle typing) do
        {:ok, _} =
          Client.call(ada, "presence.set", %{"session_id" => session.id, "state" => state})
      end

      assert_receive {:troupe_event, _t, _i, %Event{type: "presence"}}, 5_000

      # Moving presence to its own topic changed which subscription it comes out on and
      # nothing about where it goes, which is nowhere. This is on the Forbidden list.
      types = session.id |> Log.replay() |> Enum.map(& &1.type)
      refute "presence" in types, "presence reached the durable log, which the spec forbids"
    end

    test "a client that goes away leaves, and the presence topic is told", context do
      %{session: session} = start_session(context, default: {:text, "ok"})

      ada = attach(context, @ada)
      bob = attach(context, @bob)
      {:ok, _} = Client.subscribe(bob, "presence:#{session.id}")
      {:ok, _} = Client.subscribe(ada, "session:#{session.id}", from_seq: 0)

      assert_receive {:troupe_event, _t, _i,
                      %Event{type: "presence", data: %{"state" => "joined"}}},
                     5_000

      Client.close(ada)

      # The case that matters: nobody else can tell a quiet person from a dead one, so
      # the connection says it on the way out whether or not the client meant to go.
      assert_receive {:troupe_event, _t, _i,
                      %Event{type: "presence", data: %{"state" => "left"}} = left},
                     5_000

      assert left.data["subject"] == @ada
    end

    test "an unknown session is refused rather than subscribed to", context do
      _ = start_session(context, default: {:text, "ok"})
      bob = attach(context, @bob)

      assert {:error, error} = Client.subscribe(bob, "presence:" <> Troupe.Session.generate_id())
      assert error.message in ["not_found", "invalid_params"]
    end
  end

  describe "under pressure" do
    # Small enough that a client which is not reading has bytes outstanding for the whole
    # run, which is what saturated means from the connection's side.
    @tag limits: [outbound_bound: 512]
    test "presence stops entirely and the durable order is identical on both clients",
         context do
      %{session: session} =
        start_session(context,
          default: {:text, "ok"},
          config: [auto_approve: true, max_turns: 1_000]
        )

      # One healthy watcher, in a process of its own, because "identical on both clients"
      # is a claim about two independent receivers and not one list read twice.
      healthy = collector(context, @bob, session.id)

      # And one that stops reading: a raw socket nobody calls `recv` on, so the kernel
      # buffers fill and stay full. A simulated stall would be a test of the simulation.
      stalled = stalled_watcher(context, session.id)
      connection = stalled_connection()

      sender = attach(context, @ada)

      # Fill it first. A connection is not saturated the moment somebody stops reading —
      # the kernel takes a few frames — so the measured part of this test starts once the
      # bytes outstanding are over the bound and staying there.
      saturate(sender, session.id, connection)

      # Presence and durable work interleaved, so "presence stopped" is not another way of
      # saying "nothing was happening".
      for n <- 1..12 do
        {:ok, _} =
          Client.call(sender, "presence.set", %{"session_id" => session.id, "state" => "typing"})

        {:ok, _} =
          Client.call(sender, "input.send", %{
            "command_id" => "turn-#{n}",
            "session_id" => session.id,
            "text" => "line #{n}"
          })
      end

      healthy_events = settled(healthy, 12)

      # Now it starts reading, and takes everything that piled up.
      stalled_events = read_all(stalled)

      # From the first event of the measured phase onwards, presence stopped entirely. Not
      # thinned and not coalesced — none of it, because a subscriber who missed some of it
      # has missed nothing and the bytes are better spent on the session.
      from = first_turn(stalled_events)
      assert from, "the stalled client never saw the measured phase at all"

      after_saturation = Enum.drop(stalled_events, from)

      assert Enum.filter(after_saturation, &(&1["type"] == "presence")) == [],
             "presence survived a saturated queue, so it is not droppable"

      # The healthy one saw it, so the absence above is about pressure rather than about
      # presence never having been published.
      assert Enum.any?(healthy_events, &(&1.type == "presence")),
             "no presence at all; the assertion above is proving nothing"

      # And the part that is not droppable is whole, and in one order, on both. This is
      # the claim: shedding presence is a decision about one subscription and costs the
      # session's own stream nothing.
      healthy_durable = durable_order(healthy_events)
      stalled_durable = json_durable_order(stalled_events)

      assert healthy_durable != [], "no durable events at all"
      assert stalled_durable == healthy_durable

      accepted = for {_seq, "input_accepted", data} <- healthy_durable, do: data["command_id"]
      assert Enum.sort(accepted) == Enum.sort(for n <- 1..12, do: "turn-#{n}")
    end
  end

  # A subscriber that never reads. Both topics, so the absence of presence below is a
  # decision the connection made and not a subscription it was never given.
  defp stalled_watcher(context, session_id) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, context.port, [:binary, active: false, packet: :raw])

    send_line(socket, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocol_version" => "1",
        "client_info" => %{"name" => "stalled", "version" => "1"},
        "capabilities" => %{},
        "auth" => %{"token" => @stalled}
      }
    })

    {:ok, _initialized} = :gen_tcp.recv(socket, 0, 5_000)

    send_line(socket, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "subscribe",
      "params" => %{"topic" => "session:#{session_id}", "level" => "detail", "from_seq" => 0}
    })

    send_line(socket, %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "subscribe",
      "params" => %{"topic" => "presence:#{session_id}", "level" => "detail"}
    })

    # From here nothing calls `recv`, so the kernel buffers fill and stay full.
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  # Presence until the connection says it is over the bound and dropping. Presence rather
  # than anything durable, because a durable event queued at a client this far behind is a
  # resync, and the subscription under test has to still be whole at the end.
  defp saturate(sender, session_id, connection) do
    deadline = System.monotonic_time(:millisecond) + 30_000
    do_saturate(sender, session_id, connection, deadline)
  end

  # Not "has dropped one" but "is wedged": enough bytes written at a socket nobody is
  # reading that the kernel buffers are full and stay full, so a flush never brings the
  # connection back under its bound for long enough to let a frame through. A client that
  # had merely fallen behind for a moment would recover between writes, and this test would
  # be measuring the recovery rather than the saturation.
  defp do_saturate(sender, session_id, connection, deadline) do
    info = Connection.info(connection)

    cond do
      info.dropped_ephemerals > 500 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "the stalled client never fell behind (dropped #{info.dropped_ephemerals}, " <>
            "#{info.outstanding} bytes outstanding)"
        )

      true ->
        for _ <- 1..50 do
          Client.call(sender, "presence.set", %{
            "session_id" => session_id,
            "state" => String.duplicate("x", 4096)
          })
        end

        do_saturate(sender, session_id, connection, deadline)
    end
  end

  defp first_turn(events) do
    Enum.find_index(events, fn event ->
      event["type"] == "input_accepted" and get_in(event, ["data", "command_id"]) == "turn-1"
    end)
  end

  # By who it is, not by how many subscriptions it has: the healthy collector takes out the
  # same two, and picking by shape would have measured whichever one came back first.
  defp stalled_connection do
    [connection] =
      Enum.filter(Connections.list(), fn pid ->
        get_in(Connection.info(pid), [:principal, "subject"]) == @stalled
      end)

    connection
  end

  defp send_line(socket, message) do
    :ok = :gen_tcp.send(socket, [Jason.encode!(message), "\n"])
  end

  # Everything the stalled client was sent, in the order it was written.
  defp read_all(socket) do
    socket |> drain_socket("") |> String.split("\n", trim: true) |> Enum.flat_map(&events_in/1)
  end

  defp drain_socket(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} -> drain_socket(socket, acc <> data)
      {:error, :timeout} -> acc
      {:error, _closed} -> acc
    end
  end

  defp events_in(line) do
    case Jason.decode(line) do
      {:ok, %{"method" => "event", "params" => %{"event" => event}}} -> [event]
      _other -> []
    end
  end

  defp json_durable_order(events) do
    for %{"seq" => seq} = event when is_integer(seq) <- events,
        do: {seq, event["type"], event["data"]}
  end

  # A watcher of both topics, in a process of its own, in arrival order — which is the
  # thing under test.
  defp collector(context, subject, session_id) do
    test = self()

    pid =
      spawn_link(fn ->
        send(test, {:ready, self()})
        gather([])
      end)

    receive do
      {:ready, ^pid} -> :ok
    after
      5_000 -> flunk("collector never started")
    end

    client = attach(context, subject, owner: pid)
    {:ok, _} = Client.subscribe(client, "session:#{session_id}", from_seq: 0)
    {:ok, _} = Client.subscribe(client, "presence:#{session_id}")
    pid
  end

  defp gather(acc) do
    receive do
      {:troupe_event, _topic, _id, event} ->
        gather([event | acc])

      {:events, from, reference} ->
        send(from, {:events, reference, Enum.reverse(acc)})
        gather(acc)
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

  # Waits for the run to finish rather than for a fixed time: a comparison of two lists
  # taken at arbitrary moments is a comparison of two prefixes.
  defp settled(collector, turns) do
    deadline = System.monotonic_time(:millisecond) + 60_000
    do_settle(collector, turns, deadline)
  end

  defp do_settle(collector, turns, deadline) do
    events = events_of(collector)
    accepted = Enum.count(events, &(&1.type == "input_accepted"))

    cond do
      accepted >= turns ->
        # A beat for anything still in flight behind the last acceptance.
        Process.sleep(300)
        events_of(collector)

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("only #{accepted} of #{turns} inputs were accepted")

      true ->
        Process.sleep(50)
        do_settle(collector, turns, deadline)
    end
  end

  defp durable_order(events) do
    for %{seq: seq} = event when is_integer(seq) <- events,
        do: {seq, event.type, event.data}
  end
end
