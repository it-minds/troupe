defmodule Troupe.Plane.GitHub.Key do
  @moduledoc """
  The GitHub App's private key, in OpenBao's transit engine and nowhere else.

  An App proves who it is with a JWT signed by a private key GitHub generated for it.
  Whoever holds that key is the App, on every repository it is installed on, so the key
  is put where nothing can take a copy: transit, as a key that is not exportable. The
  plane asks transit to sign an App JWT and gets a signature back; it never holds the
  key, and neither does a backup of its database.

  A person hands the key over once, as the PEM GitHub downloads, through
  `admin.github.put`. The plane wraps it for transit's bring-your-own-key import (the
  key under a fresh AES-256 key with RFC 5649 key wrap, that key under transit's RSA
  wrapping key with OAEP and SHA-256) and imports it, then forgets the PEM: it is in no
  row, no log and no audit entry. A key already there gets the new one as its next
  version, which is how a key is rotated, and transit signs with the latest.

  The transit key is `troupe-github-app` unless the deployment names another
  (`:github_key` in the plane's `:transit` configuration), on the mount the session-token
  key is on. `Troupe.KMS.Policy.github_app/2` is what the plane's role needs for it.
  """

  alias Troupe.Plane.Tokens

  @default_name "troupe-github-app"

  # The sizes transit imports, by the type it names them.
  @sizes %{2048 => "rsa-2048", 3072 => "rsa-3072", 4096 => "rsa-4096"}

  @typedoc "What is known about a key once it is in transit: never the key."
  @type description :: %{type: String.t(), fingerprint: String.t(), version: pos_integer()}

  @doc "The transit key's name."
  @spec name(keyword()) :: String.t()
  def name(opts \\ []) do
    Keyword.get_lazy(opts, :github_key, fn ->
      Application.get_env(:troupe_plane, :transit, [])[:github_key] || @default_name
    end)
  end

  @doc """
  What a PEM holds, without importing it: its transit type and its fingerprint, or why it
  is not a key the plane can use. Read first, so a key that will not do is refused before
  anything is written.
  """
  @spec read(String.t()) ::
          {:ok, %{type: String.t(), fingerprint: String.t()}} | {:error, String.t()}
  def read(pem) do
    with {:ok, key} <- private_key(pem), do: describe(key)
  end

  @doc """
  Import a PEM into transit: a new key, or the next version of the one there.
  Answers what is known about it now: its type, fingerprint and version.
  """
  @spec import(String.t(), keyword()) :: {:ok, description()} | {:error, term()}
  def import(pem, opts \\ []) do
    with {:ok, key} <- private_key(pem),
         {:ok, %{type: type, fingerprint: fingerprint}} <- describe(key),
         {:ok, wrapping} <- wrapping_key(opts),
         ciphertext = wrap(:public_key.der_encode(:PrivateKeyInfo, key), wrapping),
         {:ok, _} <- import_or_rotate(ciphertext, type, opts),
         {:ok, version} <- latest_version(opts) do
      {:ok, %{type: type, fingerprint: fingerprint, version: version}}
    end
  end

  @doc """
  Sign a JWT's signing input with the App's key, as RS256: transit hashes it with SHA-256
  and signs with PKCS #1 v1.5, and the signature comes back base64url, as a JWT carries it.
  """
  @spec sign(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sign(signing_input, opts \\ []) do
    body = %{
      "input" => Base.encode64(signing_input),
      "hash_algorithm" => "sha2-256",
      "signature_algorithm" => "pkcs1v15"
    }

    case Tokens.request(:post, "/v1/#{Tokens.mount(opts)}/sign/#{name(opts)}", body, opts) do
      {:ok, %{"data" => %{"signature" => "vault:v" <> rest}}} ->
        [_version, signature] = String.split(rest, ":", parts: 2)
        {:ok, signature |> Base.decode64!() |> Base.url_encode64(padding: false)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, :not_found} ->
        {:error, :no_key}

      error ->
        error
    end
  end

  # -- reading a PEM ----------------------------------------------------------

  # GitHub hands out PKCS #1 (`BEGIN RSA PRIVATE KEY`); PKCS #8 (`BEGIN PRIVATE KEY`) is
  # what `openssl pkcs8` makes of it, and both decode to the same record.
  defp private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{_type, _der, :not_encrypted} = entry | _] ->
        rsa(:public_key.pem_entry_decode(entry))

      [{_type, _der, _cipher} | _] ->
        {:error, "the key is encrypted; give it as GitHub downloads it"}

      [] ->
        {:error, "not a PEM private key"}
    end
  rescue
    _ -> {:error, "not a PEM private key"}
  end

  defp private_key(_other), do: {:error, "a private key is the PEM text GitHub downloads"}

  defp rsa(key) when elem(key, 0) == :RSAPrivateKey, do: {:ok, key}
  defp rsa(_key), do: {:error, "a GitHub App's key is an RSA key, and this is not one"}

  defp describe(key) do
    bits = key |> elem(2) |> :binary.encode_unsigned() |> bit_size()

    case Map.fetch(@sizes, bits) do
      {:ok, type} ->
        {:ok, %{type: type, fingerprint: fingerprint(key)}}

      :error ->
        {:error, "an RSA key of #{bits} bits; transit imports 2048, 3072 or 4096"}
    end
  end

  # As GitHub shows it beside each of an App's keys: the SHA-256 of the public key's
  # SubjectPublicKeyInfo, in base64.
  defp fingerprint(key) do
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    {:SubjectPublicKeyInfo, der, _} = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)
    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, der))
  end

  # -- transit's import -------------------------------------------------------

  defp wrapping_key(opts) do
    case Tokens.request(:get, "/v1/#{Tokens.mount(opts)}/wrapping_key", nil, opts) do
      {:ok, %{"data" => %{"public_key" => pem}}} ->
        [entry] = :public_key.pem_decode(pem)
        {:ok, :public_key.pem_entry_decode(entry)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  @doc false
  # Transit's bring-your-own-key format: a fresh AES-256 key wrapped under transit's RSA
  # wrapping key with OAEP (SHA-256 for the hash and the mask), followed by the target key
  # wrapped under that AES key with RFC 5649. Public for the test of the key wrap alone.
  @spec wrap(binary(), term()) :: String.t()
  def wrap(target, wrapping_key) do
    ephemeral = :crypto.strong_rand_bytes(32)

    wrapped_key =
      :public_key.encrypt_public(ephemeral, wrapping_key,
        rsa_padding: :rsa_pkcs1_oaep_padding,
        rsa_oaep_md: :sha256,
        rsa_mgf1_md: :sha256
      )

    Base.encode64(wrapped_key <> key_wrap(ephemeral, target))
  end

  @doc false
  # AES key wrap with padding, RFC 5649: RFC 3394's six rounds over the padded key, with
  # the alternative initial value that carries its length. A key of eight bytes or less is
  # one block. The cipher follows the length of `kek`.
  @spec key_wrap(binary(), binary()) :: binary()
  def key_wrap(kek, plaintext) do
    length = byte_size(plaintext)
    padded = plaintext <> :binary.copy(<<0>>, rem(8 - rem(length, 8), 8))
    initial = <<0xA6, 0x59, 0x59, 0xA6, length::32>>

    case padded do
      <<_one::binary-8>> ->
        encrypt(kek, initial <> padded)

      _ ->
        blocks = for <<block::binary-8 <- padded>>, do: block
        {check, wrapped} = rounds(kek, initial, blocks)
        IO.iodata_to_binary([check | wrapped])
    end
  end

  defp rounds(kek, initial, blocks) do
    n = length(blocks)

    Enum.reduce(0..5, {initial, blocks}, fn j, {a, r} ->
      {a, reversed} =
        r
        |> Enum.with_index(1)
        |> Enum.reduce({a, []}, fn {block, i}, {a, acc} ->
          <<high::binary-8, low::binary-8>> = encrypt(kek, a <> block)
          {:crypto.exor(high, <<n * j + i::64>>), [low | acc]}
        end)

      {a, Enum.reverse(reversed)}
    end)
  end

  defp encrypt(kek, block), do: :crypto.crypto_one_time(:aes_ecb, kek, block, true)

  # A key that is not there is imported; one that is gets this as its next version, which
  # is a rotation: the App keeps working with the old key until GitHub forgets it, and the
  # plane signs with the new one from now on.
  defp import_or_rotate(ciphertext, type, opts) do
    path = "/v1/#{Tokens.mount(opts)}/keys/#{name(opts)}"

    case Tokens.request(:get, path, nil, opts) do
      {:error, :not_found} ->
        Tokens.request(
          :post,
          path <> "/import",
          %{
            "ciphertext" => ciphertext,
            "type" => type,
            "hash_function" => "SHA256",
            "exportable" => false,
            "allow_plaintext_backup" => false
          },
          opts
        )

      {:ok, %{"data" => %{"type" => ^type}}} ->
        Tokens.request(:post, path <> "/import_version", %{"ciphertext" => ciphertext}, opts)

      {:ok, %{"data" => %{"type" => other}}} ->
        {:error, {:key_type, other, type}}

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
