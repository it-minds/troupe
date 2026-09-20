defmodule Troupe.Session.Blobs do
  @moduledoc """
  Content-addressed storage for payloads too large to put on the wire.

  Any event field over 16 KiB becomes `{"blob": "sha256:…", "preview": …}` and the
  bytes live here, fetched with `blob.get` when a client actually wants them. That
  keeps a 40 MB test log out of every subscriber's socket while leaving it reachable.

  Blobs are deduplicated **within a session and never across sessions**. Sharing them
  would mean one session's content sitting under another session's key, which is
  exactly the property that makes per-session erasure meaningful.
  """

  alias Troupe.Paths

  @inline_limit 16 * 1024
  @preview_bytes 4 * 1024

  @doc "The size above which a payload is stored as a blob."
  @spec inline_limit() :: pos_integer()
  def inline_limit, do: @inline_limit

  @doc """
  Store `content` if it is too large to inline, returning what belongs in the event.

  Returns the content unchanged when it fits.
  """
  @spec maybe_store(String.t(), Path.t(), binary()) :: binary() | map()
  def maybe_store(session_id, workspace_root, content) when byte_size(content) <= @inline_limit do
    _ = {session_id, workspace_root}
    content
  end

  def maybe_store(session_id, workspace_root, content) do
    digest = digest(content)
    path = blob_path(session_id, workspace_root, digest)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    %{
      "blob" => digest,
      "size" => byte_size(content),
      "preview" => preview(content),
      "truncated" => true
    }
  end

  @doc "Store `content` whatever its size and return its digest: a kept tool output."
  @spec store(String.t(), Path.t(), binary()) :: String.t()
  def store(session_id, workspace_root, content) when is_binary(content) do
    digest = digest(content)
    path = blob_path(session_id, workspace_root, digest)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    digest
  end

  @doc """
  Turn a stored payload back into its bytes, or pass a plain one through.

  The inverse of `maybe_store/3`, for a replay that has to rebuild the conversation
  the model saw. A blob whose file has gone comes back as a note saying so rather than
  an error: a conversation with a missing tool result is recoverable, a crash during
  replay is not.
  """
  @spec resolve(String.t(), Path.t(), binary() | map()) :: binary()
  def resolve(_session_id, _workspace_root, content) when is_binary(content), do: content

  def resolve(session_id, workspace_root, %{"blob" => digest} = reference) do
    case read(session_id, workspace_root, digest) do
      {:ok, content, _size} -> content
      {:error, :not_found} -> Map.get(reference, "preview", "(the stored output is gone)")
    end
  end

  def resolve(_session_id, _workspace_root, other), do: to_string(other)

  @doc "Read a blob, optionally a byte range as `[first, last]` inclusive."
  @spec read(String.t(), Path.t(), String.t(), [integer()] | nil) ::
          {:ok, binary(), non_neg_integer()} | {:error, :not_found}
  def read(session_id, workspace_root, digest, range \\ nil) do
    path = blob_path(session_id, workspace_root, digest)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, slice(path, size, range), size}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp slice(path, _size, nil), do: File.read!(path)

  defp slice(path, size, [first, last]) do
    first = max(first, 0)
    last = min(last, size - 1)
    length = max(last - first + 1, 0)

    if length == 0 do
      ""
    else
      {:ok, file} = :file.open(path, [:read, :binary, :raw])
      {:ok, bytes} = :file.pread(file, first, length)
      :file.close(file)
      bytes
    end
  end

  defp slice(path, size, _range), do: slice(path, size, nil)

  @doc "The `sha256:` digest used as a blob's name."
  @spec digest(binary()) :: String.t()
  def digest(content) do
    "sha256:" <> (:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower))
  end

  defp preview(content) do
    content |> binary_part(0, min(byte_size(content), @preview_bytes)) |> scrub()
  end

  # A cut at an arbitrary byte can land mid-codepoint, and a client should never have
  # to deal with invalid UTF-8 from us.
  defp scrub(binary) do
    if String.valid?(binary), do: binary, else: scrub(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp blob_path(session_id, workspace_root, "sha256:" <> hex) do
    Path.join([Paths.session_dir(workspace_root, session_id), "blobs", hex])
  end

  defp blob_path(session_id, workspace_root, digest) do
    Path.join([Paths.session_dir(workspace_root, session_id), "blobs", digest])
  end
end
