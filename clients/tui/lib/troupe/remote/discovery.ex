defmodule Troupe.Remote.Discovery do
  @moduledoc """
  `GET <plane-url>/.well-known/troupe`, normalised.

  The contract describes `issuer`, `client_id`, `plane_ws` and
  `protocol_versions`. The deployment this client was developed against answers
  with the same identity fields but describes its endpoint as a path under a
  `plane` object (`{"plane": {"rpc": "/rpc", "protocol_version": "1"}}`), and
  that endpoint is JSON-RPC over `POST`, not a WebSocket — its own front page
  says so and `GET /rpc` is a 404 while `POST /rpc` answers a JSON-RPC error.
  It also advertises the OAuth endpoints and scopes inline.

  So a plane names its transport by which field it uses: `plane_ws` is a
  WebSocket, `plane.rpc` is a POST endpoint unless it carries a `ws` scheme.
  Both shapes are read here, and the rest of the client sees one map either way
  (Decisions 69 and 80).
  """

  alias Troupe.Remote.HTTP

  @type transport :: :websocket | :http

  @type t :: %{
          plane_url: String.t(),
          issuer: String.t(),
          client_id: String.t(),
          transport: transport(),
          rpc_url: String.t(),
          ws_url: String.t(),
          protocol_versions: [pos_integer()],
          scopes: [String.t()],
          device_endpoint: String.t() | nil,
          token_endpoint: String.t() | nil,
          name: String.t() | nil
        }

  @default_scopes ~w(openid profile groups offline_access)

  @doc "Fetches and normalises a plane's discovery document."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, term()}
  def fetch(plane_url) do
    url = base(plane_url) <> "/.well-known/troupe"

    case HTTP.get_json(url) do
      {:ok, body} when is_map(body) -> normalise(plane_url, body)
      {:ok, other} -> {:error, {:malformed_discovery, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Normalises an already-fetched document (the same code path the tests drive)."
  @spec normalise(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def normalise(plane_url, body) do
    plane = Map.get(body, "plane", %{})

    with {:ok, issuer} <- fetch_string(body, "issuer"),
         {:ok, client_id} <- fetch_string(body, "client_id"),
         {:ok, transport, url} <- endpoint(plane_url, body, plane) do
      {:ok,
       %{
         plane_url: base(plane_url),
         issuer: String.trim_trailing(issuer, "/"),
         client_id: client_id,
         transport: transport,
         rpc_url: url,
         ws_url: ws_scheme(url),
         protocol_versions: versions(body, plane),
         scopes: scopes(body),
         device_endpoint: Map.get(body, "device_authorization_endpoint"),
         token_endpoint: Map.get(body, "token_endpoint"),
         name: Map.get(plane, "name") || Map.get(body, "name")
       }}
    end
  end

  @doc "The plane URL with any trailing slash and `/.well-known/troupe` suffix removed."
  @spec base(String.t()) :: String.t()
  def base(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/.well-known/troupe", "")
    |> prefix_scheme()
  end

  defp prefix_scheme("http://" <> _ = url), do: url
  defp prefix_scheme("https://" <> _ = url), do: url
  defp prefix_scheme(url), do: "https://" <> url

  defp fetch_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:discovery_missing, key}}
    end
  end

  # `plane_ws` is the contract's spelling and always a socket; `plane.rpc` is the
  # live deployment's, and is a POST endpoint unless it says otherwise.
  defp endpoint(plane_url, body, plane) do
    case {Map.get(body, "plane_ws"), Map.get(plane, "rpc") || Map.get(body, "plane_rpc")} do
      {url, _} when is_binary(url) and url != "" ->
        {:ok, :websocket, url}

      {_, "ws://" <> _ = url} ->
        {:ok, :websocket, url}

      {_, "wss://" <> _ = url} ->
        {:ok, :websocket, url}

      {_, "http" <> _ = url} ->
        {:ok, :http, url}

      {_, path} when is_binary(path) and path != "" ->
        {:ok, :http, base(plane_url) <> path}

      _ ->
        {:error, {:discovery_missing, "plane_ws"}}
    end
  end

  @doc "The same endpoint with a WebSocket scheme, for a plane that turns out to speak one."
  @spec ws_scheme(String.t()) :: String.t()
  def ws_scheme("https://" <> rest), do: "wss://" <> rest
  def ws_scheme("http://" <> rest), do: "ws://" <> rest
  def ws_scheme(other), do: other

  defp versions(body, plane) do
    raw = Map.get(body, "protocol_versions") || Map.get(plane, "protocol_version") || 1

    raw
    |> List.wrap()
    |> Enum.flat_map(fn
      n when is_integer(n) ->
        [n]

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} -> [n]
          :error -> []
        end

      _ ->
        []
    end)
    |> case do
      [] -> [1]
      versions -> versions
    end
  end

  # A plane that lists its scopes knows which ones its issuer will honour;
  # the contract's set is the fallback for one that does not.
  defp scopes(body) do
    case Map.get(body, "scopes") do
      [_ | _] = scopes -> Enum.filter(scopes, &is_binary/1)
      _ -> @default_scopes
    end
  end

  @doc """
  The WebSocket URL for a worker `endpoint` as the plane hands it out: `ws(s)://`
  as it is; `http(s)://` with the scheme swapped and `/v1/socket` where the path
  is empty; a bare host as `wss://<host>/v1/socket`. The same rule the reference
  clients apply (Decision 94).
  """
  @spec worker_url(String.t()) :: String.t()
  def worker_url("ws://" <> _ = url), do: url
  def worker_url("wss://" <> _ = url), do: url

  def worker_url("http" <> _ = url) do
    uri = URI.parse(ws_scheme(url))
    path = if uri.path in [nil, "", "/"], do: "/v1/socket", else: uri.path
    URI.to_string(%{uri | path: path})
  end

  def worker_url(host) when is_binary(host), do: "wss://" <> host <> "/v1/socket"

  @doc "The protocol version this client speaks."
  @spec client_version() :: pos_integer()
  def client_version, do: 1

  @doc """
  The same version as `initialize` carries it. The contract's example writes
  `"protocol_version": "1"`, and the worker compares strings — an integer `1` is
  `unsupported_version` to it (Decision 95).
  """
  @spec wire_version() :: String.t()
  def wire_version, do: Integer.to_string(client_version())

  @doc "Whether a plane's advertised versions include the one this client speaks."
  @spec compatible?(t()) :: boolean()
  def compatible?(%{protocol_versions: versions}), do: client_version() in versions
end
