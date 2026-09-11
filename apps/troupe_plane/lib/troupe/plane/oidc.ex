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

  alias Troupe.Plane.{Identity, Login, Tokens}
  alias Troupe.Protocol.Token

  require Logger

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
           "profiles" => Identity.profiles_for(user) |> Enum.map(& &1.profile) |> Enum.uniq() |> Enum.sort()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check a provider token and give back its claims.

  `:verifier` replaces the whole check, which is how a test supplies an issuer it
  controls. In a cluster it is the provider's own keys, fetched from discovery.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(id_token, opts \\ []) do
    case Keyword.get(opts, :verifier) || configured_verifier() do
      nil -> {:error, :no_issuer_configured}
      verifier when is_function(verifier, 1) -> verifier.(id_token)
    end
  end

  defp configured_verifier do
    case Application.get_env(:troupe_plane, :oidc_verifier) do
      nil -> default_verifier()
      verifier -> verifier
    end
  end

  # The provider's discovery document names its JWKS, and that is what a token is checked
  # against. Cached for the life of the VM: a provider that rotates keys publishes both
  # for an overlap, and a plane that refetched on every login would be a load generator.
  defp default_verifier do
    case Application.get_env(:troupe_plane, :oidc, [])[:issuer] do
      nil -> nil
      issuer -> &verify_against_provider(&1, issuer)
    end
  end

  defp verify_against_provider(id_token, issuer) do
    with {:ok, jwks} <- provider_jwks(issuer) do
      Token.verify(id_token, jwks, audience: client_id(), issuer: issuer)
    end
  end

  defp provider_jwks(issuer) do
    case :persistent_term.get({__MODULE__, :jwks, issuer}, nil) do
      nil -> fetch_jwks(issuer)
      jwks -> {:ok, jwks}
    end
  end

  defp fetch_jwks(issuer) do
    with {:ok, %{status: 200, body: discovery}} <- get(issuer <> "/.well-known/openid-configuration"),
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

  defp client_id, do: Application.get_env(:troupe_plane, :oidc, [])[:client_id]

  @doc "The audience a plane token carries, as opposed to a pod's worker id."
  @spec audience() :: String.t()
  def audience, do: Application.get_env(:troupe_plane, :audience, "troupe-plane-api")
end
