defmodule Troupe.Plane.FakePodTest do
  @moduledoc """
  The suite's fake pod on the control listener, beside a stranger with the same name.

  Every worker suite's link enrols as `troupe-w-dev-0` with `dev-token`, and redials every
  quarter second to two seconds once its plane has gone. Another suite running on the same
  machine, another checkout's, can reach a port the system has since handed this suite's
  listener. Enrolled under the fake pod's name, it was the newer connection, and the plane
  dropped the fake pod's: `EntitlementsTest` failed so once, `FakePod.enrol/4` answered
  `{:error, :closed}`, while another checkout ran the worker tests. The fake pod's token
  carries this VM's mark, and the suite's verifier refuses one without it.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.FakePod

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})
    %{port: Listener.port()}
  end

  test "a stranger enrolling as the same pod is refused, and the suite's pod stays", context do
    pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

    [{ours, _}] =
      Registry.lookup(Connections.registry(), {:pod, "troupe-w-dev", "troupe-w-dev-0"})

    # Another suite's worker link, as `Troupe.Worker.Plane.Link` dials in its tests.
    {:ok, stranger} = :gen_tcp.connect(~c"127.0.0.1", context.port, [:binary, active: false])

    request = %{
      "jsonrpc" => "2.0",
      "id" => 0,
      "method" => "enrol",
      "params" => %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0", "capacity" => 4}
    }

    :ok = :gen_tcp.send(stranger, [Jason.encode!(request), ?\n])
    {:ok, answer} = :gen_tcp.recv(stranger, 0, 5_000)
    :gen_tcp.close(stranger)

    assert %{"error" => %{"message" => "unauthenticated"}} =
             answer |> String.split("\n", trim: true) |> hd() |> Jason.decode!()

    assert [{^ours, _}] =
             Registry.lookup(Connections.registry(), {:pod, "troupe-w-dev", "troupe-w-dev-0"})

    assert Process.alive?(ours)
    assert {:ok, _peer} = :inet.peername(pod.socket)
  end
end
