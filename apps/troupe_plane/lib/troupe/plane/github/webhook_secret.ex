defmodule Troupe.Plane.GitHub.WebhookSecret do
  @moduledoc """
  The GitHub App's webhook secret, in OpenBao's transit engine and nowhere else.

  GitHub signs every delivery it sends the App's webhook with an HMAC-SHA256 of the body,
  keyed by a secret an administrator types into the App's settings, and sends it as
  `X-Hub-Signature-256: sha256=<hex>`. Whoever holds the secret can sign a delivery the
  plane would take for GitHub's, and a delivery can start a session, so the secret is kept
  the way the App's private key is (`Troupe.Plane.GitHub.Key`): imported once into transit
  as an HMAC key that cannot be exported, and never in a row, a log or an audit entry.

  The plane asks transit for the HMAC of each delivery's body and compares it with the
  signature it was sent, in constant time, itself. A second secret is the key's next
  version, which is the rotation; transit computes with the newest.

  The transit key is `troupe-github-webhook` unless the deployment names another
  (`:github_webhook_key` in the plane's `:transit` configuration), on the session-token
  key's mount. `Troupe.KMS.Policy.github_app/3` names what the plane's role needs for it.
  """

  alias Troupe.Plane.GitHub.Key
  alias Troupe.Plane.Tokens

  @default_name "troupe-github-webhook"

  # Short secrets are guessable from a signed delivery, and transit takes an HMAC key of 32
  # bytes and more. `openssl rand -hex 32` makes one.
  @min_bytes 32
  @max_bytes 512

  @doc "The transit key's name."
  @spec name(keyword()) :: String.t()
  def name(opts \\ []) do
    Keyword.get_lazy(opts, :github_webhook_key, fn ->
      Application.get_env(:troupe_plane, :transit, [])[:github_webhook_key] || @default_name
    end)
  end

  @doc "Whether a secret will do, before anything is written: its length, as a sentence."
  @spec read(term()) :: :ok | {:error, String.t()}
  def read(secret) when is_binary(secret) do
    cond do
      byte_size(secret) < @min_bytes ->
        {:error,
         "a webhook secret is at least #{@min_bytes} characters; `openssl rand -hex 32` makes one"}

      byte_size(secret) > @max_bytes ->
        {:error, "a webhook secret is at most #{@max_bytes} characters"}

      true ->
        :ok
    end
  end

  def read(_secret), do: {:error, "the webhook secret is the text typed into the App's settings"}

  @doc """
  Import a secret into transit: a new HMAC key, or the next version of the one there.
  Answers the version transit now holds it at.
  """
  @spec import(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def import(secret, opts \\ []) do
    with :ok <- read(secret),
         {:ok, wrapping} <- Key.wrapping_key(opts),
         ciphertext = Key.wrap(secret, wrapping),
         {:ok, _} <- import_or_rotate(ciphertext, opts) do
      latest_version(opts)
    end
  end

  @doc """
  Whether `signature`, the `X-Hub-Signature-256` header as GitHub sends it, is the HMAC of
  `body` under the secret in transit. `:unsigned` for no header or one that is not
  `sha256=` and 64 hex digits; `:mismatch` for one that does not match; an error for a
  transit that could not answer. The comparison is constant-time.
  """
  @spec check(binary(), String.t() | nil, keyword()) ::
          :ok | {:error, :unsigned | :mismatch | term()}
  def check(body, signature, opts \\ [])

  def check(body, "sha256=" <> hex, opts) when is_binary(body) and byte_size(hex) == 64 do
    with {:ok, presented} <- Base.decode16(hex, case: :mixed) |> or_unsigned(),
         {:ok, expected} <- hmac(body, opts) do
      if :crypto.hash_equals(expected, presented), do: :ok, else: {:error, :mismatch}
    end
  end

  def check(_body, _signature, _opts), do: {:error, :unsigned}

  defp or_unsigned({:ok, bytes}), do: {:ok, bytes}
  defp or_unsigned(:error), do: {:error, :unsigned}

  # Transit answers `vault:v<version>:<base64>`; the 32 bytes after it are the HMAC.
  defp hmac(body, opts) do
    path = "/v1/#{Tokens.mount(opts)}/hmac/#{name(opts)}/sha2-256"

    case Tokens.request(:post, path, %{"input" => Base.encode64(body)}, opts) do
      {:ok, %{"data" => %{"hmac" => "vault:v" <> rest}}} ->
        [_version, encoded] = String.split(rest, ":", parts: 2)
        {:ok, Base.decode64!(encoded)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, :not_found} ->
        {:error, :no_secret}

      error ->
        error
    end
  end

  defp import_or_rotate(ciphertext, opts) do
    path = "/v1/#{Tokens.mount(opts)}/keys/#{name(opts)}"

    case Tokens.request(:get, path, nil, opts) do
      {:error, :not_found} ->
        Tokens.request(
          :post,
          path <> "/import",
          %{
            "ciphertext" => ciphertext,
            "type" => "hmac",
            "hash_function" => "SHA256",
            "exportable" => false,
            "allow_plaintext_backup" => false
          },
          opts
        )

      {:ok, %{"data" => %{"type" => "hmac"}}} ->
        Tokens.request(:post, path <> "/import_version", %{"ciphertext" => ciphertext}, opts)

      {:ok, %{"data" => %{"type" => other}}} ->
        {:error, {:key_type, other, "hmac"}}

      error ->
        error
    end
  end

  defp latest_version(opts) do
    case Tokens.request(:get, "/v1/#{Tokens.mount(opts)}/keys/#{name(opts)}", nil, opts) do
      {:ok, %{"data" => %{"latest_version" => version}}} -> {:ok, version}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      error -> error
    end
  end
end
