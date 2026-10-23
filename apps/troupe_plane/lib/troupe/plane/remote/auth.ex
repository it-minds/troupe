defmodule Troupe.Plane.Remote.Auth do
  @moduledoc """
  Who is on each end of a relayed session, from the tokens they present.

  A laptop presents its person's plane token, the one `/rpc` takes, or the token its own
  grant was exchanged for, which takes only the laptop's door. A viewer presents
  the token `remote.open` minted for them: for one session, at one role, with the relay's
  own audience, so it opens nothing else, not a pod and not `/rpc`. Either way the person
  must still be an active account here, as every `/rpc` call asks.
  """

  alias Troupe.Plane.{Identity, OIDC, Remote, Tokens}
  alias Troupe.Plane.Identity.User
  alias Troupe.Protocol.{Error, Token}

  @doc "A plane token's person and claims."
  @spec person(String.t() | nil) :: {:ok, User.t(), map()} | {:error, Error.t()}
  def person(token), do: verify(token, OIDC.audience())

  @doc """
  Who is at the laptop's door: a plane token, as a client hands one over, or the token
  the daemon's own grant was exchanged for (`Troupe.Plane.Remote.redeem/1`), which opens
  this door and no other and names the one device it may speak for.
  """
  @spec laptop(String.t() | nil, String.t() | nil) :: {:ok, User.t(), map()} | {:error, Error.t()}
  def laptop(token, device) do
    with {:ok, user, claims} <- verify(token, [OIDC.audience(), Remote.laptop_audience()]) do
      if Remote.laptop_audience() in List.wrap(claims["aud"]) and claims["device"] != device,
        do: {:error, Error.new(:unauthenticated, %{reason: "a token for another device"})},
        else: {:ok, user, claims}
    end
  end

  @doc "A relay token's person and claims, which name the session and the role."
  @spec viewer(String.t() | nil) :: {:ok, User.t(), map()} | {:error, Error.t()}
  def viewer(token) do
    with {:ok, user, claims} <- verify(token, Remote.audience()) do
      if is_binary(claims["session_id"]) and is_binary(claims["role"]),
        do: {:ok, user, claims},
        else: {:error, Error.new(:unauthenticated, %{reason: "not a token for a session"})}
    end
  end

  defp verify(token, audience) when is_binary(token) and token != "" do
    with {:ok, jwks} <- Tokens.jwks(),
         {:ok, claims} <- Token.verify(token, jwks, audience: audience),
         %User{active: true} = user <- Identity.get_user(claims["sub"]) do
      {:ok, user, claims}
    else
      %User{} -> {:error, Error.new(:forbidden, %{reason: "account deactivated"})}
      nil -> {:error, Error.new(:unauthenticated, %{reason: "no such user"})}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:unauthenticated, %{reason: to_string(reason)})}
    end
  end

  defp verify(_token, _audience), do: {:error, Error.new(:unauthenticated, %{reason: "no token"})}
end
