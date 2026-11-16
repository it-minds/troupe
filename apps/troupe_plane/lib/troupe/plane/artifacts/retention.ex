defmodule Troupe.Plane.Artifacts.Retention do
  @moduledoc """
  How long what was published is kept (#981), and the pass that removes what has run out.

  Two settings, the organisation's, both off (0) unless an administrator sets them:

    * `artifacts_keep_versions_days`: a version older than the newest is removed once it was
      published that many days ago, its files with it. The newest version, and the version an
      owner pinned, are never removed, so an artifact always has the one its address serves.
    * `artifacts_keep_unopened_days`: an artifact nobody has opened, republished or changed
      for that many days is removed whole, as a delete would remove it. The count runs from
      the later of `opened_at` (set by `touch/1` when somebody opens it) and `updated_at`, so
      opening it starts it again.

  `goes_at/2` and `version_goes_at/3` say when each would go, for `artifact.list` and
  `artifact.get`, so a gallery can say it before it happens. `sweep/1` removes what has run
  out, one artifact or one version at a time, each in a transaction that holds the artifact's
  row and reads it again, so an artifact opened or republished between the pass choosing it
  and removing it is not removed. Each removal is one audit row, `system:retention` as the
  actor, in the shape a takedown has with `by: retention`; never the content.

  A version's files are its own objects and those it carried from an earlier version
  (`stored_in`); a removed version's object goes only when no version left names it, so a
  later version carrying a file keeps that file. What the store refuses is left with the
  version or the artifact and tried again by the next pass.

  Nothing runs while both settings are off, and nothing while artifacts are off: an artifact
  nobody can open is not one nobody wants.
  """

  import Ecto.Query

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Artifacts, Audit, Repo, Settings}
  alias Troupe.Plane.Artifacts.{Artifact, Version}

  @actor "system:retention"
  # How many of each one pass takes: the rest are the next pass's, an hour later.
  @batch 200
  # An open moves `opened_at` at most this often, so a page reloaded all afternoon is one write.
  @touch_seconds 3600

  @typedoc "The two periods, in days, `nil` where one is off."
  @type periods :: %{versions: pos_integer() | nil, unopened: pos_integer() | nil}

  @doc "The periods in force, in days, `nil` for one that is off."
  @spec periods() :: periods()
  def periods do
    %{
      versions: days(Settings.get("artifacts_keep_versions_days")),
      unopened: days(Settings.get("artifacts_keep_unopened_days"))
    }
  end

  defp days(n) when is_integer(n) and n > 0, do: n
  defp days(_off), do: nil

  @doc "When the artifact goes for nobody opening it, or `nil` where that period is off."
  @spec goes_at(Artifact.t(), periods()) :: DateTime.t() | nil
  def goes_at(_artifact, %{unopened: nil}), do: nil

  def goes_at(%Artifact{} = artifact, %{unopened: days}),
    do: DateTime.add(last_used(artifact), days * 86_400, :second)

  @doc """
  When version `version` of the artifact goes for its age, or `nil`: for the newest, the
  pinned one, and every one while that period is off.
  """
  @spec version_goes_at(Artifact.t(), Version.t(), periods()) :: DateTime.t() | nil
  def version_goes_at(_artifact, _version, %{versions: nil}), do: nil

  def version_goes_at(%Artifact{version: newest, pinned: pinned}, %Version{n: n} = version, %{versions: days}) do
    if n == newest or n == pinned,
      do: nil,
      else: DateTime.add(version.published_at, days * 86_400, :second)
  end

  defp last_used(%Artifact{opened_at: nil, updated_at: updated}), do: updated

  defp last_used(%Artifact{opened_at: opened, updated_at: updated}),
    do: if(DateTime.compare(opened, updated) == :gt, do: opened, else: updated)

  @doc """
  Somebody opened the artifact: `opened_at` is now, unless it moved within the hour.
  """
  @spec touch(Artifact.t()) :: :ok
  def touch(%Artifact{id: id, opened_at: opened}) do
    now = DateTime.utc_now()

    if is_nil(opened) or DateTime.diff(now, opened) >= @touch_seconds do
      Repo.update_all(from(a in Artifact, where: a.id == ^id), set: [opened_at: now])
    end

    :ok
  end

  # -- the sweep --------------------------------------------------------------------

  @typedoc "What a pass did: how many of each went, and the ids the store would not let go."
  @type outcome :: %{artifacts: non_neg_integer(), versions: non_neg_integer(), failed: [String.t()]}

  @doc """
  Remove what the periods say has run out, as of `now`. Nothing at all while both are off or
  artifacts are off. Safe to run twice: what went is not found again.
  """
  @spec sweep(DateTime.t()) :: outcome()
  def sweep(now \\ DateTime.utc_now()) do
    periods = periods()

    if Artifacts.enabled?() and (periods.versions || periods.unopened) do
      {gone, failed_whole} = sweep_unopened(periods, now)
      {versions, failed_versions} = sweep_versions(periods, now)

      %{artifacts: gone, versions: versions, failed: Enum.uniq(failed_whole ++ failed_versions)}
    else
      %{artifacts: 0, versions: 0, failed: []}
    end
  end

  defp sweep_unopened(%{unopened: nil}, _now), do: {0, []}

  defp sweep_unopened(%{unopened: days} = periods, now) do
    cutoff = DateTime.add(now, -days * 86_400, :second)

    from(a in Artifact,
      where: fragment("GREATEST(?, ?)", a.opened_at, a.updated_at) < ^cutoff,
      order_by: a.updated_at,
      limit: @batch,
      select: a.id
    )
    |> Repo.all()
    |> Enum.reduce({0, []}, &tally(remove_artifact(&1, periods, now), &1, &2))
  end

  defp sweep_versions(%{versions: nil}, _now), do: {0, []}

  defp sweep_versions(%{versions: days} = periods, now) do
    cutoff = DateTime.add(now, -days * 86_400, :second)

    from(v in Version,
      join: a in Artifact,
      on: a.id == v.artifact_id,
      where: v.n != a.version and (is_nil(a.pinned) or v.n != a.pinned) and v.published_at < ^cutoff,
      order_by: [v.published_at, v.n],
      limit: @batch,
      select: {v.artifact_id, v.n}
    )
    |> Repo.all()
    |> Enum.reduce({0, []}, &version_step(&1, &2, periods, now))
  end

  # The store refused this artifact's older version already this pass: a newer one's objects
  # are no likelier to go, and its files may be the ones the older one named.
  defp version_step({id, n}, {gone, failed}, periods, now) do
    if id in failed,
      do: {gone, failed},
      else: tally(remove_version(id, n, periods, now), id, {gone, failed})
  end

  defp tally(:removed, _id, {gone, failed}), do: {gone + 1, failed}
  defp tally(:kept, _id, acc), do: acc
  defp tally(:refused, id, {gone, failed}), do: {gone, [id | failed]}

  # The whole artifact, if it has still run out with its row held.
  defp remove_artifact(id, periods, now) do
    Repo.transaction(fn ->
      with %Artifact{} = artifact <- locked(id),
           %DateTime{} = goes <- goes_at(artifact, periods),
           true <- DateTime.compare(goes, now) != :gt do
        remove_whole(artifact, periods)
      else
        _not_now -> :kept
      end
    end)
    |> outcome()
  end

  defp remove_whole(artifact, periods) do
    case ObjectStore.delete_prefix(Artifacts.object_store(), "artifacts/#{artifact.id}/") do
      {:ok, _deleted} -> drop_whole(artifact, periods)
      {:error, _reason} -> :refused
    end
  end

  defp drop_whole(artifact, periods) do
    Repo.delete!(artifact)

      {:ok, _event} =
        Audit.record(@actor, "artifact.delete", artifact.id, compact(%{
          "title" => artifact.title,
          "visibility" => artifact.visibility,
          "versions" => artifact.version,
          "by" => "retention",
          "days" => periods.unopened,
          "session" => artifact.origin["session_id"]
        }))

      :removed
  end

  # One version, if it has still run out with the artifact's row held: the objects no version
  # left names, then its row, then what the artifact counts against its team's quota.
  defp remove_version(id, n, periods, now) do
    Repo.transaction(fn ->
      with %Artifact{} = artifact <- locked(id),
           %Version{} = version <- Repo.get_by(Version, artifact_id: id, n: n),
           %DateTime{} = goes <- version_goes_at(artifact, version, periods),
           true <- DateTime.compare(goes, now) != :gt do
        remove_old(artifact, version, periods)
      else
        _not_now -> :kept
      end
    end)
    |> outcome()
  end

  defp remove_old(%Artifact{id: id} = artifact, %Version{n: n} = version, periods) do
    others = Repo.all(from(v in Version, where: v.artifact_id == ^id and v.n != ^n))
    kept = others |> Enum.flat_map(&objects/1) |> MapSet.new(fn {key, _bytes} -> key end)
    going = version |> objects() |> Enum.reject(fn {key, _bytes} -> MapSet.member?(kept, key) end)

    case delete_objects(id, going) do
      :ok -> drop_old(artifact, version, going, periods)
      {:error, _reason} -> :refused
    end
  end

  defp drop_old(%Artifact{id: id} = artifact, %Version{n: n} = version, going, periods) do
      Repo.delete!(version)
      freed = going |> Enum.map(fn {_key, bytes} -> bytes || 0 end) |> Enum.sum()

      # Not through a changeset, which would move `updated_at` and with it the count the
      # unopened period keeps.
      Repo.update_all(from(a in Artifact, where: a.id == ^id),
        set: [total_bytes: max(artifact.total_bytes - freed, 0)]
      )

      {:ok, _event} =
        Audit.record(@actor, "artifact.version.delete", id, compact(%{
          "title" => artifact.title,
          "visibility" => artifact.visibility,
          "version" => n,
          "newest" => artifact.version,
          "by" => "retention",
          "days" => periods.versions,
          "session" => artifact.origin["session_id"]
        }))

      :removed
  end

  defp outcome({:ok, result}), do: result
  defp outcome({:error, _rollback}), do: :refused

  # Held for the length of the transaction, as a republish holds it, so the two never cross.
  # `updated_at` is not moved by what this does to the row: removing an old version is not
  # somebody using the artifact.
  defp locked(id), do: Repo.one(from(a in Artifact, where: a.id == ^id, lock: "FOR UPDATE"))

  # Where each of a version's files is kept, with its size: under its own number, or under
  # the earlier version's it was carried from.
  defp objects(%Version{artifact_id: id, n: n, files: files}) do
    Enum.map(files, fn file ->
      {"artifacts/#{id}/#{file["stored_in"] || n}/#{file["path"]}", file["bytes"]}
    end)
  end

  # Every stored version of exactly these keys: the bucket keeps versions, and a plain delete
  # would leave the bytes under a marker.
  defp delete_objects(_id, []), do: :ok

  defp delete_objects(id, going) do
    keys = MapSet.new(going, fn {key, _bytes} -> key end)
    store = Artifacts.object_store()

    with {:ok, versions} <- ObjectStore.list_versions(store, "artifacts/#{id}/") do
      versions
      |> Enum.filter(&MapSet.member?(keys, &1.key))
      |> Enum.reduce_while(:ok, &delete_one(store, &1, &2))
    end
  end

  defp delete_one(store, object, :ok) do
    case ObjectStore.delete(store, object.key, version_id: object.version_id) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
