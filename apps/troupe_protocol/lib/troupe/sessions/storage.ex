defmodule Troupe.Sessions.Storage do
  @moduledoc """
  A session in object storage: the layout, and what may be read without a key.

      sessions/<session_id>/
        manifest.json                            plaintext ids only
        segments/<epoch>-<first>-<last>.seg      sealed log, zstd JSONL, encrypted
        snapshots/<seq>.snap                     fold snapshots, encrypted
        workspace/<seq>.tar                      workspace archives, encrypted
        blobs/<sha256>                           tool results and uploads, encrypted

  Two things about the layout are load-bearing.

  **The epoch is in the segment key.** Epochs are minted by the plane alone, and a pod
  that was presumed lost comes back holding the old one — so its segments land under a
  key nobody reads rather than in the middle of a session that has moved on. The plane
  refuses its seal reports for the same reason; this is what makes the refusal safe
  rather than merely tidy.

  **The manifest is plaintext and everything else is not.** A rebuild has to be able to
  enumerate sessions from storage alone, without a key it is not allowed to have, which
  is what `troupe admin index rebuild` does. So the manifest carries ids and sizes and
  nothing that was said.
  """

  alias Troupe.ObjectStore
  alias Troupe.Sessions.Cipher

  @type key :: binary()

  defmodule Segment do
    @moduledoc "One sealed run of durable events."

    @enforce_keys [:epoch, :first_seq, :last_seq]
    defstruct [:epoch, :first_seq, :last_seq, :key, :bytes, :head_hash]

    @type t :: %__MODULE__{}
  end

  @doc "The prefix everything about one session lives under."
  @spec prefix(String.t()) :: String.t()
  def prefix(session_id), do: "sessions/#{session_id}/"

  @doc "Where a sealed segment goes. The epoch is first, so a listing sorts by it."
  @spec segment_key(String.t(), pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def segment_key(session_id, epoch, first_seq, last_seq) do
    "#{prefix(session_id)}segments/#{pad(epoch)}-#{pad(first_seq)}-#{pad(last_seq)}.seg"
  end

  @doc "Where a fold snapshot goes."
  @spec snapshot_key(String.t(), non_neg_integer()) :: String.t()
  def snapshot_key(session_id, seq), do: "#{prefix(session_id)}snapshots/#{pad(seq)}.snap"

  @doc "Where a workspace archive goes."
  @spec workspace_key(String.t(), non_neg_integer(), String.t()) :: String.t()
  def workspace_key(session_id, seq, extension \\ "tar") do
    "#{prefix(session_id)}workspace/#{pad(seq)}.#{extension}"
  end

  @doc "Where a blob goes. Content-addressed, and within one session only."
  @spec blob_key(String.t(), String.t()) :: String.t()
  def blob_key(session_id, digest) do
    "#{prefix(session_id)}blobs/#{String.replace_prefix(digest, "sha256:", "")}"
  end

  @doc "Where the manifest goes."
  @spec manifest_key(String.t()) :: String.t()
  def manifest_key(session_id), do: "#{prefix(session_id)}manifest.json"

  # Zero-padded so a plain lexicographic listing is in order. Object stores sort by
  # byte, and `10` before `9` is how a replay ends up reading the tail first.
  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(12, "0")

  # -- segments ---------------------------------------------------------------

  @doc """
  Seal a run of events: encode, compress, encrypt, and upload.

  zstd over JSONL because a session log is highly repetitive — the same agent paths,
  the same event types, the same tool names — and the ratio is what keeps the object
  tier affordable.
  """
  @spec seal_segment(ObjectStore.t(), String.t(), key(), map()) ::
          {:ok, Segment.t()} | {:error, term()}
  def seal_segment(store, session_id, data_key, %{events: events, epoch: epoch} = attrs) do
    first = attrs[:first_seq] || events |> List.first() |> seq_of()
    last = attrs[:last_seq] || events |> List.last() |> seq_of()
    key = segment_key(session_id, epoch, first, last)

    body =
      events
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> :ezstd.compress()
      |> then(&Cipher.seal(data_key, session_id, &1))

    # Plaintext metadata, and deliberately: a rebuild reads the epoch, the last sequence
    # number and the head hash without a key it is not allowed to have. None of the three
    # is content.
    metadata = %{"epoch" => epoch, "last-seq" => last, "head-hash" => attrs[:head_hash] || ""}

    case ObjectStore.put(store, key, body, metadata: metadata) do
      {:ok, result} ->
        {:ok,
         %Segment{
           epoch: epoch,
           first_seq: first,
           last_seq: last,
           key: key,
           bytes: result.bytes,
           head_hash: attrs[:head_hash]
         }}

      error ->
        error
    end
  end

  defp seq_of(%{"seq" => seq}), do: seq
  defp seq_of(%{seq: seq}), do: seq
  defp seq_of(_event), do: 0

  @doc """
  What a sealed segment says about itself, without opening it.

  Epoch, last sequence number and head hash from the object's own metadata. This is the
  whole of how the plane rebuilds an index from storage it cannot decrypt.
  """
  @spec segment_head(ObjectStore.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def segment_head(store, key) do
    with {:ok, %{metadata: metadata, bytes: bytes}} <- ObjectStore.head(store, key) do
      {:ok,
       %{
         key: key,
         bytes: bytes,
         epoch: to_integer(metadata["epoch"]),
         last_seq: to_integer(metadata["last-seq"]),
         head_hash: presence(metadata["head-hash"])
       }}
    end
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) do
    case Integer.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  @doc "Read a sealed segment back into the events it holds."
  @spec read_segment(ObjectStore.t(), String.t(), key(), String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def read_segment(store, session_id, data_key, key) do
    with {:ok, sealed} <- ObjectStore.get(store, key),
         {:ok, compressed} <- Cipher.open(data_key, session_id, sealed) do
      {:ok, decode_lines(:ezstd.decompress(compressed))}
    end
  end

  defp decode_lines(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Every segment a session has, oldest first, highest epoch winning.

  A session that moved between pods has segments from more than one epoch, and the ones
  from an epoch it has moved past are not part of its history — a pod presumed lost may
  have written them after the fact. Following the highest epoch's contiguous chain is
  what a rebuild does, and this is where that order comes from.
  """
  @spec list_segments(ObjectStore.t(), String.t()) :: {:ok, [Segment.t()]} | {:error, term()}
  def list_segments(store, session_id) do
    with {:ok, keys} <- ObjectStore.list(store, prefix(session_id) <> "segments/") do
      {:ok, keys |> Enum.map(&parse_segment_key/1) |> Enum.reject(&is_nil/1) |> Enum.sort_by(&{&1.epoch, &1.first_seq})}
    end
  end

  defp parse_segment_key(key) do
    with [name] <- [Path.basename(key, ".seg")],
         [epoch, first, last] <- String.split(name, "-"),
         {epoch, ""} <- Integer.parse(epoch),
         {first, ""} <- Integer.parse(first),
         {last, ""} <- Integer.parse(last) do
      %Segment{epoch: epoch, first_seq: first, last_seq: last, key: key}
    else
      _ -> nil
    end
  end

  @doc """
  The segments that make up a session's history, discarding stale epochs.

  The highest epoch with a contiguous chain from `seq` 1 wins. A segment from an older
  epoch that overlaps it is history a pod wrote after the session had moved on, and it
  is skipped rather than merged.
  """
  @spec live_segments([Segment.t()]) :: [Segment.t()]
  def live_segments([]), do: []

  def live_segments(segments) do
    segments
    |> Enum.sort_by(&{&1.first_seq, -&1.epoch})
    |> Enum.reduce({[], 0}, fn segment, {kept, reached} ->
      # Each segment must carry on from where the last one ended. An older epoch's
      # segment covering ground already covered is dropped.
      if segment.first_seq == reached + 1 do
        {[segment | kept], segment.last_seq}
      else
        {kept, reached}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # -- snapshots, workspaces and blobs ----------------------------------------

  @doc "Write a fold snapshot. Pure cache: a mismatch on read forces a full replay."
  @spec put_snapshot(ObjectStore.t(), String.t(), key(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def put_snapshot(store, session_id, data_key, seq, snapshot) do
    body = snapshot |> Jason.encode!() |> :ezstd.compress() |> then(&Cipher.seal(data_key, session_id, &1))
    ObjectStore.put(store, snapshot_key(session_id, seq), body)
  end

  @doc "Read a snapshot back, or say it cannot be used."
  @spec get_snapshot(ObjectStore.t(), String.t(), key(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def get_snapshot(store, session_id, data_key, seq) do
    with {:ok, sealed} <- ObjectStore.get(store, snapshot_key(session_id, seq)),
         {:ok, compressed} <- Cipher.open(data_key, session_id, sealed) do
      {:ok, compressed |> :ezstd.decompress() |> Jason.decode!()}
    end
  end

  @doc "The newest snapshot a session has, or `nil`."
  @spec latest_snapshot_seq(ObjectStore.t(), String.t()) :: non_neg_integer() | nil
  def latest_snapshot_seq(store, session_id) do
    case ObjectStore.list(store, prefix(session_id) <> "snapshots/") do
      {:ok, keys} ->
        keys
        |> Enum.map(&(&1 |> Path.basename(".snap") |> Integer.parse()))
        |> Enum.flat_map(fn
          {seq, ""} -> [seq]
          _ -> []
        end)
        |> Enum.max(fn -> nil end)

      _ ->
        nil
    end
  end

  @doc "Upload a workspace archive."
  @spec put_workspace(ObjectStore.t(), String.t(), key(), non_neg_integer(), binary(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def put_workspace(store, session_id, data_key, seq, archive, extension \\ "tar") do
    ObjectStore.put(store, workspace_key(session_id, seq, extension), Cipher.seal(data_key, session_id, archive))
  end

  @doc "Read a workspace archive back."
  @spec get_workspace(ObjectStore.t(), String.t(), key(), non_neg_integer(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def get_workspace(store, session_id, data_key, seq, extension \\ "tar") do
    with {:ok, sealed} <- ObjectStore.get(store, workspace_key(session_id, seq, extension)) do
      Cipher.open(data_key, session_id, sealed)
    end
  end

  @doc "Store a blob, content-addressed within this session and no other."
  @spec put_blob(ObjectStore.t(), String.t(), key(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put_blob(store, session_id, data_key, content) do
    digest = "sha256:" <> (:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower))

    case ObjectStore.put(store, blob_key(session_id, digest), Cipher.seal(data_key, session_id, content)) do
      {:ok, _} -> {:ok, digest}
      error -> error
    end
  end

  @doc "Read a blob."
  @spec get_blob(ObjectStore.t(), String.t(), key(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get_blob(store, session_id, data_key, digest) do
    with {:ok, sealed} <- ObjectStore.get(store, blob_key(session_id, digest)) do
      Cipher.open(data_key, session_id, sealed)
    end
  end

  # -- the manifest -----------------------------------------------------------

  @doc """
  Write the manifest: ids, sizes, and where the key is. Never content.

  Plaintext on purpose. A rebuild enumerates sessions from storage alone, without a key
  it is not allowed to have, and a manifest it could not read would make that
  impossible.
  """
  @spec put_manifest(ObjectStore.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_manifest(store, session_id, manifest) do
    body =
      manifest
      |> Map.take(~w(session_id team owner_subject profile epoch latest_segment key_path last_seq head_hash object_bytes)a)
      |> Map.put(:session_id, session_id)
      |> Map.put(:written_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!(pretty: true)

    ObjectStore.put(store, manifest_key(session_id), body, content_type: "application/json")
  end

  @doc "Read a manifest. No key needed, which is the point of it."
  @spec get_manifest(ObjectStore.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_manifest(store, session_id) do
    with {:ok, body} <- ObjectStore.get(store, manifest_key(session_id)) do
      {:ok, Jason.decode!(body)}
    end
  end

  @doc "Every session the store holds, from the manifests alone."
  @spec list_sessions(ObjectStore.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_sessions(store) do
    with {:ok, keys} <- ObjectStore.list(store, "sessions/") do
      {:ok,
       keys
       |> Enum.filter(&String.ends_with?(&1, "/manifest.json"))
       |> Enum.map(&(&1 |> String.replace_prefix("sessions/", "") |> String.replace_suffix("/manifest.json", "")))
       |> Enum.sort()}
    end
  end

  @doc """
  Remove everything a session has, every version.

  Half of erasure. The other half is destroying the key, and it is the half that makes
  this final: a copy of the ciphertext that survives in a backup is unreadable once the
  key is gone.
  """
  @spec erase(ObjectStore.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def erase(store, session_id), do: ObjectStore.delete_prefix(store, prefix(session_id))
end
