defmodule Troupe.Gateway.Web do
  @moduledoc """
  The HTTP face of a worker pod: health, and the WebSocket clients attach through.

  A pod is reached through an Ingress rather than over a Unix socket, so its clients
  speak the same JSON-RPC over a WebSocket — one message per text frame, no newline
  framing — and Kubernetes needs two probe paths that answer without a token.

  Everything behind the upgrade is `Gateway.Connection`, unchanged. That is the point of
  `Gateway.Transport`: the handshake, the scopes, the subscriptions and the backpressure
  policy are the protocol and have nothing to do with sockets, and a second copy of them
  for a second transport is how two implementations drift apart.
  """

  use Plug.Router

  alias Troupe.Gateway.Web.Socket

  plug :match
  plug :dispatch

  # Liveness is about this VM, not about what it can reach: a pod that cannot talk to
  # its plane is doing exactly what it is supposed to and must not be restarted for it.
  get "/health/live" do
    send_resp(conn, 200, "ok")
  end

  # Readiness is about taking work. A draining pod answers 503 here so the Service stops
  # sending it new sessions while the ones it has finish.
  get "/health/ready" do
    case ready(conn) do
      :ok -> send_resp(conn, 200, "ready")
      {:error, reason} -> send_resp(conn, 503, to_string(reason))
    end
  end

  get "/v1/socket" do
    conn
    |> WebSockAdapter.upgrade(
      Socket,
      [endpoint: conn.private[:troupe_endpoint], bearer: bearer(conn)],
      timeout: :timer.hours(24)
    )
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp ready(conn) do
    case conn.private[:troupe_ready] do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  # The token may arrive in a header, which is what a browser and a reverse proxy are
  # comfortable with, or in `auth.token` on `initialize`, which is what a client with no
  # control over its headers has. Either reaches the same authenticator.
  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] -> token
      ["bearer " <> token | _rest] -> token
      _other -> nil
    end
  end

  @doc """
  A Bandit child serving this router.

  `:endpoint` is the `Troupe.Protocol.Endpoint` every upgraded connection is created
  with — its authenticator and guard are what decide who may attach. `:ready` is a
  zero-arity function answering `:ok` or `{:error, reason}` for the readiness probe.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)
    endpoint = Keyword.fetch!(opts, :endpoint)
    ready = Keyword.get(opts, :ready)

    plug = {__MODULE__, endpoint: endpoint, ready: ready}

    Supervisor.child_spec(
      {Bandit, plug: plug, scheme: :http, port: port, ip: Keyword.get(opts, :ip, :any)},
      id: Keyword.get(opts, :id, __MODULE__)
    )
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:troupe_endpoint, Keyword.fetch!(opts, :endpoint))
    |> Plug.Conn.put_private(:troupe_ready, Keyword.get(opts, :ready))
    |> super(opts)
  end
end
