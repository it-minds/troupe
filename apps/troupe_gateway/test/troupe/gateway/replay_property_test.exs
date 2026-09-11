defmodule Troupe.Gateway.ReplayPropertyTest do
  @moduledoc """
  Whatever a client does to its connection, `from_seq` puts it back exactly where it was.

  A client that reconnects has to be able to say "I processed up to 41" and get 42
  onwards, once each, in order. Get that wrong and the failure is invisible: the
  screen is subtly missing a tool result, or shows one twice, and nobody notices until
  they read the log.

  So the schedule of disconnects is generated rather than chosen. One fixed log, many
  ways of walking it, and the result has to be the log every time.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Troupe.Gateway.Daemon
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint, Event}
  alias Troupe.Protocol.Daemon, as: DaemonClient

  @moduletag timeout: 300_000

  setup_all do
    base = Path.join(System.tmp_dir!(), "troupe-replay-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    {:ok, fake} =
      Fake.start_link(
        steps: Enum.flat_map(1..12, fn n -> [{:tools, [{"todo_read", %{}}]}, {:text, "answer #{n}"}] end),
        default: {:text, "done"}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          auto_approve: true,
          state_dir: state_dir
        ]
      )

    # A log with some shape to it: several turns, tool calls, and enough events that a
    # cut can land anywhere interesting.
    for n <- 1..6 do
      Troupe.send_input(session.id, "turn #{n}")
      await_idle(session.id)
    end

    log = Troupe.events(session.id)
    head = List.last(log).seq

    on_exit(fn ->
      Troupe.stop_session(session.id)

      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{endpoint: endpoint, session_id: session.id, log: log, head: head}
  end

  property "random disconnects and reconnects yield the log exactly", context do
    assert context.head > 10, "the fixture log is too short to cut up"

    check all cuts <- list_of(integer(1..context.head), max_length: 6), max_runs: 25 do
      collected = walk(context, Enum.sort(cuts))

      assert Enum.map(collected, & &1.seq) == Enum.to_list(1..context.head),
             "the reassembled stream was not 1..#{context.head}"

      assert Enum.map(collected, &{&1.seq, &1.type, &1.prev_hash}) ==
               Enum.map(context.log, &{&1.seq, &1.type, &1.prev_hash}),
             "the reassembled stream differs from the log"

      assert Event.verify(collected) == :ok
    end
  end

  property "a from_seq beyond the head replays nothing and still follows live", context do
    check all beyond <- integer(context.head..(context.head + 50)), max_runs: 10 do
      client = connect(context)
      {:ok, %{"head_seq" => head}} = Client.subscribe(client, topic(context), from_seq: beyond)

      assert head == context.head
      assert collect(context, 1, 200) == []

      Client.close(client)
    end
  end

  # -- the walk ---------------------------------------------------------------

  # Read until the next cut, drop the connection, reconnect from the last seq actually
  # processed, and carry on. That last part is the whole point: a client that
  # reconnects from the last seq that *arrived* loses whatever it had not folded yet.
  defp walk(context, cuts) do
    Enum.reduce(cuts ++ [context.head], {[], 0}, fn cut, {acc, processed} ->
      if cut <= processed do
        {acc, processed}
      else
        events = read_from(context, processed, cut - processed)
        {acc ++ events, last_seq(events, processed)}
      end
    end)
    |> then(fn {acc, processed} ->
      acc ++ read_from(context, processed, context.head - processed)
    end)
  end

  defp read_from(_context, _from_seq, count) when count <= 0, do: []

  defp read_from(context, from_seq, count) do
    client = connect(context)
    {:ok, _} = Client.subscribe(client, topic(context), from_seq: from_seq)
    events = collect(context, count, 5_000)
    Client.close(client)
    flush()
    events
  end

  defp connect(context) do
    {:ok, client} = DaemonClient.connect(endpoint: context.endpoint, spawn: false)
    client
  end

  defp topic(context), do: "session:" <> context.session_id

  defp collect(context, count, timeout, acc \\ [])
  defp collect(_context, 0, _timeout, acc), do: Enum.reverse(acc)

  defp collect(context, count, timeout, acc) do
    receive do
      # Ephemerals carry no seq and are not part of what a replay has to reproduce.
      {:troupe_event, _topic, _id, %Event{seq: nil}} ->
        collect(context, count, timeout, acc)

      {:troupe_event, _topic, _id, %Event{} = event} ->
        collect(context, count - 1, timeout, [event | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp last_seq([], fallback), do: fallback
  defp last_seq(events, _fallback), do: List.last(events).seq

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp await_idle(session_id, attempts \\ 800) do
    case Troupe.snapshot(session_id) do
      %{state: state} when state in [:idle, :done] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(5)
        await_idle(session_id, attempts - 1)

      _ ->
        :ok
    end
  end
end
