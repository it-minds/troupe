defmodule Troupe.Gateway.LoopbackTest do
  @moduledoc """
  The door a browser can actually use.

  Everything here goes over a real WebSocket to a real daemon. The point is the same as
  `DaemonTest`'s: this is the surface a graphical client sees, so a change that would
  break one breaks these first.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Troupe.Gateway.Daemon
  alias Troupe.Identity
  alias Troupe.Protocol.{Client, Endpoint, JSONRPC}
  alias Troupe.Protocol.Client.Transport

  setup context do
    base = Path.join(System.tmp_dir!(), "troupe-loopback-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    run_dir = Path.join(base, "run")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    File.mkdir_p!(run_dir)

    # `daemon.json` lives wherever the platform puts runtime files, which on a
    # developer's machine is their real one. Both names are redirected so a test run
    # cannot tell a running daemon it has moved. The origin list is the test's own, read
    # as the daemon starts: a developer's would decide what these tests see.
    previous =
      for k <- ~w(TROUPE_STATE_HOME XDG_RUNTIME_DIR LOCALAPPDATA TROUPE_ALLOWED_ORIGINS),
          into: %{},
          do: {k, System.get_env(k)}

    System.put_env("TROUPE_STATE_HOME", state_dir)
    System.put_env("XDG_RUNTIME_DIR", run_dir)
    System.put_env("LOCALAPPDATA", run_dir)

    case context[:allowed_origins] do
      nil -> System.delete_env("TROUPE_ALLOWED_ORIGINS")
      origins -> System.put_env("TROUPE_ALLOWED_ORIGINS", origins)
    end

    # A socket's ceiling is read as the listener starts.
    frame_bytes = Application.get_env(:troupe_gateway, :max_frame_bytes)

    if limit = context[:max_frame_bytes],
      do: Application.put_env(:troupe_gateway, :max_frame_bytes, limit)

    on_exit(fn ->
      if frame_bytes,
        do: Application.put_env(:troupe_gateway, :max_frame_bytes, frame_bytes),
        else: Application.delete_env(:troupe_gateway, :max_frame_bytes)
    end)

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

    # D108: `initialize` said 64 MiB, the connection's own limit, and the socket closed at
    # its 16 MiB frame ceiling, so a client that believed it lost the connection and every
    # call waiting on it. Over a WebSocket the largest message is the socket's ceiling.
    @tag max_frame_bytes: 65_536
    test "initialize says what the socket takes, and a message that size is read", context do
      {:ok, client} = connect_ws(context.ws)
      assert Client.info(client).limits["max_message_bytes"] == 65_536

      # Exactly that long, frame header aside: answered (a method nobody serves), and the
      # connection is still there for the next call.
      unpadded = JSONRPC.encode({:request, 1, "nothing.here", %{"pad" => ""}})
      pad = String.duplicate("a", 65_536 - byte_size(unpadded))
      assert {:error, %{code: -32_601}} = Client.call(client, "nothing.here", %{"pad" => pad})
      assert {:ok, %{"linked" => false}} = Client.call(client, "identity.get", %{})
      Client.close(client)

      # The socket transport takes what it always took.
      {address, port} = Endpoint.connect_args(context.endpoint)
      {:ok, native} = Client.connect(address: address, port: port)
      assert Client.info(native).limits["max_message_bytes"] == 64 * 1024 * 1024
      Client.close(native)
    end

    # A frame is one message. Pretty-printed JSON has newlines between its tokens, and the
    # connection, which frames by lines, cut the frame at them and answered nothing.
    test "a frame is one message whatever whitespace it holds, newlines too", context do
      url = "ws://127.0.0.1:#{context.ws.port}/v1/socket"
      {:ok, transport} = Transport.connect([url: url, token: context.ws.token], 5_000)

      initialize = """
      {"jsonrpc": "2.0", "id": 1, "method": "initialize",
       "params": {"protocol_version": "1",
                  "client_info": {"name": "pretty", "version": "1"},
                  "capabilities": {},
                  "auth": {"token": "#{context.ws.token}"}}}
      """

      transport = send_frame(transport, initialize)
      {transport, %{"result" => %{"protocol_version" => "1"}}} = answer(transport, 1)

      get = ~s({"jsonrpc": "2.0", "id": 2, "method": "identity.get", "params": {\r\n}})
      transport = send_frame(transport, get)
      {transport, %{"result" => %{"linked" => false}}} = answer(transport, 2)

      Transport.close(transport)
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

  # Issue #449 (Decision 797): the web app on the plane this daemon is linked to, and a page
  # `troupe-daemon open --url` named, attach with no environment variable.
  describe "the pages troupe-daemon open sends here" do
    test "the plane the daemon is linked to is admitted, by its origin, while it is linked", context do
      assert status(context.ws, "https://plane.example.test") == 403

      {:ok, _} = Identity.link(%{"subject" => "ada@example.test", "plane_url" => "https://plane.example.test/"})
      refute status(context.ws, "https://plane.example.test") == 403

      # The origin, and not the host on another scheme or port.
      assert status(context.ws, "http://plane.example.test") == 403
      assert status(context.ws, "https://plane.example.test:8443") == 403

      Identity.unlink()
      assert status(context.ws, "https://plane.example.test") == 403
    end

    test "an origin published beside the token is admitted, and no other", context do
      assert status(context.ws, "https://gui.example.test") == 403

      assert Endpoint.admit_ws_origin("https://gui.example.test") == :ok
      assert Endpoint.admit_ws_origin("https://gui.example.test") == :ok
      assert Endpoint.ws_origins() == ["https://gui.example.test"]
      refute status(context.ws, "https://gui.example.test") == 403
      assert status(context.ws, "https://other.example.test") == 403

      # Beside the port and token, which a client still reads as before.
      assert {:ok, %{port: port, token: token}} = Endpoint.discover_ws()
      assert {port, token} == {context.ws.port, context.ws.token}
    end

    @tag allowed_origins: "https://only.example.test"
    test "TROUPE_ALLOWED_ORIGINS still replaces the whole list", context do
      {:ok, _} = Identity.link(%{"subject" => "ada@example.test", "plane_url" => "https://plane.example.test"})
      :ok = Endpoint.admit_ws_origin("https://gui.example.test")

      refute status(context.ws, "https://only.example.test") == 403
      assert status(context.ws, "https://plane.example.test") == 403
      assert status(context.ws, "https://gui.example.test") == 403
      assert status(context.ws, "http://localhost:5173") == 403
    end

    # A browser shows a page no 403, so the daemon's log is where the reason is.
    test "a refused upgrade is logged at warning level, with the origin and the fix", context do
      log = capture_log([level: :warning], fn -> assert status(context.ws, "https://refused.example.test") == 403 end)

      assert log =~ "[warning]"
      assert log =~ "https://refused.example.test"
      assert log =~ "troupe-daemon open --url"

      # Once a minute for one origin: a page left open dials again every few seconds.
      assert capture_log(fn -> status(context.ws, "https://refused.example.test") end) == ""
    end
  end

  # One text frame, written as it is: the protocol client would encode it again.
  defp send_frame({:ws, conn, ref, websocket}, text) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ws, conn, ref, websocket}
  end

  # The answer to request `id`, passing over anything else the daemon sends first.
  defp answer(transport, id) do
    receive do
      message ->
        case Transport.handle(transport, message) do
          {:ok, transport, texts} ->
            case texts |> Enum.map(&Jason.decode!/1) |> Enum.find(&(&1["id"] == id)) do
              nil -> answer(transport, id)
              found -> {transport, found}
            end

          :unknown ->
            answer(transport, id)

          {:closed, _transport, reason, _texts} ->
            flunk("the connection closed (#{inspect(reason)}) before request #{id} was answered")
        end
    after
      5_000 -> flunk("no answer to request #{id}")
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
      assert code == -32_602
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

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [provider: "fake", auto_approve: true, model: "fake", state_dir: context.state_dir]
      )

    # Stopped when the test ends. The session index is one process for the whole run, so
    # a session left behind is one another file's "nothing is running yet" would find.
    on_exit(fn -> Troupe.stop_session(session.id) end)
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
