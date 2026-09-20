defmodule Troupe.Gateway.BackpressureTest do
  @moduledoc """
  A client that subscribes and then stops reading.

  This is the case that decides whether the daemon is safe to leave running. A
  subscriber that stalls — a laptop that slept, a terminal scrolled with flow control
  on, a client with a bug — must cost the agent nothing and the daemon a bounded
  amount of memory, and must be told plainly that it has fallen out of sync rather
  than silently missing events.

  The client here is a raw socket that is deliberately never read, so the stall is a
  real one in the kernel's buffers rather than a simulation.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Connection, Connections, Daemon}
  alias Troupe.Protocol.Endpoint

  @moduletag timeout: 180_000

  setup context do
    base = Path.join(System.tmp_dir!(), "troupe-bp-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}

    limits = Map.get(context, :limits, [])

    start_supervised!(
      {Daemon, [endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)] ++ limits}
    )

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint}
  end

  test "a detail subscriber that never reads costs the agent nothing", context do
    session = start_session(context, Enum.map(1..60, fn n -> {:text, "answer #{n}"} end))

    baseline = Enum.map(1..5, fn _ -> time_turn(session.id) end) |> median()

    # A client that subscribes at detail and then stops reading entirely.
    socket = stalled_subscriber(context, session.id)
    connection = lone_connection()

    flood = spawn(fn -> flood(session.id) end)

    # Wait until the pressure is real — the byte bound reached and ephemerals going
    # over the side — so what follows measures the stalled case rather than the moment
    # before it.
    await(
      fn -> Connection.info(connection).dropped_ephemerals > 0 end,
      "the client never fell behind, so nothing was under pressure"
    )

    stalled = Enum.map(1..5, fn _ -> time_turn(session.id) end) |> median()

    info = Connection.info(connection)
    {:memory, memory} = Process.info(connection, :memory)
    {:message_queue_len, queued} = Process.info(connection, :message_queue_len)

    Process.exit(flood, :kill)

    # The subscription is still live at the production bounds: a stalled client loses
    # smoothness, not its place.
    assert info.subscriptions == 1
    assert info.outstanding <= 8 * 1024 * 1024, "the outbound queue grew past its bound"

    # Memory: the connection holds a bounded queue and a bounded mailbox. It is the one
    # process whose size a stalled client could otherwise drive.
    assert memory < 16 * 1024 * 1024, "the connection grew to #{memory} bytes"
    assert queued < 5_000, "the connection's mailbox grew to #{queued}"

    # Latency: the agent never waits on a subscriber, so the only thing that could
    # couple them is a mistake in the delivery path — and a mistake like that costs a
    # turn the whole time a stalled socket takes, which is unbounded, not tens of
    # milliseconds. So the bound is generous on purpose: a turn of ten milliseconds on
    # a shared runner that is also running a flood process on a core it does not have
    # has come in at 34, 62, 69 and 72ms, none of them coupling and all of them failures
    # against a 50ms floor. A quarter of a second is still three orders of magnitude
    # under what a stalled socket would cost.
    allowed = max(baseline * 2, baseline + 250)

    assert stalled <= allowed,
           "a turn took #{stalled}ms with a stalled subscriber against #{baseline}ms idle"

    :gen_tcp.close(socket)
  end

  # Small bounds, so the state past them is reachable in a test rather than after a
  # gigabyte. The behaviour is the same; only the threshold moves.
  @tag limits: [outbound_bound: 4 * 1024, durable_bound: 5]
  test "a subscriber far enough behind on durable events is told to resync", context do
    # Big answers, so the socket buffers fill from durable events alone: a backlog of
    # durable events is the thing being tested, and small ones would sit in the
    # kernel's buffer rather than behind it.
    big = String.duplicate("x", 64 * 1024)
    session = start_session(context, Enum.map(1..40, fn n -> {:text, "#{n} #{big}"} end))

    socket = stalled_subscriber(context, session.id)

    # Enough turns to put more durable events behind the client than the bound allows.
    for _ <- 1..10, do: time_turn(session.id)

    # The client only sees this once it starts reading again, which is exactly when it
    # can act on it.
    assert {:ok, notice} = read_until(socket, "resync_required", 15_000)
    assert notice["params"]["topic"] == "session:#{session.id}"
    assert notice["params"]["last_seq"] >= 0
    assert is_binary(notice["params"]["subscription_id"])

    # The subscription is gone, so nothing else is being queued for it.
    assert Connection.info(lone_connection()).subscriptions == 0

    :gen_tcp.close(socket)
  end

  # -- helpers ----------------------------------------------------------------

  defp start_session(context, steps) do
    fake = start_supervised!({Troupe.LLM.Fake, steps: steps, default: {:text, "done"}})

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          auto_approve: true,
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  # A raw socket, initialized and subscribed, and then never read from again.
  defp stalled_subscriber(context, session_id) do
    {address, port} = Endpoint.connect_args(context.endpoint)
    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw])

    send_line(socket, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocol_version" => "1", "client_info" => %{}, "capabilities" => %{}}
    })

    {:ok, _initialized} = :gen_tcp.recv(socket, 0, 5_000)

    send_line(socket, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "subscribe",
      "params" => %{
        "command_id" => "c-stall",
        "topic" => "session:#{session_id}",
        "level" => "detail"
      }
    })

    # Deliberately no further reads: from here the kernel buffers fill and stay full.
    socket
  end

  defp lone_connection do
    [connection] = Connections.list()
    connection
  end

  defp send_line(socket, message) do
    :ok = :gen_tcp.send(socket, [Jason.encode!(message), "\n"])
  end

  # Read whatever has piled up until a message with this method appears.
  defp read_until(socket, method, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_read_until(socket, method, deadline, "")
  end

  defp do_read_until(socket, method, deadline, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [_partial] -> fill(socket, method, deadline, buffer)
      [line, rest] -> match_line(socket, method, deadline, line, rest)
    end
  end

  defp fill(socket, method, deadline, buffer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case :gen_tcp.recv(socket, 0, min(remaining, 1_000)) do
        {:ok, data} -> do_read_until(socket, method, deadline, buffer <> data)
        {:error, :timeout} -> do_read_until(socket, method, deadline, buffer)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp match_line(socket, method, deadline, line, rest) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"method" => ^method} = message} -> {:ok, message}
      _ -> do_read_until(socket, method, deadline, rest)
    end
  end

  defp flood(session_id) do
    Enum.each(1..200_000, fn n ->
      Troupe.Events.publish_ephemeral(session_id, "llm_delta", ["root"], %{
        "kind" => "text",
        "text" => String.duplicate("x", 200) <> to_string(n)
      })
    end)
  end

  defp time_turn(session_id) do
    started = System.monotonic_time(:millisecond)
    Troupe.send_input(session_id, "go")
    await_idle(session_id)
    System.monotonic_time(:millisecond) - started
  end

  defp await(predicate, message, attempts \\ 400) do
    cond do
      predicate.() -> :ok
      attempts > 0 -> Process.sleep(25) && await(predicate, message, attempts - 1)
      true -> flunk(message)
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
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
