defmodule Troupe.Release.Minisign do
  @moduledoc """
  minisign's three formats - a public key, a signature, and an unencrypted secret key -
  read and written with `:crypto` alone (#66, Decision 865).

  A release's `manifest.json` is signed with one Ed25519 key that only CI holds, and every
  client carries the public half (`Troupe.Release.Keys`). This is the one verifier the TUI
  and the daemon share, and the signer `scripts/release-manifest.exs` runs in CI. It needs
  nothing but `:crypto`, `Base` and `JSON`, so that script can load it from source without
  compiling the umbrella.

  The formats, as minisign writes them:

    * a public key is `"Ed" <> key_id(8) <> key(32)`, base64, after an untrusted comment;
    * a signature is four lines: an untrusted comment, base64 `"ED" <> key_id <> sig(64)`,
      `trusted comment: <text>`, and base64 of the global signature, which signs
      `sig <> text` so the trusted comment cannot be changed either. `"ED"` signs the
      BLAKE2b-512 of the file; the older `"Ed"` signs the file itself, and is read too;
    * an unencrypted secret key (`minisign -G -W`) is `"Ed" <> <<0, 0>> <> "B2"`, a salt and
      two limits nobody reads, then `key_id <> seed(32) <> public(32) <> checksum(32)`.

  **More than one signature.** A `.minisig` may hold several of those blocks, one after
  another, each by its own key: that is how a key rotation signs a release with the new key
  and the old one (Decision 865). The `minisign` command reads the first block only, so the
  first is always the current key's. Here every block by a trusted key must verify, at
  least one must be there, and a block by a key this build does not know is passed over.
  """

  @comment "untrusted comment: "
  @trusted "trusted comment: "

  @type public_key :: %{id: <<_::64>>, key: <<_::256>>}
  @type secret_key :: %{id: <<_::64>>, seed: <<_::256>>, public: <<_::256>>}
  @type block :: %{
          algorithm: :hashed | :legacy,
          id: <<_::64>>,
          signature: <<_::512>>,
          trusted_comment: String.t(),
          global: <<_::512>>
        }

  @doc """
  A public key from what minisign writes: the `.pub` file whole, or its base64 line
  (`RW...`) alone.
  """
  @spec parse_public_key(String.t()) :: {:ok, public_key()} | {:error, String.t()}
  def parse_public_key(text) when is_binary(text) do
    with {:ok, line} <- key_line(text, "public key"),
         {:ok, <<"Ed", id::binary-size(8), key::binary-size(32)>>} <- decode(line) do
      {:ok, %{id: id, key: key}}
    else
      {:error, _} = error ->
        error

      {:ok, _other} ->
        {:error, "is not a minisign public key: it does not decode to an Ed25519 key"}
    end
  end

  @doc """
  The keys in a list of them, as `apps/troupe_core/priv/release-keys.txt` holds them: a
  base64 line (`RW...`) each, `#` starting a comment, the first the current key.
  """
  @spec parse_key_list(String.t()) :: {:ok, [public_key()]} | {:error, String.t()}
  def parse_key_list(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, keys} ->
      case parse_public_key(line) do
        {:ok, key} -> {:cont, {:ok, keys ++ [key]}}
        {:error, why} -> {:halt, {:error, "#{line} #{why}"}}
      end
    end)
  end

  @doc "The base64 line minisign writes for a public key, `RW...`."
  @spec encode_public_key(public_key()) :: String.t()
  def encode_public_key(%{id: id, key: key}), do: Base.encode64("Ed" <> id <> key)

  @doc "A public key as minisign writes its `.pub` file."
  @spec public_key_file(public_key()) :: String.t()
  def public_key_file(public) do
    "#{@comment}minisign public key #{key_id(public)}\n#{encode_public_key(public)}\n"
  end

  @doc """
  A key's id as minisign prints it: the eight bytes, read as a little-endian number, in
  upper-case hexadecimal.
  """
  @spec key_id(%{id: <<_::64>>} | <<_::64>>) :: String.t()
  def key_id(%{id: id}), do: key_id(id)

  def key_id(<<n::little-unsigned-64>>),
    do: n |> Integer.to_string(16) |> String.pad_leading(16, "0")

  @doc "Every signature block in a `.minisig`, in order."
  @spec parse_signatures(String.t()) :: {:ok, [block()]} | {:error, String.t()}
  def parse_signatures(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == ""))

    cond do
      lines == [] ->
        {:error, "is empty"}

      rem(length(lines), 4) != 0 ->
        {:error, "is not a minisign signature: a signature is four lines"}

      true ->
        lines |> Enum.chunk_every(4) |> collect_blocks([])
    end
  end

  defp collect_blocks([], blocks), do: {:ok, Enum.reverse(blocks)}

  defp collect_blocks(
         [[@comment <> _, sig_line, @trusted <> comment, global_line] | rest],
         blocks
       ) do
    with {:ok, <<alg::binary-size(2), id::binary-size(8), signature::binary-size(64)>>} <-
           decode(sig_line),
         {:ok, algorithm} <- algorithm(alg),
         {:ok, <<global::binary-size(64)>>} <- decode(global_line) do
      block = %{
        algorithm: algorithm,
        id: id,
        signature: signature,
        trusted_comment: comment,
        global: global
      }

      collect_blocks(rest, [block | blocks])
    else
      {:error, _} = error -> error
      {:ok, _other} -> {:error, "is not a minisign signature: a line does not decode to one"}
    end
  end

  defp collect_blocks(_lines, _blocks),
    do:
      {:error,
       "is not a minisign signature: the lines are not an untrusted comment, a signature, a trusted comment and a signature"}

  defp algorithm("ED"), do: {:ok, :hashed}
  defp algorithm("Ed"), do: {:ok, :legacy}
  defp algorithm(_other), do: {:error, "is not a minisign signature: not an Ed25519 one"}

  @doc """
  Check `message` against a `.minisig`, with `keys` the keys this build trusts.

  The answer is the ids of the trusted keys that signed it and the first block's trusted
  comment; a refusal is a sentence to finish "the manifest ...".
  """
  @spec verify(binary(), String.t(), [public_key()]) ::
          {:ok, %{key_ids: [String.t()], trusted_comment: String.t()}} | {:error, String.t()}
  def verify(_message, _signature, []),
    do: {:error, "cannot be checked: this build trusts no release key, so it installs no release"}

  def verify(message, signature, keys) when is_binary(message) and is_binary(signature) do
    trusted = Map.new(keys, &{&1.id, &1.key})

    with {:ok, blocks} <- signatures(signature),
         {:ok, ours} <- ours(blocks, trusted),
         :ok <- each_verifies(ours, message, trusted) do
      {:ok, %{key_ids: Enum.map(ours, &key_id/1), trusted_comment: hd(ours).trusted_comment}}
    end
  end

  defp signatures(text) do
    case parse_signatures(text) do
      {:ok, blocks} -> {:ok, blocks}
      {:error, "is empty"} -> {:error, "has no signature: its .minisig is empty"}
      {:error, why} -> {:error, "has a signature file that #{why}"}
    end
  end

  defp ours(blocks, trusted) do
    case Enum.filter(blocks, &Map.has_key?(trusted, &1.id)) do
      [] ->
        signers = Enum.map_join(blocks, ", ", &key_id/1)
        ids = trusted |> Map.keys() |> Enum.map_join(", ", &key_id/1)

        {:error,
         "is signed by key #{signers}, which this build does not trust (it trusts #{ids})"}

      ours ->
        {:ok, ours}
    end
  end

  defp each_verifies(blocks, message, trusted) do
    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      key = Map.fetch!(trusted, block.id)

      cond do
        not ed25519?(signed(block.algorithm, message), block.signature, key) ->
          {:halt,
           {:error,
            "does not match its signature by key #{key_id(block)}: it was changed after it was signed"}}

        not ed25519?(block.signature <> block.trusted_comment, block.global, key) ->
          {:halt,
           {:error,
            "has a signature by key #{key_id(block)} whose trusted comment was changed after it was signed"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp signed(:hashed, message), do: :crypto.hash(:blake2b, message)
  defp signed(:legacy, message), do: message

  defp ed25519?(message, signature, key),
    do: :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519])

  @doc """
  One signature block over `message`, as `minisign -S` writes it: hashed (`"ED"`), with
  `:trusted_comment` signed and `:comment` not. `legacy: true` signs the message itself, as
  minisign's `-l` did, for the test vectors.
  """
  @spec sign(binary(), secret_key(), keyword()) :: String.t()
  def sign(message, %{id: id, seed: seed}, opts \\ []) do
    {alg, signed} =
      if opts[:legacy], do: {"Ed", message}, else: {"ED", :crypto.hash(:blake2b, message)}

    trusted =
      Keyword.get_lazy(opts, :trusted_comment, fn -> "timestamp:#{System.os_time(:second)}" end)

    comment = Keyword.get(opts, :comment, "signature from minisign secret key")
    signature = :crypto.sign(:eddsa, :none, signed, [seed, :ed25519])
    global = :crypto.sign(:eddsa, :none, signature <> trusted, [seed, :ed25519])

    Enum.join(
      [
        @comment <> comment,
        Base.encode64(alg <> id <> signature),
        @trusted <> trusted,
        Base.encode64(global)
      ],
      "\n"
    ) <> "\n"
  end

  @doc """
  An unencrypted minisign secret key (`minisign -G -W`), the file whole or its base64
  line. Its seed is checked against the public key stored beside it, so a key cut short
  or edited is refused; minisign's own checksum (BLAKE2b-256, which `:crypto` lacks) is
  not read. An encrypted key is refused with what to do instead.
  """
  @spec parse_secret_key(String.t()) :: {:ok, secret_key()} | {:error, String.t()}
  def parse_secret_key(text) when is_binary(text) do
    with {:ok, line} <- key_line(text, "secret key"),
         {:ok, bytes} <- decode(line) do
      secret(bytes)
    end
  end

  defp secret(
         <<"Ed", 0, 0, "B2", _salt::binary-size(32), _ops::binary-size(8), _mem::binary-size(8),
           id::binary-size(8), seed::binary-size(32), public::binary-size(32),
           _chk::binary-size(32)>>
       ) do
    if derive(seed) == public,
      do: {:ok, %{id: id, seed: seed, public: public}},
      else: {:error, "is not a whole minisign secret key: its seed does not give its public key"}
  end

  defp secret(<<"Ed", "Sc", _rest::binary>>) do
    {:error,
     "is encrypted with a password; the release key is kept unencrypted, as `minisign -G -W` " <>
       "writes it, in the release environment's secret"}
  end

  defp secret(_other), do: {:error, "is not a minisign secret key"}

  @doc "The public half of a secret key."
  @spec public_key(secret_key()) :: public_key()
  def public_key(%{id: id, public: public}), do: %{id: id, key: public}

  @doc """
  A secret key as `minisign -G -W` writes it, unencrypted, for a test's throwaway key. The
  checksum is left zero: minisign itself would not read this file, and nothing here does.
  """
  @spec encode_secret_key(secret_key()) :: String.t()
  def encode_secret_key(%{id: id, seed: seed, public: public}) do
    bytes =
      "Ed" <>
        <<0, 0>> <>
        "B2" <> <<0::256>> <> <<0::64>> <> <<0::64>> <> id <> seed <> public <> <<0::256>>

    "#{@comment}minisign secret key, unencrypted: a throwaway\n#{Base.encode64(bytes)}\n"
  end

  @doc "A throwaway key pair, for tests and the test vectors: never a release's key."
  @spec generate_keypair() :: {public_key(), secret_key()}
  def generate_keypair do
    {public, seed} = :crypto.generate_key(:eddsa, :ed25519)
    secret = %{id: :crypto.strong_rand_bytes(8), seed: seed, public: public}
    {public_key(secret), secret}
  end

  defp derive(seed) do
    {public, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    public
  end

  # The last line that is not a comment: a `.pub` or `.key` file has the comment first.
  defp key_line(text, what) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, @comment)))
    |> case do
      [line] -> {:ok, line}
      [] -> {:error, "is empty: no minisign #{what} in it"}
      _many -> {:error, "is not one minisign #{what}: it has more than one line"}
    end
  end

  defp decode(line) do
    case Base.decode64(line) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "is not minisign's: a line is not base64"}
    end
  end
end
