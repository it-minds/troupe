defmodule Troupe.A2A.Artifacts do
  @moduledoc """
  `GET /a2a/tasks/<id>/artifacts/<hash>`: the bytes behind a `file` part.

  An artifact exists because an event says so — a `published` event for a file the
  agent put on a shared volume, a blob reference for a tool result or a response too
  large for the log — and the hash in the event is its id. Serving one means finding
  that event again, fetching the bytes through the session's own access checks with
  the caller's own token, and checking them against the hash before a single byte goes
  out. A mismatch is a `502`: the facade will not vouch for bytes that are not the ones
  the log recorded.
  """

  alias Troupe.A2A.{Error, Events, HTTP, Plane, Stream, Tasks, Worker}
  alias Troupe.Protocol.Error, as: PlaneError

  @spec serve(Plug.Conn.t(), Plane.caller(), String.t(), String.t()) :: Plug.Conn.t()
  def serve(conn, caller, task_id, hash) do
    hex = Events.hex_of(hash)

    with {:ok, _row} <- Tasks.fetch_task(caller, task_id),
         {:ok, acc} <- replay(caller, task_id),
         {:ok, artifact} <- find(acc, hex, task_id),
         {:ok, bytes} <- fetch(caller, task_id, artifact, hex) do
      if digest(bytes) == hex do
        conn
        |> Plug.Conn.put_resp_content_type(mime_of(artifact), nil)
        |> Plug.Conn.put_resp_header("etag", ~s("sha256-#{hex}"))
        |> Plug.Conn.put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> Plug.Conn.send_resp(200, bytes)
      else
        HTTP.json(conn, 502, %{
          "error" => "hash mismatch",
          "reason" => "the bytes read from the session do not match the artifact's hash",
          "artifactId" => hex
        })
      end
    else
      {:error, %{"code" => -32_001} = error} -> HTTP.json(conn, 404, error)
      {:error, %{"code" => _code} = error} -> HTTP.json(conn, 502, error)
    end
  end

  defp replay(caller, task_id) do
    case Stream.replay(caller, task_id) do
      {:ok, acc} -> {:ok, acc}
      {:error, %PlaneError{} = error} -> {:error, Error.from_plane(error, task_id)}
    end
  end

  defp find(acc, hex, task_id) do
    case Map.get(acc.artifacts, hex) do
      nil -> {:error, Error.task_not_found(task_id)}
      artifact -> {:ok, artifact}
    end
  end

  # Through a reader, so a dormant session stays dormant.
  defp fetch(caller, task_id, artifact, hex) do
    result =
      Worker.with_session(caller, task_id, "read", fn client, _grant ->
        read(client, task_id, artifact, hex)
      end)

    case result do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:ok, _other} -> {:error, Error.internal("the pod returned no content")}
      {:error, %PlaneError{} = error} -> {:error, Error.from_plane(error, task_id)}
    end
  end

  # A published file is read back from the destination the event named, on the
  # session's mounts; a blob is read by its digest.
  defp read(client, task_id, artifact, hex) do
    case artifact["metadata"] do
      %{"source" => _source} ->
        with {:ok, %{"content" => content}} <-
               Worker.read_file(client, task_id, artifact["name"]) do
          {:ok, content}
        end

      _blob ->
        Worker.read_blob(client, task_id, "sha256:" <> hex)
    end
  end

  defp mime_of(%{"parts" => [%{"file" => %{"mimeType" => mime}} | _rest]}), do: mime
  defp mime_of(_artifact), do: "application/octet-stream"

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
