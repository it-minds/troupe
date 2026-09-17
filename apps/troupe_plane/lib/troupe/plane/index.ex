defmodule Troupe.Plane.Index do
  @moduledoc """
  Rebuilding the session index from object storage alone.

  This is the answer to "what if PostgreSQL is gone". Object storage is the durable
  tier, and every session's manifest is plaintext on purpose, so the index can be
  reconstructed without a key the plane is not allowed to have. A restore from a
  point-in-time backup followed by a rebuild loses no session: the backup supplies the
  identity and the grants, and storage supplies where every session actually got to.

  What a rebuild trusts, and what it does not:

  * **Segment keys and their object metadata are authoritative.** The epoch, the last
    sequence number and the head hash are in the key and in the `x-amz-meta-` headers,
    none of which is content, so all three are readable without decrypting anything.
  * **The manifest is a hint.** A pod that was presumed lost and came back can have
    overwritten it under a stale epoch. Where the two disagree, the highest epoch's
    *contiguous* chain of segments wins — which is the same rule a worker follows when
    it restores a session, and the reason a stale pod's events never enter the index.
  * **A tombstone beats both.** An erased session has no objects left and must not come
    back as a row because a stray one survived somewhere.
  """

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Erasure, Identity, Repo, Sessions}
  alias Troupe.Plane.Sessions.Anchor
  alias Troupe.Sessions.Storage

  require Logger

  @doc """
  Rebuild the index.

  Returns a report rather than raising, because a rebuild runs against storage that may
  have a session in it nobody can explain, and stopping at the first would leave the
  index half built.
  """
  @spec rebuild(keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild(opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &ObjectStore.from_env/0)

    case Storage.list_sessions(store) do
      {:ok, session_ids} ->
        report =
          session_ids
          |> Enum.map(&rebuild_one(store, &1, opts))
          |> Enum.frequencies_by(&elem(&1, 0))

        {:ok,
         %{
           found: length(session_ids),
           rebuilt: Map.get(report, :ok, 0),
           skipped: Map.get(report, :skipped, 0),
           failed: Map.get(report, :error, 0)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Rebuild one session's row, for a targeted repair."
  @spec rebuild_one(ObjectStore.t(), String.t(), keyword()) :: {atom(), String.t()}
  def rebuild_one(store, session_id, opts \\ []) do
    # A tombstone beats storage: an erased session must not come back as a row because a
    # stray object survived somewhere.
    if Erasure.tombstone_for(session_id) do
      {:skipped, session_id}
    else
      do_rebuild(store, session_id, opts)
    end
  rescue
    exception ->
      Logger.error(
        "troupe plane: could not rebuild #{session_id}: #{Exception.message(exception)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:error, session_id}
  end

  defp do_rebuild(store, session_id, opts) do
    manifest = manifest(store, session_id)
    chain = live_chain(store, session_id)

    with {:ok, attrs} <- attrs(session_id, manifest, chain, opts),
         {:ok, _session} <- upsert(session_id, attrs) do
      rebuild_anchors(session_id, chain)
      {:ok, session_id}
    else
      :skip ->
        {:skipped, session_id}

      # A manifest missing something the index needs — an owner, usually — is a session
      # this rebuild cannot place. Said out loud rather than counted as done, because a
      # rebuild that quietly dropped sessions would be worse than one that failed.
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("troupe plane: #{session_id} cannot be indexed: #{inspect(changeset.errors)}")
        {:error, session_id}

      {:error, reason} ->
        Logger.error("troupe plane: #{session_id} cannot be indexed: #{inspect(reason)}")
        {:error, session_id}
    end
  end

  defp manifest(store, session_id) do
    case Storage.get_manifest(store, session_id) do
      {:ok, manifest} -> manifest
      {:error, _reason} -> %{}
    end
  end

  # The highest epoch's contiguous chain, with each segment's own metadata. A segment an
  # older epoch wrote over ground already covered is not in it.
  defp live_chain(store, session_id) do
    case Storage.list_segments(store, session_id) do
      {:ok, segments} -> segments |> Storage.live_segments() |> Enum.map(&describe(store, &1))
      {:error, _reason} -> []
    end
  end

  defp describe(store, segment) do
    case Storage.segment_head(store, segment.key) do
      {:ok, head} -> Map.merge(Map.from_struct(segment), head)
      {:error, _reason} -> Map.from_struct(segment)
    end
  end

  defp attrs(_session_id, manifest, [], _opts) when map_size(manifest) == 0, do: :skip

  defp attrs(session_id, manifest, chain, opts) do
    # A manifest a stale pod overwrote can be missing things this one had. Where the
    # index still holds a row, its identity fields are kept: storage is authoritative
    # about where a session *got to*, not about whose it is.
    existing = session_id |> Sessions.get() |> existing_fields()
    {epoch, last_seq, head_hash} = position(manifest, List.last(chain))
    kind = manifest["kind"] || existing[:kind] || "team"

    {:ok,
     %{
       id: session_id,
       kind: kind,
       owner_subject: manifest["owner_subject"] || existing[:owner_subject],
       owner_id: owner_id(manifest["owner_subject"]) || existing[:owner_id],
       # Nothing is running after a rebuild, by definition: this index was just
       # reconstructed from storage and no pod has been told about any of it.
       state: "dormant",
       epoch: epoch,
       worker_id: nil,
       last_seq: last_seq,
       head_hash: head_hash,
       object_bytes: manifest["object_bytes"] || Enum.sum(Enum.map(chain, &(&1[:bytes] || 0))),
       last_active_at: written_at(manifest)
     }
     |> Map.merge(placement(kind, manifest, existing, opts))}
  end

  # A team session gets a profile — a real one, or the fallback, because a row with none
  # is a row no listing can place. A private session gets neither profile nor team, and
  # the fallback would be a lie the check constraint catches: storage says where a session
  # got to and has no opinion about where it runs.
  defp placement("private", _manifest, _existing, _opts), do: %{profile: nil, team_id: nil}

  defp placement(_team, manifest, existing, opts) do
    %{
      team_id: team_id(manifest["team"]) || existing[:team_id],
      profile:
        manifest["profile"] || existing[:profile] ||
          Keyword.get(opts, :default_profile, "unknown")
    }
  end

  # Segments win over the manifest: they are what a worker would replay, and the manifest
  # can have been written by a pod whose epoch had already been passed.
  defp position(manifest, nil) do
    {manifest["epoch"] || 1, manifest["last_seq"] || 0, manifest["head_hash"]}
  end

  defp position(manifest, last) do
    {last.epoch, last.last_seq, last[:head_hash] || manifest["head_hash"]}
  end

  defp upsert(session_id, attrs) do
    case Sessions.get(session_id) do
      nil -> Sessions.create(attrs)
      _existing -> Sessions.put_rebuilt(session_id, attrs)
    end
  end

  # Anchors are the plane's record of every sealed head, and a rebuild has to reproduce
  # them too: without them nothing could check object storage against the index later.
  defp rebuild_anchors(session_id, chain) do
    Enum.each(chain, fn segment ->
      %Anchor{}
      |> Anchor.changeset(%{
        session_id: session_id,
        epoch: segment.epoch,
        first_seq: segment.first_seq,
        last_seq: segment.last_seq,
        head_hash: segment[:head_hash],
        object_key: segment.key,
        bytes: segment[:bytes] || 0,
        sealed_at: DateTime.utc_now()
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:session_id, :epoch, :last_seq])
    end)
  end

  # `nil` for a session the index has never heard of, so every lookup below is a plain
  # `[]` access rather than a branch.
  defp existing_fields(nil), do: %{}
  defp existing_fields(session), do: Map.from_struct(session)

  defp owner_id(nil), do: nil

  defp owner_id(subject) do
    case Identity.get_user(subject) do
      nil -> nil
      user -> user.id
    end
  end

  defp team_id(nil), do: nil

  defp team_id(name) do
    case Identity.get_team(name) do
      nil -> nil
      team -> team.id
    end
  end

  defp written_at(manifest) do
    with value when is_binary(value) <- manifest["written_at"],
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _ -> DateTime.utc_now()
    end
  end
end
