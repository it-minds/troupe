defmodule Troupe.Plane.PersonAuth do
  @moduledoc """
  What an operator writes once so a person can be vouched for at the development
  OpenBao: the person policy, a JWT auth mount, and a role bound to the plane's issuer
  and the key manager's audience, verifying against the transit key's public half.

  A compiled module rather than a helper in one test file, because the worker's suite
  proves a pod's half of the same exchange against a real plane and needs the same mount.
  Every call writes the same configuration, so two suites doing it are one.
  """

  alias Troupe.KMS.Policy
  alias Troupe.Plane.Tokens

  @doc """
  Configure the mount at `auth_path` with `role`, trusting assertions from `issuer`.
  """
  @spec configure(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def configure(auth_path, role, issuer) do
    with {:ok, jwk} <- Tokens.public_jwk(),
         pem <- jwk |> JOSE.JWK.from_map() |> JOSE.JWK.to_pem() |> elem(1),
         :ok <- enable_auth(auth_path),
         {:ok, accessor} <- auth_accessor(auth_path),
         # The policy templates on the *mount accessor*, not the mount path: a path can
         # be re-used after a mount is deleted and an accessor cannot, so a policy keyed
         # to the path could one day read a subtree written under a different mount.
         :ok <-
           put("/v1/sys/policies/acl/#{Policy.person_policy_name()}", %{
             "policy" => Policy.person(mount(), accessor)
           }),
         :ok <- put("/v1/auth/#{auth_path}/config", Policy.person_auth_config([pem])) do
      put("/v1/auth/#{auth_path}/role/#{role}", Policy.person_role(issuer, Tokens.kms_audience()))
    end
  end

  @doc "Whether the development OpenBao answers at all."
  @spec reachable?() :: boolean()
  def reachable? do
    match?(
      {:ok, %{status: 200}},
      Req.request(method: :get, url: address() <> "/v1/sys/health", retry: false)
    )
  rescue
    _ -> false
  end

  @doc "The development OpenBao, as the plane is configured to reach it."
  @spec address() :: String.t()
  def address, do: Application.get_env(:troupe_plane, :transit, [])[:address]

  @doc "A POST with the root token, which is what an operator writes configuration with."
  @spec put(String.t(), map()) :: :ok | {:error, term()}
  def put(path, body) do
    case Req.request(
           method: :post,
           url: address() <> path,
           headers: [{"x-vault-token", root_token()}],
           json: body,
           decode_body: true,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root_token, do: Application.get_env(:troupe_plane, :transit, [])[:token]
  defp mount, do: "secret"

  defp auth_accessor(auth_path) do
    case Req.request(
           method: :get,
           url: address() <> "/v1/sys/auth",
           headers: [{"x-vault-token", root_token()}],
           decode_body: true,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        case get_in(body, ["data", "#{auth_path}/", "accessor"]) ||
               get_in(body, ["#{auth_path}/", "accessor"]) do
          accessor when is_binary(accessor) -> {:ok, accessor}
          _ -> {:error, {:no_accessor, body}}
        end

      other ->
        {:error, other}
    end
  end

  # Enabling twice is not an error worth failing a suite over: the mount is per-server
  # and every run after the first finds it already there.
  defp enable_auth(auth_path) do
    case put("/v1/sys/auth/#{auth_path}", %{"type" => "jwt"}) do
      :ok ->
        :ok

      {:error, {:status, 400, body}} ->
        if inspect(body) =~ "already in use", do: :ok, else: {:error, body}

      error ->
        error
    end
  end
end
