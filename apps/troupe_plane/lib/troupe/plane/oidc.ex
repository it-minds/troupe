defmodule Troupe.Plane.OIDC do
  @moduledoc """
  The plane as a relying party.

  A client runs the device authorization grant against the identity provider directly —
  the plane is never handed the user's provider credentials, only the token that comes
  out — and then exchanges that token here for a plane token. Two separate credentials
  with two separate lifetimes: the provider's refresh token lives in a user-only file on
  the client's machine, and the plane token is minted fresh, short, and audience-bound.

  Verification is against the provider's published keys, fetched from its discovery
  document and cached. Injectable, because a test needs an issuer it controls and the
  thing worth testing is what the plane does with the claims rather than whether a
  well-known JWKS endpoint works.
  """

  alias Troupe.Plane.{Identity, Login, Settings, Tokens}
  alias Troupe.Protocol.Token

  require Logger

  # How often a failed signature may send the plane back to the provider for new keys.
  @refetch_floor_ms 60_000

  @doc """
  Exchange a provider token for a plane token.

  The claims become an identity through the same path SCIM uses, so a plane with SCIM
  disabled and one with it enabled end up with the same teams — which is a done item and
  the reason `Login` exists at all rather than this writing its own rows.
  """
  @spec exchange(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange(id_token, opts \\ []) do
    with {:ok, claims} <- verify(id_token, opts),
         {:ok, user, teams} <- Login.from_claims(claims) do
      mint(user, teams, opts)
    end
  end

  defp mint(user, teams, opts) do
    claims = %{
      "sub" => user.subject,
      "name" => user.display_name,
      "email" => user.email,
      "teams" => Enum.map(teams, & &1.name),
      "role" => "user",
      "scopes" => Enum.map(Token.scopes_for("owner"), &Atom.to_string/1)
    }

    audience = Keyword.get(opts, :audience, audience())

    case Tokens.mint(claims, audience: audience, lifetime: Keyword.get(opts, :lifetime, 900)) do
      {:ok, jwt, payload} ->
        {:ok,
         %{
           "token" => jwt,
           "expires_at" => payload["exp"],
           "subject" => user.subject,
           "display_name" => user.display_name,
           "teams" => Enum.map(teams, & &1.name),
           "profiles" =>
             Identity.profiles_for(user) |> Enum.map(& &1.profile) |> Enum.uniq() |> Enum.sort()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Authenticate a caller presenting the *provider's* token rather than one of ours.

  `/rpc` takes a plane token, because everything that reaches it has been through
  `/auth/exchange` first. An MCP client has not: it does OAuth against the identity
  provider itself, the way the specification says a client should, and arrives holding
  what the provider gave it. So this is the same three steps `exchange/2` takes — verify,
  turn claims into an identity, read the teams — stopping before the mint, because there
  is nothing to mint for: the caller already has a credential and wants to be recognised
  by it.

  The audience is this client id *or* this client's API. An id_token is addressed to the
  client; an access token for a scope the client exposes is addressed to the API. Both are
  the same person and both are signed by the same keys; refusing one of them would mean
  every MCP client had to obtain a token of the other kind, which is not something a client
  chooses.
  """
  @spec authenticate(String.t(), keyword()) :: {:ok, Identity.User.t()} | {:error, term()}
  def authenticate(token, opts \\ []) do
    with {:ok, claims} <- verify(token, Keyword.put_new(opts, :audience, audiences())),
         {:ok, user, _teams} <- Login.from_claims(claims) do
      {:ok, user}
    end
  end

  @doc """
  What this plane accepts a provider token to be addressed to.

  Three names for one registration, and none at all when no client is configured — a plane
  with no identity provider should verify nothing rather than everything.

  The client id is what an id_token carries. `api://<client-id>` and the MCP endpoint's own
  URL are both identifier URIs of the same registration, and which of them appears in an
  access token depends on the provider and on the name the client asked under — none of
  which is the caller's choice, and all of which are the same API. The list is closed and
  every entry names *this* registration; a token for anything else fails on audience.
  """
  @spec audiences() :: [String.t()]
  def audiences do
    case client_id() do
      nil -> []
      id -> [id, "api://" <> id] ++ resource_names()
    end
  end

  defp resource_names do
    case Application.get_env(:troupe_plane, :base_url) do
      nil -> []
      base -> ["#{base}/mcp"]
    end
  end

  @doc """
  Check a provider token and give back its claims.

  `:verifier` replaces the whole check, which is how a test supplies an issuer it
  controls. In a cluster it is the provider's own keys, fetched from discovery.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(id_token, opts \\ []) do
    case Keyword.get(opts, :verifier) || configured_verifier(opts) do
      nil -> {:error, :no_issuer_configured}
      verifier when is_function(verifier, 1) -> verifier.(id_token)
    end
  end

  defp configured_verifier(opts) do
    case Application.get_env(:troupe_plane, :oidc_verifier) do
      nil -> default_verifier(opts)
      verifier -> verifier
    end
  end

  # The provider's discovery document names its JWKS, and that is what a token is checked
  # against. Cached, because a plane that refetched on every login would be a load
  # generator — but not forever: a provider that has rotated its keys publishes new ones,
  # and a cache with no way to notice would refuse every login until the plane restarted.
  # So a signature that does not verify refetches once and tries again, no more often
  # than @refetch_floor_ms, which is what stops the retry becoming the load generator the
  # cache exists to prevent.
  defp default_verifier(opts) do
    case Settings.get("issuer") do
      nil -> nil
      issuer -> &verify_against_provider(&1, issuer, opts)
    end
  end

  defp verify_against_provider(id_token, issuer, opts) do
    case attempt(id_token, issuer, opts) do
      {:error, reason} when reason in [:bad_signature, :no_keys] ->
        if refetch(issuer), do: attempt(id_token, issuer, opts), else: {:error, reason}

      other ->
        other
    end
  end

  defp attempt(id_token, issuer, opts) do
    with {:ok, jwks} <- provider_jwks(issuer) do
      # `max_lifetime: :any` because this is the *provider's* token, not one of ours. The
      # fifteen-minute ceiling is a rule about what Troupe mints for a pod; applying it
      # here would refuse every provider whose id_tokens last an hour, which is most of
      # them. The signature, the issuer, the audience and `exp` are all still checked, and
      # this token is exchanged once, immediately, for a plane token that does have the
      # ceiling.
      Token.verify(id_token, jwks,
        audience: Keyword.get(opts, :audience, client_id()),
        issuer: issuer,
        max_lifetime: :any
      )
    end
  end

  defp provider_jwks(issuer) do
    case :persistent_term.get({__MODULE__, :jwks, issuer}, nil) do
      nil -> fetch_jwks(issuer)
      jwks -> {:ok, jwks}
    end
  end

  # At most one refetch per floor, whatever else is happening: a burst of bad tokens must
  # not become a burst of requests at somebody else's discovery endpoint.
  defp refetch(issuer) do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get({__MODULE__, :refetched, issuer}, 0)

    if now - last < @refetch_floor_ms do
      false
    else
      :persistent_term.put({__MODULE__, :refetched, issuer}, now)
      :persistent_term.erase({__MODULE__, :jwks, issuer})
      match?({:ok, _}, fetch_jwks(issuer))
    end
  end

  defp fetch_jwks(issuer) do
    with {:ok, %{status: 200, body: discovery}} <- get(discovery_url(issuer)),
         uri when is_binary(uri) <- discovery["jwks_uri"],
         {:ok, %{status: 200, body: jwks}} <- get(uri) do
      :persistent_term.put({__MODULE__, :jwks, issuer}, jwks)
      {:ok, jwks}
    else
      other ->
        Logger.warning("troupe plane: could not fetch #{issuer}'s keys: #{inspect(other)}")
        {:error, :no_provider_keys}
    end
  end

  defp get(url), do: Req.request(method: :get, url: url, decode_body: true, retry: false)

  # The issuer without its trailing slash, then the well-known path.
  #
  # An issuer that ends in one is not unusual — it is what Authentik publishes for a
  # per-application provider, `https://auth.example/application/o/<slug>/` — and the
  # naive concatenation asks for `<slug>//.well-known/openid-configuration`. Whether
  # that works is the provider's routing, and on Django it does not: the double slash
  # is a different path and answers 404. What that failure looks like from here is
  # `no_provider_keys` on every sign-in, with a configuration that is character for
  # character what the provider's own page told you to paste.
  #
  # Only this URL is trimmed. The `iss` claim is compared exactly, by `Token.verify/3`
  # and by the discovery check, and a trailing slash there is part of the name the
  # provider calls itself — trimming it would refuse every token from a provider whose
  # issuer genuinely ends in one.
  defp discovery_url(issuer) do
    String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"
  end

  # -- checking the configuration ---------------------------------------------

  @doc """
  What this plane can prove about its identity provider, each check with what it proved.

  The design asks for a test that is a check list with timings rather than a green tick,
  on the grounds that "identity is fine" is not a useful thing to be told at the moment it
  is not fine. These three are here because each is genuinely *provable from here* — a
  check that says "looks right" is worse than no check, because it is believed. The fourth
  thing worth knowing, whether anybody is actually an administrator, is not about the
  provider at all and `Troupe.Plane.Admin` asks it.

  What none of them proves is that a person can sign in: that needs a person. The failure
  they cannot catch is a redirect URI the registration does not have, which is why the
  console prints the URI it would send rather than claiming it is registered.
  """
  @spec check(map()) :: [map()]
  def check(config \\ configured()) do
    issuer = config[:issuer]
    document = timed(fn -> discovery(issuer) end)

    [
      discovery_check(issuer, document),
      keys_check(document),
      endpoints_check(document, config)
    ]
  end

  @doc """
  The provider as this plane currently sees it: the stored value where there is one, the
  deployment's otherwise.

  One map rather than eight `Settings.get/1` calls at eight sites, so the console's
  authorize request, the code redemption, the discovery document at `/.well-known/troupe`
  and the check are reading one description of the provider. `check/1` takes a candidate
  of the same shape, which is how a value is tested before it is saved.
  """
  @spec configured() :: map()
  def configured do
    %{
      issuer: Settings.get("issuer"),
      client_id: Settings.get("client_id"),
      authorization_endpoint: Settings.get("authorization_endpoint"),
      device_authorization_endpoint: Settings.get("device_authorization_endpoint"),
      token_endpoint: Settings.get("token_endpoint"),
      scopes: Settings.get("scopes"),
      mcp_scope: Settings.get("mcp_scope")
    }
  end

  defp discovery(nil), do: {:error, :no_issuer}

  defp discovery(issuer) do
    case get(discovery_url(issuer)) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_check(nil, _document) do
    check_result("Discovery", false, "No issuer is configured, so there is nobody to ask.", 0)
  end

  defp discovery_check(issuer, {{:ok, document}, took}) do
    published = document["issuer"]

    if published == issuer do
      check_result("Discovery", true, "#{issuer} answered and calls itself the same thing.", took)
    else
      check_result(
        "Discovery",
        false,
        "#{issuer} answered but calls itself #{inspect(published)}. A token from it will be refused, because the issuer in the token is what is checked.",
        took
      )
    end
  end

  defp discovery_check(issuer, {{:error, reason}, took}) do
    check_result("Discovery", false, "#{issuer} did not answer: #{inspect(reason)}.", took)
  end

  defp keys_check({{:ok, document}, _took}) do
    uri = document["jwks_uri"]
    {result, took} = timed(fn -> if uri, do: get(uri), else: {:error, :no_jwks_uri} end)

    case result do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when keys != [] ->
        check_result("Signing keys", true, "#{length(keys)} key(s) at #{uri}.", took)

      {:ok, %{status: 200, body: _empty}} ->
        check_result("Signing keys", false, "#{uri} answered with no keys in it.", took)

      other ->
        check_result(
          "Signing keys",
          false,
          "Could not read #{inspect(uri)}: #{inspect(other)}.",
          took
        )
    end
  end

  defp keys_check({{:error, _reason}, _took}) do
    check_result("Signing keys", false, "Not attempted: discovery did not answer.", 0)
  end

  # The mistake this one exists for: an Entra tenant configured with a v2 issuer and a v1
  # token endpoint. Everything looks right, discovery answers, and every device login fails
  # with a message about the audience.
  defp endpoints_check({{:ok, document}, _took}, config) do
    mismatched =
      for {name, key, published} <- [
            {"token endpoint", :token_endpoint, "token_endpoint"},
            {"device endpoint", :device_authorization_endpoint, "device_authorization_endpoint"}
          ],
          configured = config[key],
          is_binary(document[published]),
          configured != document[published],
          do: "the #{name} is #{configured} but the provider publishes #{document[published]}"

    if mismatched == [] do
      check_result(
        "Endpoints",
        true,
        "What this plane was given matches what the provider publishes.",
        0
      )
    else
      check_result("Endpoints", false, Enum.join(mismatched, "; ") <> ".", 0)
    end
  end

  defp endpoints_check({{:error, _reason}, _took}, _config) do
    check_result("Endpoints", false, "Not attempted: discovery did not answer.", 0)
  end

  @doc false
  @spec check_result(String.t(), boolean(), String.t(), non_neg_integer()) :: map()
  def check_result(name, ok, detail, took) do
    %{name: name, ok: ok, detail: detail, took_ms: took}
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp client_id, do: Settings.get("client_id")

  @doc "The audience a plane token carries, as opposed to a pod's worker id."
  @spec audience() :: String.t()
  def audience, do: Application.get_env(:troupe_plane, :audience, "troupe-plane-api")
end
