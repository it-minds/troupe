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
    case origin_allowed?(conn) do
      true ->
        conn
        |> WebSockAdapter.upgrade(
          Socket,
          [endpoint: conn.private[:troupe_endpoint], bearer: bearer(conn)],
          timeout: :timer.hours(24)
        )
        |> halt()

      false ->
        conn |> send_resp(403, "origin not allowed") |> halt()
    end
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

  # A browser names the page that opened the socket in `Origin`; nothing else sends the
  # header at all. The token is what actually admits a connection — a page on another
  # origin cannot read it out of this one — so the check is a second fence, not the
  # first: with no allowlist configured every origin is admitted, and a deployment that
  # knows exactly which origins host its GUI lists them and nothing else gets an upgrade.
  # `*` in the list says the permissive default was chosen on purpose.
  defp origin_allowed?(conn) do
    case {Plug.Conn.get_req_header(conn, "origin"), allowed_origins(conn)} do
      {[], _allowed} -> true
      {_origin, nil} -> true
      {_origin, []} -> true
      {[origin | _], allowed} -> "*" in allowed or Enum.any?(allowed, &origin_matches?(&1, origin))
    end
  end

  # A development server's port is whatever was free, so the daemon's own allowlist has
  # to be able to say "localhost, any port" — and only that. The wildcard is one
  # trailing `*` on the port, never a substring match: `http://localhost.evil.example`
  # must not pass a rule written for `http://localhost:*`.
  defp origin_matches?(pattern, origin) do
    case String.split(pattern, ":*", parts: 2) do
      [^pattern] -> pattern == origin
      [prefix, ""] -> origin == prefix or (String.starts_with?(origin, prefix <> ":") and port_only?(origin, prefix))
      _ -> false
    end
  end

  defp port_only?(origin, prefix) do
    rest = binary_part(origin, byte_size(prefix) + 1, byte_size(origin) - byte_size(prefix) - 1)
    rest != "" and String.match?(rest, ~r/^[0-9]+$/)
  end

  # Configured per listener where there is one — a daemon serves a person's own browser
  # and a pod serves whatever its deployment says — and from the application environment
  # otherwise, which is how a worker has always been told.
  defp allowed_origins(conn) do
    case conn.private[:troupe_allowed_origins] do
      nil -> Application.get_env(:troupe_gateway, :allowed_origins)
      configured -> configured
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

    plug = {__MODULE__, endpoint: endpoint, ready: ready, allowed_origins: Keyword.get(opts, :allowed_origins)}

    # A frame is a whole message, and the connection refuses a message over 64 MiB with
    # `payload_too_large` — but only once it has the whole thing in memory, and before
    # `initialize` nobody has shown a token yet. So the socket itself has a ceiling,
    # well under the connection's, and Bandit closes the frame before it is assembled.
    # Large payloads travel as blobs and `fs.upload` chunks, neither of which needs a
    # frame this size.
    Supervisor.child_spec(
      {Bandit,
       plug: plug,
       scheme: :http,
       port: port,
       ip: Keyword.get(opts, :ip, :any),
       websocket_options: [max_frame_size: Keyword.get(opts, :max_frame_bytes, max_frame_bytes())]},
      id: Keyword.get(opts, :id, __MODULE__)
    )
  end

  @default_max_frame_bytes 16 * 1024 * 1024

  defp max_frame_bytes,
    do: Application.get_env(:troupe_gateway, :max_frame_bytes, @default_max_frame_bytes)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:troupe_endpoint, Keyword.fetch!(opts, :endpoint))
    |> Plug.Conn.put_private(:troupe_ready, Keyword.get(opts, :ready))
    |> Plug.Conn.put_private(:troupe_allowed_origins, Keyword.get(opts, :allowed_origins))
    |> super(opts)
  end
end
