defmodule Troupe.DaemonRelocateTest do
  @moduledoc """
  A window or a headless run on a daemon session follows a daemon that restarted (D46): the
  daemon's loopback takes a new port and a random token at every start, so the pair the
  attach was given names nothing once it has. After a failure the session's connection asks
  where the daemon says it is now, and goes there.

  Played with the suite's embedded daemon: the session's connection is started at a port
  nothing listens on, with a token nobody issued, as a restarted daemon leaves it, and finds
  the daemon where `daemon.json` says it is.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.Worker

  test "a daemon session's connection goes where the daemon is now, after the pair it had fails" do
    {sid, _fake, ws} = start_session!()
    eventually(fn -> Worker.status(sid).up? end)

    # As a restart leaves it: the port the attach was given gone, the token old.
    :ok = DynamicSupervisor.terminate_child(Troupe.Remote.Sessions, Worker.whereis(sid))
    {:ok, here} = Link.websocket()

    relocate = fn ->
      {:ok, %{endpoint: "ws://127.0.0.1:#{here.port}/v1/socket", token: here.token}}
    end

    {:ok, worker} =
      DynamicSupervisor.start_child(
        Troupe.Remote.Sessions,
        {Worker,
         [
           session_id: sid,
           plane_url: nil,
           endpoint: "ws://127.0.0.1:#{dead_port()}/v1/socket",
           token: "a-token-from-before-the-restart",
           relocate: relocate,
           impl: Troupe.Client.Daemon,
           state: :active,
           workspace: ws,
           isolation: :shared
         ]}
      )

    on_exit(fn -> DynamicSupervisor.terminate_child(Troupe.Remote.Sessions, worker) end)

    eventually(fn -> Worker.status(sid).up? end, 15_000)
    assert Worker.status(sid).endpoint == "ws://127.0.0.1:#{here.port}/v1/socket"
  end

  defp dead_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
