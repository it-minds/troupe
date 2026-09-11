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
    case request(:delete, "/v1/#{mount(opts)}/metadata/#{path}", nil, opts) do
      {:ok, status, _body} when status in 200..299 or status == 404 -> :ok
      {:ok, status, _body} -> {:error, {:unexpected_status, status}}
      error -> error
    end
  end

  @impl Troupe.KMS
  def exists?(team, session_id, opts \\ []) do
    match?({:ok, _}, fetch(team, session_id, opts))
  end

  # -- the KV v2 surface ------------------------------------------------------

  defp read_key(path, opts) do
    case request(:get, "/v1/#{mount(opts)}/data/#{path}", nil, opts) do
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
    case request(:post, "/v1/#{mount(opts)}/data/#{path}", %{"data" => data}, opts) do
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
    with {:ok, jwt} <- File.read(service_account_token_path()),
         {:ok, 200, body} <- login(config(opts)[:role] || "troupe-worker", String.trim(jwt), opts) do
      get_in(body, ["auth", "client_token"])
    else
      _ -> nil
    end
  end

  defp login(role, jwt, opts) do
    path = config(opts)[:auth_path] || "kubernetes"
    url = address(opts) <> "/v1/auth/#{path}/login"

    case Req.request(
           method: :post,
           url: url,
           json: %{"role" => role, "jwt" => jwt},
           decode_body: true,
           retry: false
         ) do
      {:ok, response} -> {:ok, response.status, response.body}
      {:error, reason} -> {:error, reason}
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
