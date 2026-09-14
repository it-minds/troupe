defmodule Troupe.Gateway.LoopbackTest do
  @moduledoc """
  The door a browser can actually use.

  Everything here goes over a real WebSocket to a real daemon. The point is the same as
  `DaemonTest`'s: this is the surface a graphical client sees, so a change that would
  break one breaks these first.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Identity
  alias Troupe.Protocol.{Client, Endpoint}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-loopback-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    run_dir = Path.join(base, "run")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    File.mkdir_p!(run_dir)

    # `daemon.json` lives wherever the platform puts runtime files, which on a
    # developer's machine is their real one. Both names are redirected so a test run
    # cannot tell a running daemon it has moved.
    previous = for k <- ~w(TROUPE_STATE_HOME XDG_RUNTIME_DIR LOCALAPPDATA), into: %{}, do: {k, System.get_env(k)}
    System.put_env("TROUPE_STATE_HOME", state_dir)
    System.put_env("XDG_RUNTIME_DIR", run_dir)
    System.put_env("LOCALAPPDATA", run_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}

    start_supervised!(
      {Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1), loopback: [enabled: true]}
    )

    on_exit(fn ->
      Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint, ws: read_ws!()}
  end

  defp read_ws! do
    %{"ws" => %{"port" => port, "token" => token}} =
      Endpoint.discovery_path() |> File.read!() |> Jason.decode!()

    %{port: port, token: token}
  end

  defp connect_ws(ws, opts \\ []) do
    Client.connect(
      [
        url: "ws://127.0.0.1:#{ws.port}/v1/socket",
        token: Keyword.get(opts, :token, ws.token),
        client_info: %{"name" => "gui-test", "version" => "1"}
      ] ++ Keyword.drop(opts, [:token])
    )
  end

  describe "stage 2, done item 1: the daemon is reachable from a page" do
    test "writes a ws entry beside the primary transport, and the token admits a client", context do
      published = Endpoint.discovery_path() |> File.read!() |> Jason.decode!()

      # Beside, not instead: a client that can use the Unix socket still should.
      assert published["transport"] == "unix"
      assert published["path"] == context.endpoint.path
      assert is_integer(published["ws"]["port"])
      assert byte_size(published["ws"]["token"]) > 20

      {:ok, client} = connect_ws(context.ws)
      info = Client.info(client)

      assert info.protocol_version
      assert info.scopes == [:observe, :control, :admin]
      Client.close(client)
    end

    test "a client with the wrong token is refused", context do
      assert {:error, _reason} = connect_ws(context.ws, token: "not-the-token")
    end

    test "an upgrade from an unknown origin is refused at the handshake", context do
      assert status(context.ws, "http://evil.example") == 403

      # A development server and a desktop shell are the two origins a graphical client
      # actually has. Neither is refused for its origin — what they get instead is the
      # upgrade failing for want of the WebSocket headers this bare GET does not send.
      refute status(context.ws, "http://localhost:5173") == 403
      refute status(context.ws, "tauri://localhost") == 403

      # The wildcard is on the port and nowhere else.
      assert status(context.ws, "http://localhost.evil.example") == 403
    end
  end

  defp status(ws, origin) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", ws.port, [:binary, active: false, packet: :raw])

    request =
      "GET /v1/socket HTTP/1.1\r\nHost: 127.0.0.1:#{ws.port}\r\nOrigin: #{origin}\r\nConnection: close\r\n\r\n"

    :ok = :gen_tcp.send(conn, request)
    {:ok, response} = :gen_tcp.recv(conn, 0, 5_000)
    :gen_tcp.close(conn)

    [_http, code | _rest] = response |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ")
    String.to_integer(code)
  end

  describe "stage 2, done item 3: who the daemon says its user is" do
    test "an input carries the linked subject as actor, and the local user again once unlinked", context do
      {:ok, client} = connect_ws(context.ws)

      # Before: the operating system's user, which means nothing off this machine.
      assert Client.info(client).principal["subject"] =~ "local:"
      assert {:ok, %{"linked" => false}} = Client.call(client, "identity.get", %{})

      {:ok, linked} =
        Client.call(client, "identity.link", %{
          "command_id" => "c-link",
          "subject" => "ada@example.test",
          "display_name" => "Ada",
          "plane_url" => "https://troupe.example"
        })

      assert linked["linked"] == true
      assert linked["subject"] == "ada@example.test"

      session = start_session(context)
      {:ok, _} = Client.subscribe(client, "session:#{session.id}", from_seq: 0)
      {:ok, _} = Client.call(client, "input.send", %{"command_id" => "c-1", "session_id" => session.id, "text" => "hello"})

      assert actor_of(session.id, "input_queued") == "ada@example.test" or
               actor_of(session.id, "user_input") == "ada@example.test"

      # A second connection, which never saw the link, is the same person.
      {:ok, other} = connect_ws(context.ws)
      assert Client.info(other).principal["subject"] == "ada@example.test"
      Client.close(other)

      {:ok, %{"linked" => false}} = Client.call(client, "identity.unlink", %{"command_id" => "c-unlink"})
      assert Identity.get() == nil

      {:ok, after_unlink} = connect_ws(context.ws)
      assert Client.info(after_unlink).principal["subject"] =~ "local:"
      Client.close(after_unlink)
      Client.close(client)
    end

    test "a session created while linked records its owner", context do
      {:ok, client} = connect_ws(context.ws)
      {:ok, _} = Client.call(client, "identity.link", %{"command_id" => "c-link", "subject" => "ada@example.test"})

      session = start_session(context)

      created = event_of(session.id, "session_created")
      assert created.data["owner"] == "ada@example.test"
      assert created.data["kind"] == "local"

      Client.close(client)
    end

    test "linking with no subject is refused and changes nothing", context do
      {:ok, client} = connect_ws(context.ws)

      assert {:error, %{code: code}} = Client.call(client, "identity.link", %{"command_id" => "c-x", "subject" => ""})
      assert code == -32602
      assert Identity.get() == nil

      Client.close(client)
    end
  end

  defp start_session(context) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, steps: [%{text: "done"}]},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} = Troupe.start_session(workspace: context.workspace, fake: fake)
    session
  end

  defp events(session_id) do
    Troupe.events(session_id)
  rescue
    _ -> []
  end

  defp event_of(session_id, type) do
    wait_for(fn -> Enum.find(events(session_id), &(&1.type == type)) end)
  end

  defp actor_of(session_id, type) do
    case wait_for(fn -> Enum.find(events(session_id), &(&1.type == type)) end) do
      nil -> nil
      event -> event.actor.subject
    end
  end

  defp wait_for(fun, attempts \\ 50) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(20)
        wait_for(fun, attempts - 1)

      answer ->
        answer
    end
  end
end
