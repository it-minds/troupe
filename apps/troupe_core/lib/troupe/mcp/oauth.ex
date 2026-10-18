defmodule Troupe.MCP.OAuth do
  @moduledoc """
  A person's own MCP server that wants *them*, signed in, rather than a machine
  (Decision 741).

  Such a server is an OAuth resource server as the MCP authorization specification
  describes it: it publishes protected-resource metadata (RFC 9728), answers a call
  without a token with `401` and `WWW-Authenticate: Bearer resource_metadata="…"`, and
  names an authorization server whose metadata (RFC 8414, or OpenID Connect discovery)
  says where to sign in. The person's entry in `mcp.json` says it wants a sign-in, with
  an `oauth`, and may override the scopes, the loopback redirect, the resource indicator
  and the issuer:

      "wiki": {
        "url": "https://mcp.example.com/mcp",
        "oauth": {"client_id": "0d5c…", "scopes": ["api://mcp.example.com/read"]}
      }

  The client id is what the authorization server knows Troupe by. One the entry gives,
  registered there in advance, is used. With none, Troupe presents its client ID metadata
  document where the authorization server takes one, or registers itself (RFC 7591)
  where it names a registration endpoint (`client/3`); one that does
  neither is answered with the sentence asking for a client id.

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

  A call that comes back `403 insufficient_scope` wants more than the sign-in granted
  (Decision 872): the scope the server named is kept beside the sign-in, the tool
  answers `sign_in_required` with that scope, and the person's next sign-in asks for it
  on top of what was granted, at the authorization server the server's metadata names.
  The tokens held are used until that sign-in lands. Signing out tells the provider too,
  at its `revocation_endpoint` (RFC 7009), when it names one.

  Every URL the daemon calls for it — the server, the protected-resource and
  authorization-server metadata, the token and revocation endpoints — is held to one rule
  (Decision 875, `Troupe.MCP.Address`): its name is resolved, every address it answers is
  checked, none may be link-local, a cloud's metadata service or the unspecified address,
  and the request goes to the address that was checked. The authorization endpoint, which
  the person's browser opens, is checked the same way at discovery.

  This module is the part with no process: reading the configuration, discovery, the
  URLs, the token and revocation endpoints, and `authorized/2`, which wraps a call.
  """

  alias Troupe.MCP.{Address, Client, Server}
  alias Troupe.MCP.OAuth.{SignIn, Store, Tokens}

  @typedoc "What an entry's `oauth` says, read: the client id and the overrides."
  @type config :: %{
          client_id: String.t() | nil,
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
          revocation_endpoint: String.t() | nil,
          resource: String.t() | nil,
          scopes: [String.t()],
          registration_endpoint: String.t() | nil,
          client_id_metadata_document: boolean()
        }

  @typedoc """
  What signing out told the provider: `revoked`; `failed`, with why it was not told;
  `unsupported`, a provider that names no revocation endpoint; or `none`, nothing held.
  """
  @type revocation :: %{
          state: :revoked | :failed | :unsupported | :none,
          reason: String.t() | nil
        }

  @http_timeout 15_000

  # Signing out waits this long for the provider, then forgets the sign-in anyway.
  @revoke_timeout 5_000

  # -- configuration -------------------------------------------------------------------

  @doc """
  An entry's `oauth`, read: `nil` when there is none, or why it cannot be used.

  `client_id` may be left out, for an authorization server Troupe can introduce itself
  to (`client/3`). `scopes` is a list or one space-separated string;
  `redirect_uri` a loopback `http` URL, with or without a port; `resource: false` leaves
  out the resource indicator for an authorization server that refuses it; `issuer`
  names the authorization server when the server publishes no metadata of its own.
  """
  @spec config(term()) :: {:ok, config()} | {:error, String.t()} | nil
  def config(nil), do: nil

  def config(%{} = oauth) do
    oauth = Map.new(oauth, fn {key, value} -> {to_string(key), value} end)
    redirect = present(oauth["redirect_uri"])

    if redirect != nil and loopback_redirect(redirect) == :error do
      {:error,
       "oauth.redirect_uri must be http:// on 127.0.0.1, [::1] or localhost, with or without a port"}
    else
      {:ok,
       %{
         client_id: present(oauth["client_id"]),
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

  @doc """
  The name a sign-in is filed under: the server's canonical URL and the client id the
  entry gives, hashed. An entry that gives none files its sign-in under the URL alone,
  whichever client Troupe was given or presented, so the name holds before that is known.
  """
  @spec key(String.t(), String.t() | nil) :: String.t()
  def key(url, client_id) do
    :sha256
    |> :crypto.hash(resource(url) <> "\n" <> (client_id || ""))
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
  will come back to, when the wait ends, and the scopes it asks for. A second sign-in to
  the same server replaces the first. One after the server wanted more than was granted
  asks for what was granted and what the server named, besides what a first one would.
  """
  @spec sign_in(String.t(), String.t(), config(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def sign_in(name, url, config, opts \\ []) do
    binding = binding(name, url, config, Keyword.get(opts, :state_dir))

    with {:ok, plan} <- discover(url, config, wider(Store.get(binding.state_dir, binding.key))),
         {:ok, client} <- client(binding, plan, opts) do
      case SignIn.start(%{binding | config: client}, plan) do
        {:error, _why} = failed -> again_registered(binding, plan, client, opts, failed)
        started -> started
      end
    end
  end

  # A registration fixed the port the browser comes back to, and something else holds it
  # now: Troupe registers again, on a port that is free.
  defp again_registered(binding, plan, %{registered: key, port_chosen: true}, opts, _failed) do
    :ok = Tokens.forget_client(binding.state_dir, key)

    with {:ok, client} <- client(binding, plan, opts),
         do: SignIn.start(%{binding | config: client}, plan)
  end

  defp again_registered(_binding, _plan, _client, _opts, failed), do: failed

  # What a step-up adds to a sign-in: what was granted — the token endpoint's `scope`,
  # or what was asked for when it said none — and what the server named since.
  defp wider(%{"step_up" => [_ | _] = named} = entry),
    do: (split(entry["scope"]) || List.wrap(entry["scopes"])) ++ named

  defp wider(_entry), do: []

  @doc """
  Sign out of a server on this machine: the sign-in is forgotten, then the provider is
  asked to revoke its refresh token (RFC 7009) when its metadata names a revocation
  endpoint, within `timeout_ms` (five seconds). What the provider was told comes back;
  the sign-in is forgotten whatever it was. The provider's own session in the browser is
  the provider's.

  Forgotten first, so no refresh can spend the token and keep a new one while the
  provider is asked.
  """
  @spec sign_out(binding() | %{key: String.t(), state_dir: Path.t() | nil}, keyword()) ::
          {:ok, revocation()} | {:error, String.t()}
  def sign_out(binding, opts \\ []) do
    with {:ok, entry} <- Tokens.take(binding) do
      {:ok, revoke(entry, opts)}
    end
  end

  @doc """
  Sign out of every server signed in to on this machine, as `sign_out/2` does each, for
  `troupe logout`: each one's revocation, with the server's name.
  """
  @spec sign_out_all(Path.t() | nil, keyword()) ::
          {:ok, [%{server: String.t() | nil, state: atom(), reason: String.t() | nil}]}
          | {:error, String.t()}
  def sign_out_all(state_dir, opts \\ []) do
    state_dir
    |> Store.all()
    |> Enum.reduce_while({:ok, []}, fn {key, entry}, {:ok, done} ->
      case sign_out(%{key: key, state_dir: state_dir}, opts) do
        {:ok, told} -> {:cont, {:ok, [Map.put(told, :server, entry["server"]) | done]}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  How a server's sign-in stands, for a client: `signed_out`, `signing_in` (a browser is
  out), `signed_in` (with the account, when the provider said whose it is) or `expired`
  (it ran out or was refused, and the person signs in again). `step_up` is the scope the
  server wanted on top of what was granted, which the next sign-in asks for, or `nil`.
  Read from the store, so it never waits behind a refresh.
  """
  @spec status(binding()) :: %{
          state: atom(),
          account: String.t() | nil,
          error: String.t() | nil,
          step_up: String.t() | nil
        }
  def status(binding) do
    entry = Store.get(binding.state_dir, binding.key) || %{}

    state =
      cond do
        SignIn.pending?(binding) -> :signing_in
        is_binary(entry["access_token"]) and Tokens.usable?(entry) -> :signed_in
        is_binary(entry["access_token"]) or entry["rejected"] == true -> :expired
        true -> :signed_out
      end

    %{state: state, account: entry["account"], error: entry["error"], step_up: step_up_of(entry)}
  end

  defp step_up_of(%{"step_up" => [_ | _] = named}), do: Enum.join(named, " ")
  defp step_up_of(_entry), do: nil

  @doc """
  Run `call` with the server's token, once more after a refresh when the server answers
  `401`, and `{:error, :sign_in_required}` when there is no sign-in to use or it has run
  out. A `403 insufficient_scope` naming a scope is `{:error, {:sign_in_required,
  scope}}`, the scope kept for the next sign-in and the tokens kept as they are. What
  `call` answers otherwise comes back as it is.
  """
  @spec authorized(Server.t(), (Server.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def authorized(%Server{oauth: binding} = server, call) when is_map(binding) do
    with {:ok, token} <- Tokens.token(binding) do
      case call.(%{server | credential: token}) do
        {:error, {:unauthorized, _challenge}} -> again(server, binding, token, call)
        other -> step_up(binding, other)
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
          step_up(binding, other)
      end
    end
  end

  # The token is good and the call wants a scope it was not granted. Only the scope is
  # read from the challenge: a `resource_metadata` there is not followed, so the next
  # sign-in goes where the server's own metadata says, not where a `403` points. Nothing
  # signs in from here; the person decides. A challenge that names no scope leaves a
  # sign-in nothing to ask for, and is the refusal it was.
  defp step_up(binding, {:error, {:insufficient_scope, header}} = refused) do
    case split(challenge(header)["scope"]) do
      nil ->
        refused

      named ->
        _ = Tokens.step_up(binding, named)
        {:error, {:sign_in_required, Enum.join(named, " ")}}
    end
  end

  defp step_up(_binding, other), do: other

  # -- the client a sign-in is made as ----------------------------------------------------

  # Where Troupe's client ID metadata document is published, which is the client id it
  # presents to an authorization server that takes one. An authorization server knows
  # Troupe by this address, so the document stays at it.
  @client_metadata_url "https://it-minds.github.io/troupe/oauth/client.json"

  @doc """
  The client a sign-in is made as: the entry's `config` with the client id in it.

  The entry's `client_id` when it gives one. Else, where the authorization server takes a
  client ID metadata document and the entry fixes no redirect, the document's URL
  (`client_metadata_url/1`). Else, where it names a `registration_endpoint`, a client it
  registered for Troupe (RFC 7591): the one kept from before for that authorization
  server and redirect, or one registered now, with the redirect it was registered with
  and the name it is kept under (`registered`). Else the sentence asking for a client id.

  `opts`: `client_metadata_url`, the document's URL, for a test.
  """
  @spec client(binding(), plan(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def client(%{config: %{client_id: id} = config}, _plan, _opts) when is_binary(id),
    do: {:ok, config}

  def client(%{config: config} = binding, plan, opts) do
    cond do
      Map.get(plan, :client_id_metadata_document) == true and config.redirect_uri == nil ->
        {:ok, %{config | client_id: client_metadata_url(opts)}}

      is_binary(Map.get(plan, :registration_endpoint)) ->
        registered(binding, plan)

      true ->
        {:error,
         "oauth has no client_id, and #{plan.issuer} neither registers clients nor takes a " <>
           "client ID metadata document: give the id of a client registered with the " <>
           "server's authorization server"}
    end
  end

  @doc """
  Where Troupe's client ID metadata document is: `opts`' `client_metadata_url`, else
  `:troupe_core, :mcp_client_metadata_url`, else the one Troupe publishes.
  """
  @spec client_metadata_url(keyword()) :: String.t()
  def client_metadata_url(opts \\ []) do
    Keyword.get(opts, :client_metadata_url) ||
      Application.get_env(:troupe_core, :mcp_client_metadata_url, @client_metadata_url)
  end

  @doc """
  What Troupe registers itself as, for one redirect: its name and home, the loopback
  redirect, the code and refresh grants, and no secret, since a program on a person's
  machine has nowhere to keep one that the person's other programs cannot read. The
  published metadata document says the same, for the loopback redirects.
  """
  @spec client_metadata(String.t()) :: map()
  def client_metadata(redirect_uri) do
    %{
      "client_name" => "Troupe",
      "client_uri" => "https://github.com/it-minds/troupe",
      "redirect_uris" => [redirect_uri],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
  end

  @doc """
  The name a registered client is kept under: the authorization server and the redirect
  the entry fixes, or none, hashed. One client serves every server that signs in at the
  same authorization server.
  """
  @spec client_key(String.t(), String.t() | nil) :: String.t()
  def client_key(issuer, redirect_uri) do
    :sha256
    |> :crypto.hash(issuer <> "\n" <> (redirect_uri || ""))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp registered(binding, plan) do
    key = client_key(plan.issuer, binding.config.redirect_uri)

    case Store.client(binding.state_dir, key) do
      %{"client_id" => id, "redirect_uri" => redirect} when is_binary(id) and is_binary(redirect) ->
        {:ok, as_registered(binding.config, id, redirect, key)}

      _none ->
        register(binding, plan, key)
    end
  end

  # The redirect is the one the entry fixes, or one on a free loopback port chosen now and
  # kept with the client: a provider that matches a redirect with its port takes it, and
  # one that matches loopback without the port (RFC 8252 section 7.3) does too.
  defp register(binding, plan, key) do
    endpoint = plan.registration_endpoint
    redirect = binding.config.redirect_uri || free_redirect()

    with :ok <- outbound(endpoint, "the registration endpoint"),
         {:ok, answer} <- registration_request(endpoint, client_metadata(redirect)),
         {:ok, id} <- registered_id(answer),
         :ok <-
           Tokens.keep_client(binding.state_dir, key, %{
             "issuer" => plan.issuer,
             "client_id" => id,
             "redirect_uri" => redirect,
             "registration_endpoint" => endpoint,
             "registered_at" =>
               DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }) do
      {:ok, as_registered(binding.config, id, redirect, key)}
    end
  end

  defp as_registered(config, id, redirect, key) do
    Map.merge(config, %{
      client_id: id,
      redirect_uri: redirect,
      registered: key,
      port_chosen: config.redirect_uri == nil
    })
  end

  defp free_redirect do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    "http://127.0.0.1:#{port}/callback"
  end

  # A public client is asked for, and one that must authenticate at the token endpoint is
  # refused rather than used: the secret it came with would sit beside the tokens, readable
  # by anything the person runs, which is no client authentication at all.
  defp registered_id(%{"client_id" => id} = answer) when is_binary(id) and id != "" do
    case answer["token_endpoint_auth_method"] do
      method when method in [nil, "none"] ->
        {:ok, id}

      method ->
        {:error,
         "the authorization server registered Troupe as a client that authenticates with " <>
           "#{method}, and a program on a person's machine has no secret to keep: give the " <>
           "entry an oauth.client_id, a public client registered with it"}
    end
  end

  defp registered_id(_answer), do: {:error, "the registration endpoint answered no client_id"}

  # As a token request is: to the address that was checked, following no redirect.
  defp registration_request(endpoint, metadata) do
    case Req.post(
           endpoint,
           [
             json: metadata,
             headers: [{"accept", "application/json"}],
             receive_timeout: @http_timeout,
             retry: false,
             redirect: false
           ] ++ Address.options()
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, json(body)}

      {:ok, %{status: status, body: body}} ->
        case json(body) do
          %{"error" => error} = answer when is_binary(error) ->
            {:error,
             "the authorization server would not register Troupe: " <>
               refused(error, answer["error_description"])}

          _other ->
            {:error, "the registration endpoint answered #{status}"}
        end

      {:error, %Address.Refused{} = refused} ->
        {:error, refusal("the registration endpoint", endpoint, refused)}

      {:error, reason} ->
        {:error, "the registration endpoint could not be reached: #{reason_text(reason)}"}
    end
  end

  # -- discovery -------------------------------------------------------------------------

  @doc """
  Find where a server's sign-in is done: its protected-resource metadata — from the
  `resource_metadata` its `401` names, or the two well-known places (RFC 9728) — for the
  authorization server, unless `issuer` names it; then that server's metadata, tried at
  the three places the MCP specification lists for an issuer with a path and the two for
  one without. Scopes are the entry's, or the `401`'s, or the metadata's
  `scopes_supported`, with `wider` added (a step-up's, Decision 872) and `offline_access`
  when the authorization server offers it, since without it there is no refresh and the
  person signs in every hour. The revocation endpoint, when the metadata names one, is
  kept for signing out.
  """
  @spec discover(String.t(), config(), [String.t()]) :: {:ok, plan()} | {:error, String.t()}
  def discover(url, config, wider \\ []) do
    with :ok <- outbound(url, "the server's url"),
         {:ok, issuer, hints} <- authorization_server(url, config),
         {:ok, metadata} <- server_metadata(issuer),
         :ok <- opened(metadata["authorization_endpoint"], "the authorization endpoint"),
         :ok <- outbound(metadata["token_endpoint"], "the token endpoint"),
         :ok <- pkce(metadata) do
      scopes = Enum.uniq((config.scopes || hints.scopes || []) ++ wider)

      {:ok,
       %{
         issuer: metadata["issuer"] || issuer,
         authorization_endpoint: metadata["authorization_endpoint"],
         token_endpoint: metadata["token_endpoint"],
         revocation_endpoint: present(metadata["revocation_endpoint"]),
         resource: if(config.resource, do: resource(url)),
         scopes: with_offline(scopes, metadata),
         registration_endpoint: present(metadata["registration_endpoint"]),
         client_id_metadata_document: metadata["client_id_metadata_document_supported"] == true
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

      {:refused, why} ->
        {:error, why}

      _none ->
        {:error,
         "#{url} names no authorization server (no protected-resource metadata); " <>
           "name it with oauth.issuer"}
    end
  end

  # An unauthenticated call, for what the server says it wants: a server that answers it
  # anyway is still asked for its metadata, since it may want a token for its tools.
  defp probe(url) do
    server = %Server{name: "probe", url: url, timeout_ms: @http_timeout, pinned: true}

    case Client.initialize(server) do
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

  # One whose address is refused stops discovery with why, rather than being passed over
  # as a place with nothing there.
  defp resource_metadata(url) do
    with :ok <- secure(url, "the resource metadata"),
         {:ok, %{"authorization_servers" => [_ | _]} = metadata} <-
           get_json(url, "the resource metadata") do
      metadata
    else
      {:refused, why} -> {:refused, why}
      _ -> nil
    end
  end

  defp metadata_scopes(%{"scopes_supported" => [_ | _] = scopes}),
    do: Enum.filter(scopes, &is_binary/1)

  defp metadata_scopes(_metadata), do: nil

  defp server_metadata(issuer, timeout \\ @http_timeout) do
    with :ok <- secure(issuer, "the authorization server") do
      case issuer |> metadata_places() |> Enum.find_value(&metadata_at(&1, timeout)) do
        nil -> {:error, "#{issuer} publishes no authorization server metadata"}
        {:refused, why} -> {:error, why}
        metadata -> {:ok, metadata}
      end
    end
  end

  defp metadata_at(place, timeout) do
    case get_json(place, "the authorization server's metadata", timeout) do
      {:ok, %{"authorization_endpoint" => a, "token_endpoint" => t} = metadata}
      when is_binary(a) and is_binary(t) ->
        metadata

      {:refused, why} ->
        {:refused, why}

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

  @doc """
  Redeem the code the person came back with. `{:error, {:invalid_client, why}}` when the
  authorization server does not know the client, which for one Troupe registered means it
  is gone there.
  """
  @spec exchange(plan(), config(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t() | {:invalid_client, String.t()}}
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
      {:error, {:refused, "invalid_client", why}} -> {:error, {:invalid_client, refused("invalid_client", why)}}
      {:error, {:refused, error, why}} -> {:error, refused(error, why)}
      {:error, why} -> {:error, why}
    end
  end

  @doc """
  Trade a refresh token for new tokens. `{:error, :invalid_grant}` when the
  authorization server will not, which means signing in again, and `{:error,
  :invalid_client}` when it does not know the client any more, which means that too;
  anything else is a failure to ask, and the sign-in is kept.
  """
  @spec refresh(map()) :: {:ok, map()} | {:error, :invalid_grant | :invalid_client | String.t()}
  def refresh(%{"refresh_token" => refresh_token, "token_endpoint" => endpoint} = entry)
      when is_binary(refresh_token) and is_binary(endpoint) do
    form =
      [grant_type: "refresh_token", refresh_token: refresh_token, client_id: entry["client_id"]] ++
        resource_param(entry["resource"])

    case token_request(endpoint, form) do
      {:ok, body} ->
        tokens(body, refresh_token)

      {:error, {:refused, "invalid_grant", _why}} ->
        {:error, :invalid_grant}

      {:error, {:refused, "invalid_client", _why}} ->
        {:error, :invalid_client}

      {:error, {:refused, error, why}} ->
        {:error, refused(error, why)}

      {:error, why} ->
        {:error, why}
    end
  end

  def refresh(_entry), do: {:error, :invalid_grant}

  # -- revocation (RFC 7009) -------------------------------------------------------------

  # The refresh token, since revoking it ends the grant at a provider that ties its
  # access tokens to it; the access token when there is no refresh token.
  defp revoke(entry, opts) do
    case held(entry) do
      nil ->
        told(:none)

      {token, hint} ->
        timeout = Keyword.get(opts, :timeout_ms, @revoke_timeout)

        case revocation_endpoint(entry, timeout) do
          {:ok, nil} -> told(:unsupported)
          {:ok, endpoint} -> revoke_at(endpoint, token, hint, entry["client_id"], timeout)
          {:error, why} -> told(:failed, why)
        end
    end
  end

  defp held(%{"refresh_token" => token}) when is_binary(token), do: {token, "refresh_token"}
  defp held(%{"access_token" => token}) when is_binary(token), do: {token, "access_token"}
  defp held(_entry), do: nil

  # Kept at the sign-in, `nil` when the metadata named none. A sign-in kept before it was
  # looked for has it looked up now, from the authorization server it was made with.
  defp revocation_endpoint(%{"revocation_endpoint" => endpoint}, _timeout)
       when is_binary(endpoint) or is_nil(endpoint),
       do: {:ok, endpoint}

  defp revocation_endpoint(%{"issuer" => issuer}, timeout) when is_binary(issuer) do
    with {:ok, metadata} <- server_metadata(issuer, timeout),
         do: {:ok, present(metadata["revocation_endpoint"])}
  end

  defp revocation_endpoint(_entry, _timeout),
    do: {:error, "the sign-in kept no authorization server to tell"}

  # The token goes where a refresh token may: `outbound/2`, as for the token endpoint, and
  # then to the address that was checked (`Troupe.MCP.Address`). 200 is revoked, and so is
  # any 2xx; anything else, or no answer in time, is the provider not told.
  defp revoke_at(endpoint, token, hint, client_id, timeout) do
    form =
      Enum.reject([token: token, token_type_hint: hint, client_id: client_id], fn {_k, v} ->
        is_nil(v)
      end)

    case outbound(endpoint, "the revocation endpoint") do
      :ok -> endpoint |> revocation_request(form, timeout) |> revocation_answer(endpoint)
      {:error, why} -> told(:failed, why)
    end
  end

  defp revocation_request(endpoint, form, timeout) do
    Req.post(
      endpoint,
      [
        form: form,
        headers: [{"accept", "application/json"}],
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false,
        redirect: false
      ] ++ Address.options()
    )
  end

  defp revocation_answer({:ok, %{status: status}}, _endpoint) when status in 200..299,
    do: told(:revoked)

  defp revocation_answer({:ok, %{status: status, body: body}}, _endpoint) do
    case json(body) do
      %{"error" => error} = answer when is_binary(error) ->
        told(:failed, refused(error, answer["error_description"]))

      _other ->
        told(:failed, "the revocation endpoint answered #{status}")
    end
  end

  defp revocation_answer({:error, %Address.Refused{} = refused}, endpoint),
    do: told(:failed, refusal("the revocation endpoint", endpoint, refused))

  defp revocation_answer({:error, reason}, _endpoint),
    do: told(:failed, "the revocation endpoint could not be reached: #{reason_text(reason)}")

  defp told(state, reason \\ nil), do: %{state: state, reason: reason}

  defp resource_param(nil), do: []
  defp resource_param(resource), do: [resource: resource]

  # A refusal comes back structured, since `refresh/1` decides on its code; the request
  # itself is never in what comes back, as it carries a code or a refresh token. It goes
  # to the address that was checked (`Troupe.MCP.Address`), and follows no redirect: a
  # code or a refresh token goes to the endpoint the metadata named, and nowhere it points.
  defp token_request(endpoint, form) do
    case Req.post(
           endpoint,
           [
             form: form,
             headers: [{"accept", "application/json"}],
             receive_timeout: @http_timeout,
             retry: false,
             redirect: false
           ] ++ Address.options()
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

      {:error, %Address.Refused{} = refused} ->
        {:error, refusal("the token endpoint", endpoint, refused)}

      {:error, reason} ->
        {:error, "the token endpoint could not be reached: #{reason_text(reason)}"}
    end
  end

  defp reason_text(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_text(reason), do: inspect(reason)

  # What a lookup answered instead of an address: `nxdomain`, `timeout`.
  defp lookup_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp lookup_text(reason), do: inspect(reason)

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
  Whether the daemon may send a token to a URL: `secure/2`, and not at an address no
  worker reaches either (Decision 856, `Troupe.WorkerProfile.Reach.refusal/1`) —
  link-local, a cloud's metadata service, the unspecified address — written as one or
  resolved from a name, any of the addresses the name answers (Decision 875,
  `Troupe.MCP.Address`). Loopback stays, as `secure/2` has it, for a server on this
  machine, and so do the private ranges. A name that resolves to nothing is not sent
  anything either. Held to by the server's URL, the token endpoint and the revocation
  endpoint, the three a token goes to; the request itself is checked again, and goes to
  the address that passed.
  """
  @spec outbound(term(), String.t()) :: :ok | {:error, String.t()}
  def outbound(url, what) do
    with :ok <- secure(url, what) do
      case Address.target(URI.parse(url).host) do
        {:ok, _address} -> :ok
        {:error, %Address.Refused{} = refused} -> {:error, refusal(what, url, refused)}
        {:error, reason} -> {:error, "#{what} (#{url}) does not resolve (#{lookup_text(reason)})"}
      end
    end
  end

  # The authorization endpoint is opened by the person's browser, not called by the
  # daemon: a name of it is refused where it resolves to an address no request of the
  # daemon's goes to, but one that does not resolve here is left to the browser, which may
  # reach it through a proxy the daemon does not use.
  defp opened(url, what) do
    with :ok <- secure(url, what) do
      case Address.target(URI.parse(url).host) do
        {:error, %Address.Refused{} = refused} -> {:error, refusal(what, url, refused)}
        _reached_or_unresolved -> :ok
      end
    end
  end

  defp refusal(what, url, refused), do: "#{what} (#{url}) #{Address.Refused.said(refused)}"

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

  # A metadata document, from the address its name was checked at. A refused address is
  # `{:refused, why}`, which ends the search for the document; anything else that is not
  # a JSON object is a place with nothing there.
  defp get_json(url, what, timeout \\ @http_timeout) do
    case Req.get(
           url,
           [
             headers: [{"accept", "application/json"}],
             receive_timeout: timeout,
             retry: false,
             redirect: false
           ] ++ Address.options()
         ) do
      {:ok, %{status: 200, body: body}} ->
        case json(body) do
          %{} = map when map_size(map) > 0 -> {:ok, map}
          _other -> :error
        end

      {:error, %Address.Refused{} = refused} ->
        {:refused, refusal(what, url, refused)}

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
