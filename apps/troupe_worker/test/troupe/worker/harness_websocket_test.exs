defmodule Troupe.Worker.HarnessWebSocketTest do
  @moduledoc """
  A pod's HTTP face: the probes kubelet calls, and the WebSocket clients attach through.

  A worker pod is reached through an Ingress, so the transport the operator's Ingress
  routes and the transport a client actually speaks have to be the same one. They were
  not: everything above this listened on raw NDJSON, and `PROTOCOL.md` promised
  `wss://<host>/v1/socket`. This is that promise, tested end to end — the same
  `Troupe.Protocol.Client` a laptop uses, over frames instead of lines.

  The probes are here rather than in a unit test because their answers are about the
  pod's state and not about the router: a draining pod must fail readiness, or the
  Service keeps sending it sessions it is in the middle of abandoning.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.Client
  alias Troupe.Worker.{Auth, Drain, Harness}

  @moduletag timeout: 180_000

  @pod "worker-dev-0"

  setup context do
    context = requires_tier(context)

    # No `Gateway.Connections` or `Gateway.Commands` here on purpose: the harness owns
    # them on a pod, and starting a second copy would hide the fact that it must.
    {:ok, jwks} = Tokens.jwks()
    auth = start_supervised!({Auth, name: nil, worker_id: @pod, jwks: jwks})

    http_port = free_port()
    socket_port = free_port()

    start_supervised!(
      {Harness,
       name: :"harness-#{http_port}",
       listener_name: :"harness-listener-#{http_port}",
       web_name: :"harness-web-#{http_port}",
       auth: auth,
       port: socket_port,
       http_port: http_port}
    )

    on_exit(&Drain.reset/0)

    Map.merge(context, %{auth: auth, http_port: http_port, socket_port: socket_port})
  end

  describe "probes" do
    test "liveness answers without a token, because kubelet has none", context do
      assert {200, "ok"} = get(context, "/health/live")
    end

    test "readiness turns 503 while the pod is draining", context do
      assert {200, "ready"} = get(context, "/health/ready")

      # Step one of a drain is to stop taking new work, and this is what makes that
      # true for the Service rather than only inside the pod.
      :persistent_term.put({Drain, :draining?}, true)

      assert {503, "draining"} = get(context, "/health/ready")
    end

    test "an unknown path is a 404 rather than an upgrade", context do
      assert {404, _body} = get(context, "/nowhere")
    end
  end

  describe "attaching over a websocket" do
    test "the same client, the same handshake, one message per frame", context do
      {:ok, client} = connect(context, token(context, role: "owner"))

      info = Client.info(client)
      assert info.server_info["name"] == "troupe-worker"
      assert info.capabilities["remote"] == true
      assert Enum.sort(info.scopes) == [:admin, :control, :observe]
      assert info.principal["subject"] == "owner@example.test"
    end

    test "no token in the header and none in initialize is refused", context do
      assert {:error, error} = connect(context, nil)
      assert error.message == "unauthenticated"
    end

    test "a token for another pod is refused here too", context do
      assert {:error, error} = connect(context, token(context, audience: "worker-ux-0"))
      assert error.message == "unauthenticated"
      assert error.data["reason"] == "wrong_audience"
    end

    test "a whole turn, over frames", context do
      {:ok, _} = activate(context)
      {:ok, client} = connect(context, token(context, role: "owner", session_id: context.session_id))

      {:ok, _} = Client.subscribe(client, "session:#{context.session_id}", from_seq: 0)

      command_id = Client.command_id()

      assert {:ok, %{"accepted" => true}} =
               Client.call(client, "input.send", %{
                 "command_id" => command_id,
                 "session_id" => context.session_id,
                 "text" => "say something"
               })

      assert_receive {:troupe_event, _topic, _id,
                      %{type: "input_accepted", data: %{"command_id" => ^command_id}}},
                     30_000

      assert_receive {:troupe_event, _topic, _id, %{type: "llm_response"}}, 30_000
    end

    test "a closed frame takes the connection with it", context do
      {:ok, client} = connect(context, token(context, role: "owner"))
      before = connection_count()

      Client.close(client)

      assert eventually(fn -> connection_count() < before end)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context, jwt) do
    Client.connect(
      url: "ws://127.0.0.1:#{context.http_port}/v1/socket",
      token: jwt,
      client_info: %{"name" => "test", "version" => "1"}
    )
  end

  defp get(context, path) do
    {:ok, response} = Req.get("http://127.0.0.1:#{context.http_port}#{path}", retry: false)
    {response.status, response.body}
  end

  defp connection_count do
    Troupe.Gateway.Connections
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp token(context, opts) do
    claims =
      %{
        "sub" => Keyword.get(opts, :sub, "owner@example.test"),
        "role" => Keyword.get(opts, :role, "owner"),
        "team" => context.team
      }
      |> then(fn map ->
        case Keyword.get(opts, :session_id) do
          nil -> map
          session_id -> Map.put(map, "session_id", session_id)
        end
      end)

    mint_opts =
      [audience: Keyword.get(opts, :audience, @pod)] ++ Keyword.take(opts, [:lifetime, :now])

    {:ok, jwt, _payload} = Tokens.mint(claims, mint_opts)
    jwt
  end
end
