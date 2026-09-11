defmodule Troupe.Worker.Harness do
  @moduledoc """
  Where harnesses attach to sessions on this pod.

  The same JSON-RPC the local daemon speaks, over the same gateway code, reached through
  the pod's own Ingress host. Only the authentication differs: locally the socket's
  permissions are the whole story, and here it is a token whose audience is this pod
  alone.

  Reusing the gateway rather than writing a second server is the point. A remote session
  and a local one enforce the same scopes with the same table, stream the same events
  through the same backpressure, and answer the same methods — so there is one protocol
  implementation and not two that drift.

  Two ports, one protocol.

  * **4000, HTTP.** `GET /v1/socket` upgrades to a WebSocket carrying one JSON-RPC
    message per text frame, which is what an Ingress can route and what the operator's
    Ingress and probes already point at. `/health/live` and `/health/ready` answer
    without a token, because kubelet has none.
  * **4100, raw NDJSON.** The same framing the local daemon uses, for anything inside
    the cluster that would rather not carry an HTTP stack — the test suite, and a
    debugging session on a port-forward.

  Both hand their connections to `Gateway.Connection` with the same endpoint, so the
  authenticator, the guard and the scopes are one decision made in one place — and both
  need the gateway's own connection supervisor and command ledger, which on a laptop
  belong to `Gateway.Daemon` and on a pod belong here. A pod never runs the local daemon,
  so there is exactly one owner either way.
  """

  use Supervisor

  alias Troupe.Gateway.{Listener, Web}
  alias Troupe.Protocol.Endpoint
  alias Troupe.Worker.{Auth, Drain}

  @default_http_port 4000
  @default_socket_port 4100

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The HTTP port a pod serves its WebSocket and its probes on."
  @spec http_port(keyword()) :: :inet.port_number()
  def http_port(opts \\ []) do
    Keyword.get_lazy(opts, :http_port, fn ->
      Application.get_env(:troupe_worker, :http_port, @default_http_port)
    end)
  end

  @impl Supervisor
  def init(opts) do
    auth = Keyword.get(opts, :auth, Auth)
    endpoint = Endpoint.remote(socket_port(opts), Auth.authenticator(auth), guard: Auth.guard(auth))

    children = [
      Troupe.Gateway.Commands,
      Troupe.Gateway.Connections,
      {Listener, name: listener_name(opts), endpoint: endpoint},
      Web.child_spec(
        id: web_name(opts),
        port: http_port(opts),
        endpoint: endpoint,
        ready: Keyword.get(opts, :ready, &ready/0)
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Readiness is about taking *new* work. A draining pod keeps serving the sessions it
  # has — that is the whole point of a graceful drain — and must stop being sent more,
  # which is exactly what a failing readiness probe does to a Service's endpoints.
  defp ready do
    if Drain.draining?(), do: {:error, "draining"}, else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp socket_port(opts) do
    Keyword.get_lazy(opts, :port, fn ->
      Application.get_env(:troupe_worker, :harness_port, @default_socket_port)
    end)
  end

  defp listener_name(opts), do: Keyword.get(opts, :listener_name, __MODULE__.Listener)
  defp web_name(opts), do: Keyword.get(opts, :web_name, __MODULE__.Web)
end
