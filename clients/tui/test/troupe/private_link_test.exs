defmodule Troupe.PrivateLinkTest do
  @moduledoc """
  Issue #365: the daemon registers and seals a private session with a plane token, which it
  cannot get itself, so a TUI signed in to a plane hands it the one it holds when it
  attaches to the daemon (`identity.link` with `plane_token`), again when the token is
  renewed, and again when the daemon has restarted, which leaves it with none.

  Against `FakeRemote` on the live plane's POST transport, whose `/rpc` honours only the
  tokens its `/auth/exchange` minted, so a private session registered there was registered
  with a token the TUI handed over; and the daemon this VM embeds, which is the
  `Troupe.Gateway.Daemon` the `troupe-daemon` binary runs.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote

  test "a signed-in TUI attaching to the daemon links it with its token, and a private session it starts is registered" do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)
    reattach()

    identity = eventually(fn -> linked(url) end)
    assert identity["subject"] == "alice"
    assert identity["display_name"] == "Alice"
    refute inspect(identity) =~ "plane-"
    assert daemon_token() in FakeRemote.plane_tokens(remote)

    ws = tmp_workspace()

    {sid, _, _} =
      start_session!(workspace: ws, params: %{private: true}, script: [{:text, "ok"}])

    assert Map.has_key?(FakeRemote.registered(remote), sid)
  end

  test "a renewed token is handed over before the one the daemon holds runs out" do
    # A plane token good for two seconds past the minute before its end that the TUI
    # renews it in.
    {remote, url} = start_remote!(transport: :http, plane_token_ttl: 62)
    login!(remote, url)
    reattach()

    eventually(fn -> linked(url) end)
    first = daemon_token()
    assert first in FakeRemote.plane_tokens(remote)

    renewed = eventually(fn -> (daemon_token() != first and daemon_token()) || nil end, 15_000)
    assert renewed in FakeRemote.plane_tokens(remote)
  end

  test "a daemon that restarted is linked again, and holds a token again" do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)
    reattach()
    eventually(fn -> linked(url) end)
    assert daemon_token()

    # The daemon goes and comes back: the same `troupe-daemon` with no token in memory.
    %{embedded: daemon} = :sys.get_state(Link)
    :ok = DynamicSupervisor.terminate_child(Troupe.Client.Daemons, daemon)
    eventually(fn -> not Link.up?() end)

    assert {:ok, _identity} = Link.call("identity.get", %{})
    token = eventually(fn -> daemon_token() end)
    assert token in FakeRemote.plane_tokens(remote)
  end

  test "a daemon linked to somebody else is left as it is" do
    {remote, url} = start_remote!(transport: :http)
    {:ok, _} = Link.call("identity.unlink", %{command_id: "unlink-first"})

    {:ok, _} =
      Link.call("identity.link", %{
        command_id: "link-bob",
        subject: "bob",
        display_name: "Bob",
        plane_url: url
      })

    login!(remote, url)
    reattach()
    Process.sleep(500)

    assert {:ok, %{"subject" => "bob"}} = Link.call("identity.get", %{})
    refute daemon_token()
  end

  # The TUI's connection to the daemon drops and is made again at the next call, as one
  # that starts after `troupe login` makes it the first time. Earlier tests in this VM
  # left it connected before anybody signed in.
  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end

  defp linked(url) do
    case Link.call("identity.get", %{}) do
      {:ok, %{"linked" => true, "plane_url" => ^url} = identity} -> identity
      _ -> nil
    end
  end

  # The token the embedded daemon holds. It is in the daemon's memory and in no answer, so
  # this is the one place a test can see it: the state of the process that keeps it.
  defp daemon_token do
    case Process.whereis(Troupe.Gateway.Plane) do
      nil -> nil
      pid -> :sys.get_state(pid).token
    end
  end
end
