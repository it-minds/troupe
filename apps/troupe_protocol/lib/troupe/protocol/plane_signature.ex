defmodule Troupe.Protocol.PlaneSignature do
  @moduledoc """
  What a plane signs for its clients, and how a client checks it (#657).

  A plane holds an Ed25519 key of its own in OpenBao's transit engine, which cannot be
  exported, and signs with it what it tells people's machines to do: which versions it
  serves (`me.client_versions`) and the organisation's defaults and limits
  (`me.client_defaults`). It is not the release key: that one signs releases, and is
  compiled into every client; this one is the plane's word, and a client learns it from
  the plane at sign-in and pins it, as SSH pins a host key.

  ## The signed answer

  Each of those answers carries `signed`, beside the fields a client from before it reads:

      "signed": {
        "algorithm": "ed25519",
        "fingerprint": "SHA256:...",
        "document": "<canonical JSON, as signed>",
        "signature": "<base64 of the 64-byte signature>"
      }

  `document` is the text that was signed, not a map to encode again: a verifier checks the
  bytes it was sent and parses them afterwards, so no two encoders ever have to agree. It is
  canonical JSON (`Troupe.Protocol.Canonical`) of

      {"kind": "client_versions" | "client_defaults", "plane": URL or null,
       "signed_at": ISO 8601, "expires_at": ISO 8601, "body": the answer}

  and the signature is plain Ed25519 over it (RFC 8032), which is what transit's `ed25519`
  key makes of its input. `kind` is checked, so one answer cannot stand in for the other.

  ## The key

  The public half is 32 bytes, served at `/.well-known/troupe-signing-key` as base64, with
  its fingerprint: `SHA256:` and the unpadded base64 of its SHA-256, as `ssh-keygen -l`
  writes one.
  """

  alias Troupe.Protocol.Canonical

  @kinds ~w(client_versions client_defaults)
  @algorithm "ed25519"

  # A week: long enough for a laptop that is not signed in every day, short enough that an
  # answer copied out of a cache is not the plane's word for long.
  @lifetime_seconds 7 * 24 * 60 * 60

  @type kind :: String.t()
  @type key :: %{public_key: <<_::256>>, fingerprint: String.t()}
  @type reason ::
          :unsigned
          | :malformed
          | :forged
          | {:other_key, String.t()}
          | {:expired, String.t()}
          | {:wrong_kind, String.t()}

  @doc "What a plane signs: its version policy and its organisation's document."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The one signature algorithm."
  @spec algorithm() :: String.t()
  def algorithm, do: @algorithm

  @doc "How long a signed answer is the plane's word, in seconds."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc "A public key's fingerprint, `SHA256:<unpadded base64>`."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(public_key) when byte_size(public_key) == 32,
    do: "SHA256:" <> Base.encode64(:crypto.hash(:sha256, public_key), padding: false)

  @doc """
  A key as the plane serves it or a client pinned it: `algorithm` and `public_key` (base64),
  the fingerprint worked out again rather than believed.
  """
  @spec read_key(term()) :: {:ok, key()} | {:error, :malformed}
  def read_key(%{"algorithm" => @algorithm, "public_key" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::256>> = raw} -> {:ok, %{public_key: raw, fingerprint: fingerprint(raw)}}
      _other -> {:error, :malformed}
    end
  end

  def read_key(_other), do: {:error, :malformed}

  @doc "A key as it is written down: `algorithm`, `public_key` in base64 and `fingerprint`."
  @spec key_json(binary()) :: map()
  def key_json(public_key) do
    %{
      "algorithm" => @algorithm,
      "public_key" => Base.encode64(public_key),
      "fingerprint" => fingerprint(public_key)
    }
  end

  @doc """
  The document a plane signs: `kind`, `plane`, `signed_at`, `expires_at` and `body`, as the
  canonical text. `:now` (a `DateTime`) and `:plane` (its URL) are the plane's.
  """
  @spec document(kind(), map(), keyword()) :: String.t()
  def document(kind, body, opts \\ []) when kind in @kinds and is_map(body) do
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.truncate(:second)

    Canonical.encode(%{
      "kind" => kind,
      "plane" => opts[:plane],
      "signed_at" => DateTime.to_iso8601(now),
      "expires_at" => now |> DateTime.add(@lifetime_seconds, :second) |> DateTime.to_iso8601(),
      "body" => body
    })
  end

  @doc "The `signed` an answer carries, from the document, the signature and the key's fingerprint."
  @spec envelope(String.t(), binary(), String.t()) :: map()
  def envelope(document, signature, fingerprint) do
    %{
      "algorithm" => @algorithm,
      "fingerprint" => fingerprint,
      "document" => document,
      "signature" => Base.encode64(signature)
    }
  end

  @doc """
  Check an answer's `signed` against the key a client pinned for the plane, as `kind`.

  The body that was signed, with when it was signed and until when, where the signature
  holds, is the key's, names `kind` and has not expired (`:now`, a `DateTime`). Otherwise
  why not: `:unsigned` for no `signed` at all, `{:other_key, fingerprint}` for a signature
  by a key other than the one pinned, `:forged` for one that does not hold, `{:expired, at}`,
  `{:wrong_kind, kind}` and `:malformed`. `refusal/3` words each.
  """
  @spec verify(term(), key(), kind(), keyword()) ::
          {:ok, %{body: map(), signed_at: String.t(), expires_at: String.t()}}
          | {:error, reason()}
  def verify(signed, key, kind, opts \\ [])

  def verify(nil, _key, _kind, _opts), do: {:error, :unsigned}

  def verify(
        %{"algorithm" => @algorithm, "document" => document, "signature" => signature} = signed,
        %{public_key: public_key, fingerprint: pinned},
        kind,
        opts
      )
      when is_binary(document) and is_binary(signature) do
    with {:ok, raw} <- signature(signature),
         :ok <- holds(document, raw, public_key, signed["fingerprint"], pinned),
         {:ok, parsed} <- parsed(document),
         :ok <- kind_of(parsed, kind),
         :ok <- fresh(parsed["expires_at"], Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)) do
      {:ok,
       %{body: parsed["body"], signed_at: parsed["signed_at"], expires_at: parsed["expires_at"]}}
    end
  end

  def verify(_signed, _key, _kind, _opts), do: {:error, :malformed}

  defp signature(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::512>> = raw} -> {:ok, raw}
      _other -> {:error, :malformed}
    end
  end

  # The signature is checked against the pinned key whatever the answer says it is by. The
  # fingerprint it names is a label, read only where the signature does not hold: naming
  # another key, it says which, so a person is told the plane's key changed rather than
  # that its answer was forged.
  defp holds(document, signature, public_key, named, pinned) do
    cond do
      :crypto.verify(:eddsa, :none, document, signature, [public_key, :ed25519]) -> :ok
      is_binary(named) and named != pinned -> {:error, {:other_key, named}}
      true -> {:error, :forged}
    end
  end

  defp parsed(document) do
    case Jason.decode(document) do
      {:ok, %{"body" => body} = parsed} when is_map(body) -> {:ok, parsed}
      _other -> {:error, :malformed}
    end
  end

  defp kind_of(%{"kind" => kind}, kind), do: :ok

  defp kind_of(%{"kind" => other}, _kind) when is_binary(other),
    do: {:error, {:wrong_kind, other}}

  defp kind_of(_parsed, _kind), do: {:error, :malformed}

  defp fresh(expires_at, now) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, at, _offset} ->
        if DateTime.compare(now, at) == :lt, do: :ok, else: {:error, {:expired, expires_at}}

      _unread ->
        {:error, :malformed}
    end
  end

  defp fresh(_expires_at, _now), do: {:error, :malformed}

  @doc """
  What a refusal says, finishing "... is not taken": `what` is what was refused ("the
  version policy", "the organisation's document"), `plane` where from, and `:pinned` the
  fingerprint of the key the client holds for it.
  """
  @spec refusal(reason(), String.t(), keyword()) :: String.t()
  def refusal(reason, plane, opts \\ []) do
    what = Keyword.get(opts, :what, "the plane's answer")
    pinned = opts[:pinned]

    case reason do
      :unsigned ->
        "#{what} from #{plane} is not signed, and this machine holds the plane's signing key " <>
          "#{pinned}: it is not taken"

      {:other_key, fingerprint} ->
        "#{what} from #{plane} is signed by the key #{fingerprint}, not by #{pinned}, the key " <>
          "this machine pinned for that plane: it is not taken until you accept the new key"

      :forged ->
        "#{what} from #{plane} does not match its signature: it was changed after the plane " <>
          "signed it, and is not taken"

      {:expired, at} ->
        "#{what} from #{plane} was the plane's word until #{at}: it is not taken"

      {:wrong_kind, kind} ->
        "#{what} from #{plane} is signed as #{kind}, which is something else: it is not taken"

      :malformed ->
        "#{what} from #{plane} carries a signature this client cannot read: it is not taken"
    end
  end
end
