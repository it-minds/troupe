defmodule Troupe.Protocol.Client.TransportTest do
  @moduledoc """
  A WebSocket's upgrade reads only its own socket's messages. It took every message in the
  mailbox while it waited for the server's `101`, so a process that dialled from its own
  mailbox, a GenServer with calls and timers queued, lost them.

  The server here is a few lines over a loopback socket that answers the upgrade and
  nothing else.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Client.Transport

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  test "the upgrade leaves the dialling process's own messages in its mailbox" do
    port = upgrade_server()

    send(self(), :queued_before)
    send(self(), {:tcp, :not_this_socket, "nor this"})

    assert {:ok, {:ws, _conn, _ref, _websocket} = transport} =
             Transport.connect([url: "ws://127.0.0.1:#{port}/v1/socket"], 5_000)

    assert_received :queued_before
    assert_received {:tcp, :not_this_socket, "nor this"}
    Transport.close(transport)
  end

  # Answers one upgrade with its `101`, then holds the socket until the test ends.
  defp upgrade_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        {:ok, request} = read_request(socket, "")
        [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)
        accept = Base.encode64(:crypto.hash(:sha, key <> @guid))

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\n",
            "upgrade: websocket\r\nconnection: Upgrade\r\n",
            "sec-websocket-accept: #{accept}\r\n\r\n"
          ])

        receive do
          :stop -> :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      send(server, :stop)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 10_000), do: read_request(socket, acc <> data)
    end
  end
end
