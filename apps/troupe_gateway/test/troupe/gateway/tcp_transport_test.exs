defmodule Troupe.Gateway.TcpTransportTest do
  @moduledoc """
  The daemon's door on a platform without Unix sockets: loopback TCP, a random token in
  a user-only `daemon.json`, and the same NDJSON as everywhere else.

  Windows is where this runs for real and nothing in this suite runs there, so the
  transport is exercised here by asking for it explicitly. What matters is the part a
  Unix socket does not have: the token is required, a wrong one is refused before any
  scope is granted, and the discovery file names the port the kernel actually chose
  rather than the `0` the daemon asked for.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Listener}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-tcp-#{System.unique_integer([:positive])}")
    state_dir = Path.join(base, "state")
    run_dir = Path.join(base, "run")
    File.mkdir_p!(state_dir)
    File.mkdir_p!(run_dir)

    previous = for k <- ~w(TROUPE_STATE_HOME XDG_RUNTIME_DIR LOCALAPPDATA), into: %{}, do: {k, System.get_env(k)}
    System.put_env("TROUPE_STATE_HOME", state_dir)
    System.put_env("XDG_RUNTIME_DIR", run_dir)
    System.put_env("LOCALAPPDATA", run_dir)

    # Port 0: the kernel picks, which is what the daemon does on Windows by default.
    endpoint = Endpoint.tcp(0)
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
      File.rm_rf!(base)
    end)

    %{endpoint: endpoint, port: Listener.port()}
  end

  test "daemon.json names the bound port and the token, owner-only", %{endpoint: endpoint, port: port} do
    assert port > 0

    path = Endpoint.discovery_path()
    assert %{"transport" => "tcp", "port" => ^port, "token" => token} = path |> File.read!() |> Jason.decode!()
    assert token == endpoint.token

    unless match?({:win32, _}, :os.type()) do
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o077) == 0
    end

    # And a client that reads the file finds the same door.
    assert {:ok, %Endpoint{kind: :tcp, port: ^port, token: ^token}} = Endpoint.discover()
  end

  test "the token admits a client with every scope", %{endpoint: endpoint, port: port} do
    {:ok, client} = Client.connect(address: {127, 0, 0, 1}, port: port, token: endpoint.token, client_info: %{"name" => "test", "version" => "1"})
    info = Client.info(client)

    assert info.server_info["name"] == "troupe-daemon"
    assert :admin in info.scopes
    assert info.capabilities["remote"] == false
    Client.close(client)
  end

  test "no token, or the wrong one, is refused at initialize", %{port: port} do
    for token <- [nil, "not-the-token"] do
      opts = [address: {127, 0, 0, 1}, port: port, client_info: %{"name" => "test", "version" => "1"}]
      opts = if token, do: [{:token, token} | opts], else: opts

      assert {:error, %Error{code: -32_003}} = Client.connect(opts)
    end
  end
end
