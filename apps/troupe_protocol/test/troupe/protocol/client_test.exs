defmodule Troupe.Protocol.ClientTest do
  @moduledoc """
  A call the connection does not outlive is answered (D115). The client stopped `:normal`
  with calls pending, so each caller's `GenServer.call` exited with it, and a caller that
  did not catch the exit went too. Each pending call is now answered `unavailable` before
  the client stops, whatever stops it: the server closing the connection, or `close/1`.

  The server here is a few lines over a loopback socket: it answers `initialize`, then
  reads the next request and does what the test says, so nothing else is in the way.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.{Client, Error}

  # A server that answers `initialize` and hands the connection to the test.
  defp serve do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
        %{"id" => id, "method" => "initialize"} = Jason.decode!(line)
        reply = %{"jsonrpc" => "2.0", "id" => id, "result" => %{"protocol_version" => "1"}}
        :ok = :gen_tcp.send(socket, [Jason.encode!(reply), "\n"])
        :ok = :gen_tcp.controlling_process(socket, test)
        send(test, {:accepted, socket})
      end)

    {:ok, client} = Client.connect(address: {127, 0, 0, 1}, port: port, timeout: 5_000)
    assert_receive {:accepted, socket}, 5_000
    on_exit(fn -> :gen_tcp.close(listen) end)
    %{client: client, socket: socket, server: server}
  end

  # A call from a process of its own, which reports what it got back, or how it exited.
  defp call_in_flight(client, method) do
    test = self()

    spawn(fn ->
      result =
        try do
          Client.call(client, method, %{}, 5_000)
        catch
          :exit, reason -> {:exited, reason}
        end

      send(test, {:answered, method, result})
    end)
  end

  defp await_request(socket, method) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    assert %{"method" => ^method} = Jason.decode!(line)
  end

  test "the server closing the connection with a call in it answers the call unavailable" do
    %{client: client, socket: socket} = serve()
    ref = Process.monitor(client)

    call_in_flight(client, "session.list")
    await_request(socket, "session.list")
    :ok = :gen_tcp.close(socket)

    assert_receive {:answered, "session.list", {:error, %Error{message: "unavailable"} = error}},
                   5_000

    assert Client.closed?(error)
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5_000
    assert_receive {:troupe_disconnected, :closed}
  end

  test "every call in it is answered, not only the first" do
    %{client: client, socket: socket} = serve()

    call_in_flight(client, "one")
    await_request(socket, "one")
    call_in_flight(client, "two")
    await_request(socket, "two")
    :ok = :gen_tcp.close(socket)

    assert_receive {:answered, "one", {:error, %Error{message: "unavailable"}}}, 5_000
    assert_receive {:answered, "two", {:error, %Error{message: "unavailable"}}}, 5_000
  end

  test "closing the client with a call in it answers the call unavailable" do
    %{client: client, socket: socket} = serve()

    call_in_flight(client, "session.list")
    await_request(socket, "session.list")
    :ok = Client.close(client)

    assert_receive {:answered, "session.list", {:error, %Error{message: "unavailable"}}}, 5_000
  end

  test "an error the server sends is the server's, not a closed connection" do
    %{client: client, socket: socket} = serve()

    call_in_flight(client, "session.list")
    await_request(socket, "session.list")

    refusal = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => -32_010, "message" => "unavailable"}
    }

    :ok = :gen_tcp.send(socket, [Jason.encode!(refusal), "\n"])

    assert_receive {:answered, "session.list", {:error, %Error{message: "unavailable"} = error}},
                   5_000

    refute Client.closed?(error)
    assert Process.alive?(client)
    Client.close(client)
  end
end
