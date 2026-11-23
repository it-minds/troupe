defmodule Troupe.Gateway.CheckpointReadTest do
  @moduledoc """
  Reading a session from its latest checkpoint, and paging back before it (#1181):
  `subscribe {from: "checkpoint"}` answers the checkpoint and replays from its `through`,
  from 0 where there is none; `session.events` answers the events before a seq, oldest
  first, a page at most 500 long. Over a real socket, against dormant sessions whose logs
  are the recordings in `test/fixtures/checkpoints/`, read without waking them.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Paths
  alias Troupe.Protocol.{Client, Endpoint, Error, Event}

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "checkpoints"]))
  @approvals Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-checkpoint-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{workspace: workspace, state_dir: state_dir, endpoint: endpoint}
  end

  test "the server says it reads from a checkpoint", context do
    assert Client.info(connect(context)).capabilities["checkpoints"] == true
  end

  test "subscribe from the checkpoint answers the latest and replays from its through", context do
    id = dormant(context, @recorded, "manual")
    log = log(@recorded, "manual")
    [_first, latest] = Enum.filter(log, &(&1["type"] == "checkpoint"))
    through = latest["data"]["through"]
    head = List.last(log)["seq"]

    client = connect(context)

    assert {:ok, answer} = Client.subscribe(client, "session:" <> id, from: :checkpoint)
    assert answer["head_seq"] == head
    assert answer["from_seq"] == through
    assert answer["checkpoint"] == latest

    replayed = collect(head - through)
    assert Enum.map(replayed, & &1.seq) == Enum.to_list((through + 1)..head)
    assert Enum.find(replayed, &(&1.type == "checkpoint")).seq == latest["seq"]

    # Read, not woken.
    refute Troupe.Registry.whereis({:session, id})
  end

  test "a session that never compacted has no checkpoint and replays from the start", context do
    id = dormant(context, @approvals, "decided")
    head = List.last(log(@approvals, "decided"))["seq"]
    client = connect(context)

    assert {:ok, %{"checkpoint" => nil, "from_seq" => 0, "head_seq" => ^head}} =
             Client.subscribe(client, "session:" <> id, from: :checkpoint)

    assert Enum.map(collect(head), & &1.seq) == Enum.to_list(1..head)
  end

  test "session.events pages back before a seq, oldest first, a page at a time", context do
    id = dormant(context, @recorded, "manual")
    log = log(@recorded, "manual")
    [first | _] = Enum.filter(log, &(&1["type"] == "checkpoint"))
    through = first["data"]["through"]
    client = connect(context)

    assert {:ok, %{"events" => page, "more" => true}} = Client.session_events(client, id, through, limit: 10)
    assert Enum.map(page, & &1["seq"]) == Enum.to_list((through - 10)..(through - 1))
    assert page == Enum.filter(log, &(&1["seq"] in (through - 10)..(through - 1)))

    {:ok, %{"events" => older, "more" => false}} = Client.session_events(client, id, through - 10)
    assert Enum.map(older, & &1["seq"]) == Enum.to_list(1..(through - 11))
  end

  test "a page past 500, a seq below 1, and from with from_seq are refused", context do
    id = dormant(context, @recorded, "manual")
    client = connect(context)

    assert {:error, %Error{message: "invalid_params", data: %{"field" => "limit"}}} =
             Client.session_events(client, id, 10, limit: 501)

    assert {:error, %Error{message: "invalid_params", data: %{"field" => "before"}}} =
             Client.session_events(client, id, 0)

    assert {:error, %Error{message: "invalid_params", data: %{"field" => "from"}}} =
             Client.subscribe(client, "session:" <> id, from: :checkpoint, from_seq: 0)

    assert {:error, %Error{message: "invalid_params", data: %{"field" => "from"}}} =
             Client.subscribe(client, "session:" <> id, from: :somewhere)
  end

  test "an open from the checkpoint, and a page before it, decode only what they answer", context do
    # 2,000 events, the checkpoint at 1,990 standing for 1,989.
    events =
      Enum.map(1..2_000, fn
        1_990 ->
          %Event{type: "checkpoint", agent: ["root"], data: checkpoint_data(1_989)}

        n ->
          %Event{type: "user_input", agent: ["root"], data: %{"text" => "line #{n}"}}
      end)

    id = dormant_log(context, seal(events))
    client = connect(context)

    # The offsets beside the log, and the session's row, are built by the first look at
    # it, which a listing makes; what is counted is the open after that.
    assert Troupe.head_seq(id) == 2_000
    assert Troupe.get_session(id)

    {result, decoded} = counting(fn -> Client.subscribe(client, "session:" <> id, from: :checkpoint) end)
    assert {:ok, %{"from_seq" => 1_989, "checkpoint" => %{"seq" => 1_990}}} = result
    assert length(collect(11)) == 11
    assert decoded < 200, "decoded #{decoded} events for an open from the checkpoint"

    # Reading it marked it read, and the index folds its row again from the log (the row
    # every read looks a session up by), which is the index's read and not this one.
    assert Troupe.get_session(id)

    {result, decoded} = counting(fn -> Client.session_events(client, id, 1_000, limit: 50) end)
    assert {:ok, %{"events" => page, "more" => true}} = result
    assert Enum.map(page, & &1["seq"]) == Enum.to_list(950..999)
    assert decoded == 50
  end

  defp checkpoint_data(through) do
    %{
      "shape" => "session/1",
      "through" => through,
      "compacted" => through - 1,
      "previous" => nil,
      "summary" => "earlier",
      "facts" => Troupe.Session.Checkpoint.new() |> Troupe.Session.Checkpoint.facts()
    }
  end

  defp seal(events) do
    {sealed, _} =
      Enum.map_reduce(Enum.with_index(events, 1), nil, fn {event, seq}, previous ->
        sealed = Event.seal(event, seq, previous)
        {sealed, sealed}
      end)

    sealed
  end

  # How many events the log's reads decoded while `fun` ran.
  defp counting(fun) do
    handler = "checkpoint-read-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:troupe, :log, :read], &__MODULE__.decoded/4, self())
    result = fun.()
    :telemetry.detach(handler)
    {result, drain_decoded(0)}
  end

  @doc false
  def decoded(_name, %{events: n}, _meta, test), do: send(test, {:decoded, n})

  defp drain_decoded(sum) do
    receive do
      {:decoded, n} -> drain_decoded(sum + n)
    after
      0 -> sum
    end
  end

  defp dormant_log(context, events) do
    id = "20261123T#{System.unique_integer([:positive]) |> rem(1_000_000) |> pad()}-seeked"
    session_dir = Paths.session_dir(context.workspace, id, context.state_dir)
    File.mkdir_p!(session_dir)
    lines = Enum.map(events, &[Jason.encode_to_iodata!(Event.to_json(&1)), ?\n])
    File.write!(Path.join(session_dir, "events.jsonl"), lines)
    id
  end

  # A recorded log as a dormant session of this daemon's: only its log, under a fresh id.
  defp dormant(context, dir, name) do
    id = "20261123T#{System.unique_integer([:positive]) |> rem(1_000_000) |> pad()}-#{String.slice(name <> "______", 0, 6)}"
    session_dir = Paths.session_dir(context.workspace, id, context.state_dir)
    File.mkdir_p!(session_dir)
    File.cp!(Path.join(dir, name <> ".jsonl"), Path.join(session_dir, "events.jsonl"))
    id
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  defp log(dir, name) do
    dir |> Path.join(name <> ".jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp connect(context) do
    {address, port} = Endpoint.connect_args(context.endpoint)

    {:ok, client} =
      Client.connect(address: address, port: port, client_info: %{"name" => "test", "version" => "1"})

    client
  end

  defp collect(count, acc \\ [])
  defp collect(0, acc), do: Enum.reverse(acc)

  defp collect(count, acc) do
    receive do
      {:troupe_event, _topic, _id, %Event{seq: nil}} -> collect(count, acc)
      {:troupe_event, _topic, _id, event} -> collect(count - 1, [event | acc])
    after
      5_000 -> raise "timed out with #{count} events still expected"
    end
  end
end
