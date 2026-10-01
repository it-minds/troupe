defmodule Troupe.MCP.OAuth do
  @moduledoc """
  A person's own MCP server that wants *them*, signed in, rather than a machine
  (Decision 741).

  Such a server is an OAuth resource server as the MCP authorization specification
  describes it: it publishes protected-resource metadata (RFC 9728), answers a call
  without a token with `401` and `WWW-Authenticate: Bearer resource_metadata="…"`, and
  names an authorization server whose metadata (RFC 8414, or OpenID Connect discovery)
  says where to sign in. The person's entry in `mcp.json` gives what cannot be
  discovered — a client id registered with that authorization server in advance, since
  one with no dynamic registration has no other way to know Troupe — and may override
  the scopes, the loopback redirect, the resource indicator and the issuer:

      "wiki": {
        "url": "https://mcp.example.com/mcp",
        "oauth": {"client_id": "0d5c…", "scopes": ["api://mcp.example.com/read"]}
      }

  The daemon runs the sign-in, because it is the process that calls the server: the
  authorization code flow with PKCE (S256), a `state`, the RFC 8707 `resource`
  indicator, and a redirect to a loopback port it listens on for the one answer
  (`Troupe.MCP.OAuth.SignIn`). A client only opens the URL and shows how it stands. The
  tokens are kept in the daemon's state directory (`Troupe.MCP.OAuth.Store`), never in
  `mcp.json`, a log line or an event, and every use goes through one process
  (`Troupe.MCP.OAuth.Tokens`), which refreshes them — once, for everyone — when they
  run out. A call that comes back `401` is refreshed and tried again once; when that
  fails too, the sign-in is marked as run out and the tool answers `sign_in_required`
  for the model to relay, and every client shows "sign in again".

  This module is the part with no process: reading the configuration, discovery, the
  URLs, the token endpoint, and `authorized/2`, which wraps a call.
  """

  alias Troupe.MCP.{Client, Server}
  alias Troupe.MCP.OAuth.{SignIn, Store, Tokens}

  @typedoc "What an entry's `oauth` says, read: the client id and the overrides."
  @type config :: %{
          client_id: String.t(),
          scopes: [String.t()] | nil,
          redirect_uri: String.t() | nil,
          resource: boolean(),
          issuer: String.t() | nil
        }

  @typedoc """
  Where a server's sign-in is kept, as a `Troupe.MCP.Server` carries it: the key it is
  filed under, the state directory, and what a refresh needs.
  """
  @type binding :: %{
          key: String.t(),
          url: String.t(),
          name: String.t(),
          state_dir: Path.t() | nil,
          config: config()
        }

  @typedoc "What discovery found: where to send the person, where to redeem, what to ask for."
  @type plan :: %{
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          resource: String.t() | nil,
          scopes: [String.t()]
        }

  @http_timeout 15_000

  # -- configuration -------------------------------------------------------------------

  @doc """
  An entry's `oauth`, read: `nil` when there is none, or why it cannot be used.

  `client_id` is required. `scopes` is a list or one space-separated string;
  `redirect_uri` a loopback `http` URL, with or without a port; `resource: false` leaves
  out the resource indicator for an authorization server that refuses it; `issuer`
  names the authorization server when the server publishes no metadata of its own.
  """
  @spec config(term()) :: {:ok, config()} | {:error, String.t()} | nil
  def config(nil), do: nil

  def config(%{} = oauth) do
    oauth = Map.new(oauth, fn {key, value} -> {to_string(key), value} end)
    redirect = present(oauth["redirect_uri"])

    cond do
      present(oauth["client_id"]) == nil ->
        {:error,
         "oauth has no client_id: give the id of a client registered with the server's authorization server"}

      redirect != nil and loopback_redirect(redirect) == :error ->
        {:error,
         "oauth.redirect_uri must be http:// on 127.0.0.1, [::1] or localhost, with or without a port"}

      true ->
        {:ok,
         %{
           client_id: oauth["client_id"],
           scopes: scopes(oauth["scopes"]),
           redirect_uri: redirect,
           resource: oauth["resource"] != false,
           issuer: present(oauth["issuer"])
         }}
    end
  end

  def config(_other), do: {:error, "oauth is not an object"}

  defp scopes(list) when is_list(list),
    do: list |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == ""))

  defp scopes(text) when is_binary(text) and text != "", do: String.split(text)
  defp scopes(_none), do: nil

  @doc """
  Where a server's sign-in is kept, for a `Troupe.MCP.Server`'s `oauth`. One sign-in
  serves every entry that names the same server with the same client, under any name and
  in any workspace.
  """
  @spec binding(String.t(), String.t(), config(), Path.t() | nil) :: binding()
  def binding(name, url, config, state_dir) do
    %{key: key(url, config.client_id), url: url, name: name, state_dir: state_dir, config: config}
  end

  @doc "The name a sign-in is filed under: the server's canonical URL and the client id, hashed."
  @spec key(String.t(), String.t()) :: String.t()
  def key(url, client_id) do
    :sha256
    |> :crypto.hash(resource(url) <> "\n" <> client_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  The server's canonical URI, the `resource` indicator (RFC 8707): scheme and host in
  lower case, no query, no fragment, no trailing slash.

      iex> Troupe.MCP.OAuth.resource("HTTPS://MCP.Example.com/mcp/?x=1#top")
      "https://mcp.example.com/mcp"
  """
  @spec resource(String.t()) :: String.t()
  def resource(url) do
    uri = URI.parse(url)

    path =
      case uri.path do
        nil -> nil
        path -> path |> String.trim_trailing("/") |> present()
      end

    URI.to_string(%URI{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host),
        path: path,
        query: nil,
        fragment: nil
    })
  end

  # -- the sign-in, its state, its end ---------------------------------------------------

  @doc """
  Start a person's sign-in to one server: discover where it is done, and listen on a
  loopback port for the answer. Answers the URL for a client to open, the redirect it
  will come back to, and when the wait ends. A second sign-in to the same server
  replaces the first.
  """
  @spec sign_in(String.t(), String.t(), config(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def sign_in(name, url, config, opts \\ []) do
    binding = binding(name, url, config, Keyword.get(opts, :state_dir))

    with {:ok, plan} <- discover(url, config) do
      SignIn.start(binding, plan)
    end
  end

  @doc "Forget a server's sign-in on this machine. The provider's own session is the provider's."
  @spec sign_out(binding()) :: :ok | {:error, String.t()}
  def sign_out(binding), do: Tokens.forget(binding)

  @doc """
  How a server's sign-in stands, for a client: `signed_out`, `signing_in` (a browser is
  out), `signed_in` (with the account, when the provider said whose it is) or `expired`
  (it ran out or was refused, and the person signs in again). Read from the store, so it
  never waits behind a refresh.
  """
  @spec status(binding()) :: %{state: atom(), account: String.t() | nil, error: String.t() | nil}
  def status(binding) do
    entry = Store.get(binding.state_dir, binding.key) || %{}

    state =
      cond do
        SignIn.pending?(binding) -> :signing_in
        is_binary(entry["access_token"]) and Tokens.usable?(entry) -> :signed_in
        is_binary(entry["access_token"]) or entry["rejected"] == true -> :expired
        true -> :signed_out
      end

    %{state: state, account: entry["account"], error: entry["error"]}
  end

  @doc """
  Run `call` with the server's token, once more after a refresh when the server answers
  `401`, and `{:error, :sign_in_required}` when there is no sign-in to use or it has run
  out. What `call` answers otherwise comes back as it is.
  """
  @spec authorized(Server.t(), (Server.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def authorized(%Server{oauth: binding} = server, call) when is_map(binding) do
    with {:ok, token} <- Tokens.token(binding) do
      case call.(%{server | credential: token}) do
        {:error, {:unauthorized, _challenge}} -> again(server, binding, token, call)
        other -> other
      end
    end
  end

  def authorized(%Server{} = server, call), do: call.(server)

  # The server refused a token Troupe thought good: refreshed (or already replaced by
  # somebody else's refresh) it gets one more try; a second refusal means the sign-in
  # itself is no good any more.
  defp again(server, binding, token, call) do
    with {:ok, fresh} <- Tokens.rejected(binding, token) do
      case call.(%{server | credential: fresh}) do
        {:error, {:unauthorized, _challenge}} ->
          Tokens.give_up(binding)
          {:error, :sign_in_required}

        other ->
          other
      end
    end
  end

  # -- discovery -------------------------------------------------------------------------

  @doc """
  Find where a server's sign-in is done: its protected-resource metadata — from the
  `resource_metadata` its `401` names, or the two well-known places (RFC 9728) — for the
  authorization server, unless `issuer` names it; then that server's metadata, tried at
  the three places the MCP specification lists for an issuer with a path and the two for
  one without. Scopes are the entry's, or the `401`'s, or the metadata's
  `scopes_supported`, with `offline_access` added when the authorization server offers
  it, since without it there is no refresh and the person signs in every hour.
  """
  @spec discover(String.t(), config()) :: {:ok, plan()} | {:error, String.t()}
  def discover(url, config) do
    with :ok <- secure(url, "the server's url"),
         {:ok, issuer, hints} <- authorization_server(url, config),
         {:ok, metadata} <- server_metadata(issuer),
         :ok <- secure(metadata["authorization_endpoint"], "the authorization endpoint"),
         :ok <- secure(metadata["token_endpoint"], "the token endpoint"),
         :ok <- pkce(metadata) do
      {:ok,
       %{
         issuer: metadata["issuer"] || issuer,
         authorization_endpoint: metadata["authorization_endpoint"],
         token_endpoint: metadata["token_endpoint"],
         resource: if(config.resource, do: resource(url)),
         scopes: with_offline(config.scopes || hints.scopes || [], metadata)
       }}
    end
  end

  defp authorization_server(_url, %{issuer: issuer}) when is_binary(issuer),
    do: {:ok, issuer, %{scopes: nil}}

  defp authorization_server(url, _config) do
    challenge = probe(url)

    places =
      case challenge["resource_metadata"] do
        nil -> well_known_resource(url)
        named -> [named]
      end

    case Enum.find_value(places, &resource_metadata/1) do
      %{"authorization_servers" => [issuer | _]} = metadata when is_binary(issuer) ->
        {:ok, issuer, %{scopes: split(challenge["scope"]) || metadata_scopes(metadata)}}

      _none ->
        {:error,
         "#{url} names no authorization server (no protected-resource metadata); " <>
           "name it with oauth.issuer"}
    end
  end

  # An unauthenticated call, for what the server says it wants: a server that answers it
  # anyway is still asked for its metadata, since it may want a token for its tools.
  defp probe(url) do
    case Client.initialize(%Server{name: "probe", url: url, timeout_ms: @http_timeout}) do
      {:error, {:unauthorized, header}} -> challenge(header)
      _other -> %{}
    end
  end

  defp well_known_resource(url) do
    uri = URI.parse(url)
    origin = origin(uri)

    case uri.path |> to_string() |> String.trim_trailing("/") do
      "" ->
        [origin <> "/.well-known/oauth-protected-resource"]

      path ->
        [
          origin <> "/.well-known/oauth-protected-resource" <> path,
          origin <> "/.well-known/oauth-protected-resource"
        ]
    end
  end

  defp resource_metadata(url) do
    with :ok <- secure(url, "the resource metadata"),
         {:ok, %{"authorization_servers" => [_ | _]} = metadata} <- get_json(url) do
      metadata
    else
      _ -> nil
    end
  end

  defp metadata_scopes(%{"scopes_supported" => [_ | _] = scopes}),
    do: Enum.filter(scopes, &is_binary/1)

  defp metadata_scopes(_metadata), do: nil

  defp server_metadata(issuer) do
    with :ok <- secure(issuer, "the authorization server") do
      case issuer |> metadata_places() |> Enum.find_value(&metadata_at/1) do
        nil -> {:error, "#{issuer} publishes no authorization server metadata"}
        metadata -> {:ok, metadata}
      end
    end
  end

  defp metadata_at(place) do
    case get_json(place) do
      {:ok, %{"authorization_endpoint" => a, "token_endpoint" => t} = metadata}
      when is_binary(a) and is_binary(t) ->
        metadata

      _ ->
        nil
    end
  end

  @doc """
  Where an issuer's metadata may be, in the order the MCP specification gives: RFC 8414
  and OpenID Connect discovery with the issuer's path inserted, then OpenID Connect's
  path appended.
  """
  @spec metadata_places(String.t()) :: [String.t()]
  def metadata_places(issuer) do
    uri = URI.parse(issuer)
    origin = origin(uri)

    case uri.path |> to_string() |> String.trim_trailing("/") do
      "" ->
        [
          origin <> "/.well-known/oauth-authorization-server",
          origin <> "/.well-known/openid-configuration"
        ]

      path ->
        [
          origin <> "/.well-known/oauth-authorization-server" <> path,
          origin <> "/.well-known/openid-configuration" <> path,
          origin <> path <> "/.well-known/openid-configuration"
        ]
    end
  end

  # S256 always. A server that says which methods it takes must take that one; one that
  # says nothing — OpenID Connect discovery does not define the field, and some providers
  # leave it out — is used anyway, since refusing it would refuse the providers this is
  # for, and an unused challenge costs nothing.
  defp pkce(%{"code_challenge_methods_supported" => methods}) when is_list(methods) do
    if "S256" in methods,
      do: :ok,
      else: {:error, "the authorization server does not take PKCE with S256"}
  end

  defp pkce(_metadata), do: :ok

  defp with_offline(scopes, %{"scopes_supported" => offered}) when is_list(offered) do
    if "offline_access" in offered and "offline_access" not in scopes,
      do: scopes ++ ["offline_access"],
      else: scopes
  end

  defp with_offline(scopes, _metadata), do: scopes

  @doc """
  The parameters of a `WWW-Authenticate: Bearer …` challenge, by lower-case name:
  `resource_metadata`, `scope`, `error`. Empty when there is no Bearer challenge.
  """
  @spec challenge(String.t() | nil) :: %{String.t() => String.t()}
  def challenge(header) when is_binary(header) do
    case Regex.run(~r/bearer\s+(.*)$/is, header) do
      [_all, params] ->
        ~r/([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,"]+))/
        |> Regex.scan(params)
        |> Map.new(fn
          [_all, name, quoted] ->
            {String.downcase(name), String.replace(quoted, ~r/\\(.)/, "\\1")}

          [_all, name, _quoted, bare] ->
            {String.downcase(name), bare}
        end)

      _none ->
        %{}
    end
  end

  def challenge(_none), do: %{}

  # -- the authorization code flow ---------------------------------------------------------

  @doc "A PKCE verifier and its S256 challenge (RFC 7636)."
  @spec pkce_pair() :: {String.t(), String.t()}
  def pkce_pair do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {verifier, :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)}
  end

  @doc "The URL the person is sent to."
  @spec authorize_url(plan(), config(), String.t(), String.t(), String.t()) :: String.t()
  def authorize_url(plan, config, redirect_uri, state, code_challenge) do
    params =
      [
        {"response_type", "code"},
        {"client_id", config.client_id},
        {"redirect_uri", redirect_uri},
        {"state", state},
        {"code_challenge", code_challenge},
        {"code_challenge_method", "S256"}
      ] ++
        if(plan.scopes == [], do: [], else: [{"scope", Enum.join(plan.scopes, " ")}]) ++
        if(plan.resource, do: [{"resource", plan.resource}], else: [])

    separator = if String.contains?(plan.authorization_endpoint, "?"), do: "&", else: "?"
    plan.authorization_endpoint <> separator <> URI.encode_query(params)
  end

  @doc "Redeem the code the person came back with."
  @spec exchange(plan(), config(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def exchange(plan, config, code, verifier, redirect_uri) do
    form =
      [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: config.client_id,
        code_verifier: verifier
      ] ++ resource_param(plan.resource)

    case token_request(plan.token_endpoint, form) do
      {:ok, body} -> tokens(body, nil)
      {:error, {:refused, error, why}} -> {:error, refused(error, why)}
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  Trade a refresh token for new tokens. `{:error, :invalid_grant}` when the
  authorization server will not, which means signing in again; anything else is a
  failure to ask, and the sign-in is kept.
  """
  @spec refresh(map()) :: {:ok, map()} | {:error, :invalid_grant | String.t()}
  def refresh(%{"refresh_token" => refresh_token, "token_endpoint" => endpoint} = entry)
      when is_binary(refresh_token) and is_binary(endpoint) do
    form =
      [grant_type: "refresh_token", refresh_token: refresh_token, client_id: entry["client_id"]] ++
        resource_param(entry["resource"])

    case token_request(endpoint, form) do
      {:ok, body} ->
        tokens(body, refresh_token)

      {:error, {:refused, error, _why}} when error in ["invalid_grant", "invalid_client"] ->
        {:error, :invalid_grant}

      {:error, {:refused, error, why}} ->
        {:error, refused(error, why)}

      {:error, why} ->
        {:error, why}
    end
  end

  def refresh(_entry), do: {:error, :invalid_grant}

  defp resource_param(nil), do: []
  defp resource_param(resource), do: [resource: resource]

  # A refusal comes back structured, since `refresh/1` decides on its code; the request
  # itself is never in what comes back, as it carries a code or a refresh token.
  defp token_request(endpoint, form) do
    case Req.post(endpoint,
           form: form,
           headers: [{"accept", "application/json"}],
           receive_timeout: @http_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, json(body)}

      {:ok, %{status: status, body: body}} ->
        case json(body) do
          %{"error" => error} = answer when is_binary(error) ->
            {:error, {:refused, error, answer["error_description"]}}

          _other ->
            {:error, "the token endpoint answered #{status}"}
        end

      {:error, reason} ->
        {:error, "the token endpoint could not be reached: #{reason_text(reason)}"}
    end
  end

  defp reason_text(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_text(reason), do: inspect(reason)

  defp refused(error, nil), do: "the authorization server refused: #{error}"
  defp refused(error, why), do: "the authorization server refused: #{error} (#{why})"

  defp tokens(%{"access_token" => access} = body, previous_refresh) when is_binary(access) do
    expires_at =
      case body["expires_in"] do
        seconds when is_integer(seconds) -> System.os_time(:second) + seconds
        text when is_binary(text) -> System.os_time(:second) + String.to_integer(text)
        _none -> nil
      end

    {:ok,
     %{
       "access_token" => access,
       # A provider that does not rotate leaves the old one good.
       "refresh_token" => body["refresh_token"] || previous_refresh,
       "expires_at" => expires_at,
       "scope" => body["scope"],
       "account" => account(body["id_token"]) || account(access)
     }}
  rescue
    ArgumentError -> {:error, "the token endpoint answered an expires_in that is not a number"}
  end

  defp tokens(_body, _previous), do: {:error, "the token endpoint answered no access_token"}

  @doc """
  Whose sign-in it is, for showing: a name from the ID token's claims, or from the access
  token's when it is a JWT. Read, never trusted — nothing is decided on it.
  """
  @spec account(String.t() | nil) :: String.t() | nil
  def account(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(decoded) do
      Enum.find_value(~w(preferred_username email upn unique_name name sub), fn claim ->
        present(claims[claim])
      end)
    else
      _ -> nil
    end
  end

  def account(_token), do: nil

  # -- helpers -----------------------------------------------------------------------------

  @doc """
  Whether a URL may carry a sign-in: `https`, or `http` to this machine's loopback, where
  a test or a server on the same machine is.
  """
  @spec secure(term(), String.t()) :: :ok | {:error, String.t()}
  def secure(url, what) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "::1", "localhost"] -> :ok
      _other -> {:error, "#{what} (#{url}) is not https"}
    end
  end

  def secure(_url, what), do: {:error, "#{what} is missing"}

  @doc """
  A redirect URI as the daemon listens for it: `{ip, port, path}`, the port `0` when the
  URI names none, so any free one is taken.
  """
  @spec loopback_redirect(String.t()) ::
          {:ok, {String.t(), non_neg_integer(), String.t()}} | :error
  def loopback_redirect(uri) do
    case Regex.run(~r"^http://(127\.0\.0\.1|localhost|\[::1\])(?::(\d{1,5}))?(/[^?#]*)?$"i, uri) do
      [_all, host] -> {:ok, {String.downcase(host), 0, "/"}}
      [_all, host, port] -> {:ok, {String.downcase(host), port_of(port), "/"}}
      [_all, host, port, path] -> {:ok, {String.downcase(host), port_of(port), path}}
      nil -> :error
    end
  end

  defp port_of(""), do: 0
  defp port_of(port), do: String.to_integer(port)

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    URI.to_string(%URI{scheme: scheme, host: host, port: port})
  end

  defp get_json(url) do
    case Req.get(url,
           headers: [{"accept", "application/json"}],
           receive_timeout: @http_timeout,
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        case json(body) do
          %{} = map when map_size(map) > 0 -> {:ok, map}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp json(body) when is_map(body), do: body

  defp json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp json(_body), do: %{}

  defp split(nil), do: nil
  defp split(text), do: text |> String.split() |> then(&if(&1 == [], do: nil, else: &1))

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
