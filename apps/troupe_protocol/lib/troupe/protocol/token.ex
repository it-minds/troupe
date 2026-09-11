defmodule Troupe.Protocol.Token do
  @moduledoc """
  Session tokens: what they claim, and what makes one acceptable.

  Minted by the plane, verified by workers **offline** against a cached JWKS. Offline is
  the point: the plane must not be in the data path of a live session, so a worker that
  cannot reach the plane still knows whether the token in front of it is good.

  Two claims carry the weight.

  `aud` is the **pod's worker id**, not the profile and not the plane. A token minted for
  a `ux` pod presented to a `dev` pod fails on audience, which is what stops a token
  leaking sideways from being useful. `exp` is at most fifteen minutes out and nothing is
  accepted past it — a worker warns with `auth.expiring` before that so a client can
  refresh on the same connection rather than reconnecting.

  Roles map to the same three scopes the local daemon uses, so a remote session and a
  local one enforce permissions with the same table:

      owner        -> admin
      collaborator -> control
      viewer       -> observe
  """

  @type claims :: %{optional(String.t()) => term()}
  @type scope :: :observe | :control | :admin

  # The spec's ceiling. A token good for longer is refused at verification as well as at
  # minting, because the mint is not the only place one could come from.
  @max_lifetime_seconds 15 * 60
  # Clocks in a cluster disagree by small amounts, and a token refused for a second of
  # skew would be a flapping outage rather than a security property.
  @leeway_seconds 30

  @roles %{"owner" => :admin, "collaborator" => :control, "viewer" => :observe}

  @doc "The scopes a role carries. Higher scopes include the lower ones."
  @spec scopes_for(String.t() | atom()) :: [scope()]
  def scopes_for(role) when is_atom(role), do: scopes_for(Atom.to_string(role))

  def scopes_for(role) do
    case Map.get(@roles, role) do
      :admin -> [:observe, :control, :admin]
      :control -> [:observe, :control]
      :observe -> [:observe]
      nil -> []
    end
  end

  @doc "The roles a session ACL may carry."
  @spec roles() :: [String.t()]
  def roles, do: Map.keys(@roles)

  @doc "The longest a session token may live."
  @spec max_lifetime_seconds() :: pos_integer()
  def max_lifetime_seconds, do: @max_lifetime_seconds

  @doc """
  Check a token and give back its claims.

  `:audience` is required and is the worker id of the pod doing the checking. Passing
  the profile, or leaving it out, would make every pod of a profile interchangeable and
  the audience check pointless.
  """
  @spec verify(String.t(), map(), keyword()) :: {:ok, claims()} | {:error, atom()}
  def verify(jwt, jwks, opts \\ []) do
    with {:ok, claims} <- check_signature(jwt, jwks),
         :ok <- check_time(claims, opts),
         :ok <- check_audience(claims, opts),
         :ok <- check_issuer(claims, opts) do
      {:ok, claims}
    end
  end

  defp check_signature(jwt, %{"keys" => keys}) do
    kid = peek_kid(jwt)

    keys
    # Try the named key first; fall back to the rest, because a token minted moments
    # before a rotation carries the old `kid` and is still perfectly good.
    |> Enum.sort_by(&(&1["kid"] != kid))
    |> Enum.find_value({:error, :bad_signature}, fn key ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["ES256", "RS256"], jwt) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _ -> nil
      end
    end)
  end

  defp check_signature(_jwt, _jwks), do: {:error, :no_keys}

  defp check_time(claims, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    leeway = Keyword.get(opts, :leeway, @leeway_seconds)

    cond do
      not is_integer(claims["exp"]) -> {:error, :no_expiry}
      claims["exp"] + leeway < now -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] - leeway > now -> {:error, :not_yet_valid}
      too_long?(claims, opts) -> {:error, :lifetime_too_long}
      true -> :ok
    end
  end

  # The ceiling applies to tokens *Troupe* mints, which is what it is a rule about: a
  # leaked worker token is a fifteen-minute problem and no longer. An identity provider's
  # id_token is not one of those — its lifetime is the provider's policy, and a plane that
  # refused every provider whose default is an hour would refuse almost all of them. Those
  # callers pass `max_lifetime: :any` and rely on `exp`, the signature and the audience.
  defp too_long?(claims, opts) do
    case Keyword.get(opts, :max_lifetime, @max_lifetime_seconds) do
      :any ->
        false

      seconds ->
        is_integer(claims["iat"]) and claims["exp"] - claims["iat"] > seconds
    end
  end

  defp check_audience(claims, opts) do
    case Keyword.fetch(opts, :audience) do
      {:ok, audience} ->
        if audience in List.wrap(claims["aud"]), do: :ok, else: {:error, :wrong_audience}

      :error ->
        {:error, :no_audience_given}
    end
  end

  defp check_issuer(claims, opts) do
    case Keyword.get(opts, :issuer) do
      nil -> :ok
      issuer -> if claims["iss"] == issuer, do: :ok, else: {:error, :wrong_issuer}
    end
  end

  @doc "The claims without checking anything. Diagnostics only, never a decision."
  @spec peek(String.t()) :: {:ok, claims()} | {:error, :malformed}
  def peek(jwt) do
    case String.split(jwt, ".") do
      [_header, payload, _signature] -> decode_segment(payload)
      _ -> {:error, :malformed}
    end
  end

  @doc "The `kid` in a token's header, for choosing a key out of a JWKS."
  @spec peek_kid(String.t()) :: String.t() | nil
  def peek_kid(jwt) do
    with [header, _payload, _signature] <- String.split(jwt, "."),
         {:ok, decoded} <- decode_segment(header) do
      decoded["kid"]
    else
      _ -> nil
    end
  end

  @doc "How long a token has left, in seconds. Negative once it has expired."
  @spec remaining(claims(), integer()) :: integer()
  def remaining(claims, now \\ System.system_time(:second))
  def remaining(%{"exp" => exp}, now) when is_integer(exp), do: exp - now
  def remaining(_claims, _now), do: 0

  @doc """
  The RFC 7638 thumbprint of a JWK, used as its `kid`.

  Derived rather than assigned, so the same key gets the same `kid` in the plane that
  minted it and in the JWKS a worker fetched, with nothing to keep in step.
  """
  @spec thumbprint(map()) :: String.t()
  def thumbprint(%{"kty" => "EC"} = jwk) do
    digest(%{"crv" => jwk["crv"], "kty" => "EC", "x" => jwk["x"], "y" => jwk["y"]})
  end

  def thumbprint(%{"kty" => "RSA"} = jwk) do
    digest(%{"e" => jwk["e"], "kty" => "RSA", "n" => jwk["n"]})
  end

  defp digest(canonical) do
    :sha256
    |> :crypto.hash(Jason.encode!(canonical))
    |> Base.url_encode64(padding: false)
  end

  defp decode_segment(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :malformed}
    end
  end
end
