defmodule Troupe.KMS.OpenBao do
  @moduledoc """
  Session keys in OpenBao's KV v2 engine.

  KV v2 rather than v1 for one reason: `DELETE /metadata/<path>` removes every version
  of a secret, and erasure has to leave nothing that can be rolled back to. A v1 delete
  removes the current value, and a versioned store without that call would keep the key
  alive in its own history.

  Two ways to authenticate. In a pod, Kubernetes auth: the worker presents its projected
  ServiceAccount token and OpenBao gives back a token whose policy allows the paths of
  its profile's granted teams — which is what stops a `ux` pod reading a `dev` team's
  keys. Outside one, a token from configuration, which is how the development server is
  reached.
  """

  @behaviour Troupe.KMS

  @impl Troupe.KMS
  def create(team, session_id, opts \\ []) do
    path = Troupe.KMS.path(team, session_id)

    case read_key(path, opts) do
      # Idempotent: a session whose key already exists is a retry, not a second session,
      # and overwriting would strand every segment written under the old key.
      {:ok, key} ->
        {:ok, key}

      {:error, :not_found} ->
        key = Troupe.KMS.generate()

        case write(path, %{"key" => Base.encode64(key)}, opts) do
          :ok -> {:ok, key}
          error -> error
        end

      error ->
        error
    end
  end

  @impl Troupe.KMS
  def fetch(team, session_id, opts \\ []) do
    read_key(Troupe.KMS.path(team, session_id), opts)
  end

  @impl Troupe.KMS
  def destroy(team, session_id, opts \\ []) do
    path = Troupe.KMS.path(team, session_id)

    # `metadata`, not `data`: this is the call that removes every version. Deleting the
    # data would leave the key readable at its previous version, which is not erasure.
    case request(:delete, "/v1/#{mount(opts)}/metadata/#{encode(path)}", nil, opts) do
      {:ok, status, _body} when status in 200..299 or status == 404 -> :ok
      {:ok, status, _body} -> {:error, {:unexpected_status, status}}
      error -> error
    end
  end

  @impl Troupe.KMS
  def exists?(team, session_id, opts \\ []) do
    match?({:ok, _}, fetch(team, session_id, opts))
  end

  # A key path is a *logical* path — it is what the policy matches on and what the store
  # files the secret under — and a URL is not. `idp|ada` is a perfectly ordinary subject
  # (Auth0 writes every one of them that way) and a perfectly invalid request target, so
  # a person's key would fail at the HTTP client with `:invalid_request_target` and never
  # reach OpenBao at all.
  #
  # Segment by segment, so the separators survive: the whole path encoded in one call
  # would turn every `/` into `%2F` and address one secret with a very long name.
  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  # -- the KV v2 surface ------------------------------------------------------

  defp read_key(path, opts) do
    case request(:get, "/v1/#{mount(opts)}/data/#{encode(path)}", nil, opts) do
      {:ok, 200, body} -> decode_key(body)
      {:ok, 404, _body} -> {:error, :not_found}
      {:ok, 403, _body} -> {:error, :forbidden}
      {:ok, status, _body} -> {:error, {:unexpected_status, status}}
      error -> error
    end
  end

  defp decode_key(body) do
    case get_in(body, ["data", "data", "key"]) do
      nil ->
        {:error, :malformed}

      encoded ->
        case Base.decode64(encoded) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, :malformed}
        end
    end
  end

  defp write(path, data, opts) do
    case request(:post, "/v1/#{mount(opts)}/data/#{encode(path)}", %{"data" => data}, opts) do
      {:ok, status, _body} when status in 200..299 -> :ok
      {:ok, status, _body} -> {:error, {:unexpected_status, status}}
      error -> error
    end
  end

  # -- transport --------------------------------------------------------------

  defp request(method, path, body, opts) do
    request =
      [
        method: method,
        url: address(opts) <> path,
        headers: [{"x-vault-token", token(opts) || ""}],
        decode_body: true,
        retry: false,
        receive_timeout: 15_000
      ]
      |> then(fn request -> if body, do: Keyword.put(request, :json, body), else: request end)

    case Req.request(request) do
      {:ok, response} -> {:ok, response.status, response.body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config(opts), do: Keyword.merge(Application.get_env(:troupe_worker, :kms, []), opts)

  defp address(opts) do
    config(opts)[:address] || System.get_env("TROUPE_BAO_ADDR") || "http://localhost:8200"
  end

  defp mount(opts), do: config(opts)[:mount] || "secret"

  # A token from configuration outside a pod; inside one, the token Kubernetes auth
  # exchanged the ServiceAccount token for.
  defp token(opts) do
    config(opts)[:token] || System.get_env("TROUPE_BAO_TOKEN") || kubernetes_token(opts)
  end

  defp kubernetes_token(opts) do
    auth_path = config(opts)[:auth_path] || "kubernetes"
    role = config(opts)[:role] || "troupe-worker"

    with {:ok, jwt} <- File.read(service_account_token_path()),
         {:ok, %{token: token}} <- kubernetes_login(address(opts), auth_path, role, jwt) do
      token
    else
      _ -> nil
    end
  end

  @doc """
  Exchange a Kubernetes ServiceAccount token for an OpenBao client token.

  One login for every component that authenticates this way: a worker under its
  profile's role, the plane under its own. The roles differ — that is the point of
  them — but the exchange is the same call, and the plane gets back the same shape a
  worker does: the token, and the number of seconds OpenBao will honour it. A lease of
  zero is a token that does not expire, which is what a root or periodic token reports.
  """
  @spec kubernetes_login(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{token: String.t(), lease_duration: non_neg_integer()}} | {:error, term()}
  def kubernetes_login(address, auth_path, role, jwt) do
    case Req.request(
           method: :post,
           url: address <> "/v1/auth/#{auth_path}/login",
           json: %{"role" => role, "jwt" => String.trim(jwt)},
           decode_body: true,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"auth" => %{"client_token" => token} = auth}}} ->
        {:ok, %{token: token, lease_duration: Map.get(auth, "lease_duration", 0)}}

      {:ok, %{status: 200}} ->
        {:error, :malformed}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exchange a plane-minted assertion for a key-manager token of that person.

  The same shape as `kubernetes_login/4` and for the same reason: one login per way of
  proving who you are, answering the token and its lease. What differs is what is being
  proved — a pod proves it is a pod of a profile, this proves it is acting for a person
  the plane vouched for — and OpenBao verifies the signature against the transit key
  rather than taking anybody's word for it.
  """
  @spec jwt_login(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{token: String.t(), lease_duration: non_neg_integer()}} | {:error, term()}
  def jwt_login(address, auth_path, role, assertion) do
    case Req.request(
           method: :post,
           url: address <> "/v1/auth/#{auth_path}/login",
           json: %{"role" => role, "jwt" => String.trim(assertion)},
           decode_body: true,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"auth" => %{"client_token" => token} = auth}}} ->
        {:ok, %{token: token, lease_duration: Map.get(auth, "lease_duration", 0)}}

      {:ok, %{status: 200}} ->
        {:error, :malformed}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp service_account_token_path do
    Application.get_env(
      :troupe_worker,
      :service_account_token_path,
      "/var/run/secrets/kubernetes.io/serviceaccount/token"
    )
  end
end
