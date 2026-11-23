defmodule Troupe.Session.LogOffsetsTest do
  @moduledoc """
  The session log knows where each event starts. A replay from a cursor decodes only what
  follows it, a restarted `Log` reads only its last line, and the side file the offsets are
  kept in is trusted only while it is the log's: a stale or forged one costs a full read,
  never a wrong answer. Whatever the log holds, a seek replay is the full decode filtered.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Troupe.Paths
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Session.Log.Offsets

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-offsets-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(base) end)

    test_pid = self()
    handler = "log-offsets-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:troupe, :log, :read],
        fn _event, measures, _meta, pid -> send(pid, {:read, self(), measures}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    sid = "s-#{System.unique_integer([:positive])}"
    dir = Paths.session_dir(workspace, sid, state_dir)

    %{
      sid: sid,
      dir: dir,
      log: Path.join(dir, "events.jsonl"),
      workspace: workspace,
      state_dir: state_dir
    }
  end

  test "a replay from a cursor decodes only the events after it", context do
    write_log(context, chain(2_000))
    log = start_log(context)
    drain()

    assert Log.replay_from(context.sid, 1_990) |> Enum.map(& &1.seq) == Enum.to_list(1_991..2_000)
    assert_received {:read, ^log, %{events: 10}}
    refute_received {:read, ^log, _}

    # Appended since: kept from the written line's length, not read back.
    for _ <- 1..3, do: Log.append(context.sid, ["root"], :note, %{"n" => 1})
    drain()

    assert Log.replay_from(context.sid, 2_001) |> Enum.map(& &1.seq) == [2_002, 2_003]
    assert_received {:read, ^log, %{events: 2}}
    assert Log.replay_from(context.sid, 2_003) == []
    assert Log.replay_from(context.sid, 0) == Log.read_file(context.log)
  end

  test "a page between two seqs decodes only the page, running or not", context do
    write_log(context, chain(2_000))
    log = start_log(context)
    drain()

    assert Log.replay_between(context.sid, 949, 1_000) |> Enum.map(& &1.seq) == Enum.to_list(950..999)
    assert_received {:read, ^log, %{events: 50}}
    assert Log.replay_between(context.sid, 1_995, 9_999) |> Enum.map(& &1.seq) == Enum.to_list(1_996..2_000)
    assert Log.replay_between(context.sid, 10, 5) == []

    :ok = stop_supervised(Log)
    drain()
    page = Log.read_session_between(context.sid, context.state_dir, 0, 11)
    assert Enum.map(page, & &1.seq) == Enum.to_list(1..10)
    assert_received {:read, _reader, %{events: 10}}
  end

  test "a restarted Log on a 10k-event log reads one line", context do
    write_log(context, chain(10_000))
    first = start_log(context)
    assert_received {:read, ^first, %{events: 10_000}}
    assert {:ok, _} = Offsets.load(context.log)
    stop_supervised!(Log)

    second = start_log(context)
    assert_received {:read, ^second, %{events: 1}}
    refute_received {:read, ^second, _}
    assert Log.head_seq(context.sid) == 10_000

    {:ok, seq} = Log.append(context.sid, ["root"], :note, %{})
    assert seq == 10_001
    assert :ok = Event.verify(Log.read_file(context.log))
  end

  test "a side file the log has moved past is rebuilt, and the replay is right", context do
    events = chain(50)
    write_log(context, events)
    start_log(context)
    stop_supervised!(Log)
    assert {:ok, _} = Offsets.load(context.log)

    # Written again whole, as a pod's restore writes it: the same events, their bytes moved.
    File.write!(context.log, ["\n\n" | Enum.map(events, &[Jason.encode!(Event.to_json(&1)), ?\n])])

    assert Offsets.load(context.log) == :stale

    log = start_log(context)
    assert_received {:read, ^log, %{events: 50}}
    assert {:ok, _} = Offsets.load(context.log)

    for cursor <- 0..51 do
      assert Log.replay_from(context.sid, cursor) == full_after(context.log, cursor)
    end
  end

  test "a side file whose stamp matches but whose offsets are wrong reads the log whole",
       context do
    write_log(context, chain(30))
    contents = File.read!(context.log)
    {offsets, _events} = Offsets.scan(contents)

    shifted =
      :gb_trees.from_orddict(
        for {seq, at} <- :gb_trees.to_list(offsets.entries), do: {seq, at + 3}
      )

    :ok = Offsets.save(context.log, %{offsets | entries: shifted, last: offsets.last + 3})
    assert {:ok, _} = Offsets.load(context.log)

    for cursor <- [0, 1, 17, 29, 30] do
      assert Log.read_session_after(context.sid, context.state_dir, cursor) ==
               full_after(context.log, cursor)
    end

    start_log(context)
    assert Log.head_seq(context.sid) == 30
    assert Log.replay_from(context.sid, 12) == full_after(context.log, 12)
  end

  test "a torn last line is closed, so the next event is read back", context do
    write_log(context, chain(5))
    File.write!(context.log, ~s({"seq":6,"type":"no), [:append])

    start_log(context)
    {:ok, 6} = Log.append(context.sid, ["root"], :note, %{})
    stop_supervised!(Log)

    assert context.log |> Log.read_file() |> Enum.map(& &1.seq) == [1, 2, 3, 4, 5, 6]
    start_log(context)
    assert Log.head_seq(context.sid) == 6
    assert Log.replay_from(context.sid, 5) |> Enum.map(& &1.seq) == [6]
  end

  test "a repaired log replays right from any cursor", context do
    write_log(context, chain(12))
    start_log(context)

    Log.append(context.sid, ["root"], :log_repaired, %{"event" => 7, "at" => 12})
    Log.append(context.sid, ["root"], :note, %{})

    for cursor <- 0..15 do
      assert Log.replay_from(context.sid, cursor) == full_after(context.log, cursor)
    end
  end

  test "the side file lives in the session's directory, which erasure removes", context do
    write_log(context, chain(3))
    start_log(context)
    assert File.regular?(Offsets.side_file(context.log))
    assert Path.dirname(Offsets.side_file(context.log)) == context.dir
  end

  property "a seek replay is the full decode filtered, for any log and any cursor", context do
    check all(
            n <- integer(0..40),
            junk <-
              list_of(member_of(["not json", "[1,2]", "{\"type\":\"x\"}", ""]), max_length: 6),
            places <- list_of(integer(0..40), length: length(junk)),
            torn <- boolean(),
            max_runs: 60
          ) do
      lines =
        n
        |> chain()
        |> Enum.map(&[Jason.encode!(Event.to_json(&1)), ?\n])
        |> insert_junk(Enum.zip(places, junk))

      contents = IO.iodata_to_binary([lines, if(torn, do: ~s({"seq":99,"ty), else: "")])
      File.mkdir_p!(context.dir)
      File.write!(context.log, contents)
      File.rm(Offsets.side_file(context.log))

      {offsets, events} = Offsets.scan(contents)
      assert events == Log.read_file(context.log)
      assert Log.last_on_disk(context.sid, context.state_dir) == List.last(events)

      for cursor <- 0..(n + 1) do
        expected = Enum.filter(events, &(&1.seq && &1.seq > cursor))

        case Offsets.read_after(context.log, offsets, cursor) do
          {:ok, read} -> assert read == expected
          :whole -> refute offsets.rising
        end

        assert Log.read_session_after(context.sid, context.state_dir, cursor) == expected
      end
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp chain(n) do
    {events, _} =
      Enum.map_reduce(1..n//1, nil, fn seq, previous ->
        type =
          Enum.at(
            ["user_message", "tool_call_requested", "log_repaired", "agent_message"],
            rem(seq, 4)
          )

        data =
          if type == "log_repaired",
            do: %{"event" => seq - 1},
            else: %{"text" => String.duplicate("x", rem(seq, 97))}

        event = Event.seal(%Event{type: type, agent: ["root"], data: data}, seq, previous)
        {event, event}
      end)

    events
  end

  defp insert_junk(lines, junk) do
    junk
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(lines, fn {at, line}, lines -> List.insert_at(lines, at, [line, ?\n]) end)
  end

  defp write_log(context, events), do: :ok = Log.write_new(context.dir, events)

  defp start_log(context) do
    start_supervised!(
      {Log,
       session_id: context.sid, workspace_root: context.workspace, state_dir: context.state_dir}
    )
  end

  defp full_after(path, cursor), do: path |> Log.read_file() |> Enum.filter(&(&1.seq > cursor))

  defp drain do
    receive do
      {:read, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end
