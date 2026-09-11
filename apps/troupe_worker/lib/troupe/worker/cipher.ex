defmodule Troupe.Worker.Cipher do
  @moduledoc """
  AES-256-GCM with the session's data key.

  Everything a session puts in object storage goes through here except its manifest,
  which is plaintext ids and no content. Authenticated encryption rather than plain
  AES because the object store is not trusted to hand back what it was given: a
  segment that was altered in place has to fail to decrypt rather than decode into
  something plausible.

  Each object gets a fresh 96-bit nonce, stored in front of the ciphertext. Reusing one
  under the same key would leak the XOR of two plaintexts and break the authentication
  entirely, so it is generated per call and never derived from anything.

  The wire format is `"TRPE1" <> nonce <> tag <> ciphertext`, which makes a Troupe
  object identifiable without decrypting it and leaves room to change algorithms
  without guessing what an old object was.
  """

  @magic "TRPE1"
  @nonce_bytes 12
  @tag_bytes 16

  @type key :: <<_::256>>

  @doc """
  Encrypt, with the session id as associated data.

  The session id is authenticated but not encrypted: moving an object from one
  session's prefix to another then fails to decrypt, so a store that mixed up two
  sessions' objects cannot silently hand one the other's history.
  """
  @spec seal(key(), String.t(), binary()) :: binary()
  def seal(key, session_id, plaintext) when byte_size(key) == 32 do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, session_id, true)

    @magic <> nonce <> tag <> ciphertext
  end

  @doc "Decrypt, or say why not. A tampered object is `{:error, :invalid}` and never plaintext."
  @spec open(key(), String.t(), binary()) :: {:ok, binary()} | {:error, :invalid | :unknown_format}
  def open(key, session_id, <<@magic, nonce::binary-size(@nonce_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>)
      when byte_size(key) == 32 do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, session_id, tag, false) do
      :error -> {:error, :invalid}
      plaintext -> {:ok, plaintext}
    end
  end

  def open(_key, _session_id, _blob), do: {:error, :unknown_format}

  @doc "Whether a blob looks like something this module wrote."
  @spec ours?(binary()) :: boolean()
  def ours?(<<@magic, _rest::binary>>), do: true
  def ours?(_blob), do: false
end
