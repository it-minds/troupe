defmodule Troupe.Plane.Tokens do
  @moduledoc """
  Minting session tokens, without ever holding a signing key.

  The plane assembles the header and the payload and asks OpenBao's transit engine to
  sign the result. The private key never leaves OpenBao and the plane has no way to
  export it, so a compromised plane can mint tokens while it is compromised and forge
  nothing afterwards — and the same OpenBao policy that allows signing allows nothing
  under the session-key paths, which is the Forbidden list's "no plane credential that
  can read session keys".

  ES256 over P-256, because the public half is a JWK a worker can cache and check
  offline, and because transit will marshal an ECDSA signature in JWS form directly.

  The `kid` is the key's RFC 7638 thumbprint rather than a name we assign, so the plane
  that minted a token and the worker that fetched the JWKS agree on it with nothing kept
  in step between them.
  """

  alias Troupe.Protocol.Token

  @key_name "troupe-session-tokens"
  @default_lifetime 15 * 60

  @doc """
  Mint a session token.

  `:audience` is the pod's worker id — required, and the reason a token cannot be
  replayed against another pod of the same profile.
  """
  @spec mint(map(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def mint(claims, opts \\ []) do
    lifetime = min(Keyword.get(opts, :lifetime, @default_lifetime), Token.max_lifetime_seconds())
    now = Keyword.get(opts, :now, System.system_time(:second))

    audience =
      Keyword.get_lazy(opts, :audience, fn -> Map.get(claims, "aud") end)

    payload =
      claims
      |> Map.merge(%{
        "aud" => audience,
        "iat" => now,
        "nbf" => now,
        "exp" => now + lifetime,
        "jti" => 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      })
      |> put_issuer(opts)

    with {:ok, jwk} <- public_jwk(opts),
         header = %{"alg" => "ES256", "typ" => "JWT", "kid" => Token.thumbprint(jwk)},
         signing_input = segment(header) <> "." <> segment(payload),
         {:ok, signature} <- sign(signing_input, opts) do
      {:ok, signing_input <> "." <> signature, payload}
    end
  end

  defp put_issuer(payload, opts) do
    case Keyword.get(opts, :issuer, issuer()) do
      nil -> payload
      issuer -> Map.put(payload, "iss", issuer)
    end
  end

  @doc """
  The JWKS a worker caches.

  Every version of the transit key, not only the current one: a token minted moments
  before a rotation carries the old `kid` and stays good until it expires.
  """
  @spec jwks(keyword()) :: {:ok, map()} | {:error, term()}
  def jwks(opts \\ []) do
    case read_key(opts) do
      {:ok, %{"keys" => versions}} ->
        keys =
          versions
          |> Enum.sort_by(fn {version, _} -> -String.to_integer(version) end)
          |> Enum.flat_map(fn {_version, %{"public_key" => pem}} -> [jwk_of(pem)] end)
          |> Enum.reject(&is_nil/1)

        {:ok, %{"keys" => keys}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The current public key as a JWK, which is what a `kid` is derived from."
  @spec public_jwk(keyword()) :: {:ok, map()} | {:error, term()}
  def public_jwk(opts \\ []) do
    with {:ok, %{"keys" => versions, "latest_version" => latest}} <- read_key(opts) do
      case versions[Integer.to_string(latest)] do
        %{"public_key" => pem} -> {:ok, jwk_of(pem)}
        _ -> {:error, :no_public_key}
      end
    end
  end

  defp jwk_of(pem) do
    {_module, map} = pem |> JOSE.JWK.from_pem() |> JOSE.JWK.to_map()

    map
    |> Map.put("use", "sig")
    |> Map.put("alg", "ES256")
    |> then(&Map.put(&1, "kid", Token.thumbprint(&1)))
  rescue
    _ -> nil
  end

  # -- OpenBao ----------------------------------------------------------------

  defp sign(signing_input, opts) do
    body = %{
      "input" => Base.encode64(signing_input),
      "hash_algorithm" => "sha2-256",
      # Transit's JWS marshalling is r || s, fixed width — exactly what ES256 wants.
      # Its default is ASN.1 DER, which no JWT verifier will accept.
      "marshaling_algorithm" => "jws"
    }

    case request(:post, "/v1/#{mount(opts)}/sign/#{key_name(opts)}", body, opts) do
      {:ok, %{"data" => %{"signature" => signature}}} -> {:ok, strip(signature)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  # `vault:v1:<signature>`, and with JWS marshalling the signature is already unpadded
  # base64url — which is what a JWT wants, so there is nothing to convert. The key
  # version is implied by the `kid`, so only the bytes matter here.
  defp strip(signature), do: signature |> String.split(":") |> List.last()

  defp read_key(opts) do
    request(:get, "/v1/#{mount(opts)}/keys/#{key_name(opts)}", nil, opts)
    |> case do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end

  defp request(method, path, body, opts) do
    options =
      [
        method: method,
        url: address(opts) <> path,
        headers: [{"x-vault-token", token(opts)}],
        decode_body: true,
        retry: false,
        receive_timeout: 5_000
      ] ++ if(body, do: [json: body], else: [])

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config(opts), do: Keyword.merge(Application.get_env(:troupe_plane, :transit, []), opts)

  defp address(opts) do
    config(opts)[:address] || System.get_env("TROUPE_BAO_ADDR") || "http://localhost:58200"
  end

  defp mount(opts), do: config(opts)[:mount] || "transit"
  defp key_name(opts), do: config(opts)[:key] || @key_name

  defp token(opts) do
    config(opts)[:token] || System.get_env("TROUPE_BAO_TOKEN") ||
      read_service_account_token() || "troupe-dev-root"
  end

  # In a pod the plane authenticates to OpenBao with its own Kubernetes ServiceAccount;
  # the login exchange happens outside this module and leaves the client token here.
  defp read_service_account_token do
    case File.read("/var/run/secrets/troupe/bao-token") do
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp issuer, do: Application.get_env(:troupe_plane, :issuer)

  defp segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
