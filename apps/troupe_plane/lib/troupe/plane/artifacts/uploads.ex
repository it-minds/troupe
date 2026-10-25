defmodule Troupe.Plane.Artifacts.Uploads do
  @moduledoc """
  An upload handle (#62): how a version reaches the limits a file and a version have (16 and
  64 MiB) when one call cannot carry it, since `/rpc` takes 4 MiB of body and base64 makes a
  file a third larger.

  `artifact.upload.begin` names the files and their sizes; the plane answers a URL for each,
  presigned for a PUT of that one key under `artifact-uploads/<handle>/` for fifteen
  minutes, and the client sends the bytes to the object store directly. A publish or a put
  then names the handle as `upload`: the plane reads each file back, holds it to the size it
  was announced at and to what a file sent inline is held to, writes the version, and
  deletes the handle's objects. A handle is its person's alone and is spent once; one left
  unspent is swept, objects and row, at the next `begin` after it expired.
  """

  import Ecto.Query

  alias Troupe.ObjectStore
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Repo
  alias Troupe.Protocol.Error

  @seconds 900

  @doc """
  A handle for `files` (`path`, `size`, `content_type`, checked already) for `user`, with a
  presigned PUT for each.
  """
  @spec begin(User.t(), [map()], term()) :: {:ok, map()} | {:error, Error.t()}
  def begin(%User{id: user_id}, files, %ObjectStore{} = store) when is_binary(user_id) do
    sweep(store)
    handle = "up-" <> (15 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))
    now = NaiveDateTime.utc_now()

    {1, _} =
      Repo.insert_all("artifact_uploads", [
        %{
          handle: handle,
          user_id: Ecto.UUID.dump!(user_id),
          files: files,
          expires_at: NaiveDateTime.add(now, @seconds),
          inserted_at: now
        }
      ])

    urls =
      Enum.map(files, fn file ->
        %{
          "path" => file["path"],
          "url" => ObjectStore.presign(store, :put, key(handle, file["path"]), ttl: @seconds)
        }
      end)

    {:ok, %{"upload" => handle, "expires_in" => @seconds, "urls" => urls}}
  end

  def begin(%User{}, _files, %ObjectStore{}),
    do: {:error, Error.new(:forbidden, %{reason: "not a person of this plane"})}

  def begin(_user, _files, _store),
    do: {:error, Error.new(:unavailable, %{reason: "this plane's object store signs no uploads"})}

  @doc """
  The files under `handle`, read back for `user` and each made a version's file by `check`
  (path, body, content type), or why not: `not_found` for a handle that is not theirs, is
  spent or expired; `invalid_params` for a file missing or not the size announced.
  """
  @spec take(String.t(), User.t(), term(), (String.t(), binary(), String.t() -> {:ok, map()} | {:error, Error.t()})) ::
          {:ok, [map()]} | {:error, Error.t()}
  def take(handle, %User{id: user_id}, store, check) when is_binary(user_id) do
    now = NaiveDateTime.utc_now()

    from(u in "artifact_uploads",
      where: u.handle == ^handle and u.user_id == type(^user_id, :binary_id) and u.expires_at > ^now,
      select: u.files
    )
    |> Repo.one()
    |> case do
      nil -> {:error, Error.new(:not_found, %{upload: handle, reason: "no such upload, or it was spent or expired"})}
      files -> read_back(handle, files, store, check)
    end
  end

  def take(handle, _user, _store, _check), do: {:error, Error.new(:not_found, %{upload: handle})}

  defp read_back(handle, files, store, check) do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      path = file["path"]

      with {:ok, body} <- fetched(store, handle, path),
           :ok <- announced(path, body, file["size"]),
           {:ok, entry} <- check.(path, body, file["content_type"]) do
        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.sort_by(files, & &1.path)}
      error -> error
    end
  end

  defp fetched(store, handle, path) do
    case ObjectStore.get(store, key(handle, path)) do
      {:ok, body} -> {:ok, body}
      {:error, :not_found} -> {:error, invalid("#{path} was not uploaded under #{handle}")}
      {:error, reason} -> {:error, Error.new(:unavailable, %{reason: "the object store refused #{path}: #{inspect(reason)}"})}
    end
  end

  defp announced(_path, body, size) when byte_size(body) == size, do: :ok

  defp announced(path, body, size),
    do: {:error, invalid("#{path} is #{byte_size(body)} bytes, not the #{size} its upload announced")}

  @doc "Spend `handle`: its row and every object under it."
  @spec finish(String.t(), term()) :: :ok
  def finish(handle, store) do
    Repo.delete_all(from(u in "artifact_uploads", where: u.handle == ^handle))
    drop(store, handle)
  end

  # Handles left unspent past their time, objects and rows.
  defp sweep(store) do
    now = NaiveDateTime.utc_now()

    from(u in "artifact_uploads", where: u.expires_at <= ^now, select: u.handle)
    |> Repo.all()
    |> Enum.each(&finish(&1, store))
  end

  defp drop(%ObjectStore{} = store, handle) do
    _ = ObjectStore.delete_prefix(store, "artifact-uploads/#{handle}/")
    :ok
  end

  defp drop(_store, _handle), do: :ok

  defp key(handle, path), do: "artifact-uploads/#{handle}/#{path}"

  defp invalid(reason), do: Error.new(:invalid_params, %{reason: reason})
end
