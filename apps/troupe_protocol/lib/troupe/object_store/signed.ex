defmodule Troupe.ObjectStore.Signed do
  @moduledoc """
  Object storage for a caller who has no object-storage credential.

  A laptop sealing a private session cannot hold one — that is the whole point of the
  arrangement — so it asks the plane to sign a URL for each key it is about to touch and
  then talks to the store directly. The bytes never pass through the plane, and the plane
  has no key for them.

  This is a `Troupe.ObjectStore` in the only sense `Troupe.Sessions.Storage` needs: it is
  the first argument to `put`, `get`, `head` and `list`, and `ObjectStore` dispatches on
  it. Storage does not know which of the two it has, which is what lets one `Sealer` serve
  a pod with a service account and a daemon with neither.

  Two of the five verbs are not here.

  **Listing** cannot be signed per-key, because the caller does not yet know the keys; the
  plane lists on its behalf, which it can do without reading anything — a key is not
  content. That is the `list` function this struct is built with.

  **Deleting** is not here at all. Erasure has to remove *every version* of every object,
  which is a bucket-level operation and a decision with an owner; it stays on
  `session.erase`, where the plane does it with the credential and the audit row that
  belongs to it.

  One thing is quietly different, and it is written down rather than discovered.
  `:metadata` is dropped. S3 refuses a request carrying an `x-amz-*` header the signature
  does not cover, and a query-string signature covers `host` alone — so a presigned PUT
  cannot set object metadata at all. What that metadata is *for* is letting the plane
  rebuild its index from storage without a key; for a private session those same three
  facts reach it twice over, in the plaintext manifest and in every `session.register`,
  and the epoch and sequence numbers are in the segment key besides.
  """

  @enforce_keys [:session_id, :presign, :list]
  defstruct [:session_id, :presign, :list]

  @type method :: :get | :put | :head

  @typedoc """
  `presign` answers one URL per key for one method; `list` answers the keys under a
  prefix. Both are functions rather than a module, because what backs them is a plane
  connection the daemon already holds and this module should not learn to open.
  """
  @type t :: %__MODULE__{
          session_id: String.t(),
          presign: (method(), [String.t()] -> {:ok, %{String.t() => String.t()}} | {:error, term()}),
          list: (String.t() -> {:ok, [String.t()]} | {:error, term()})
        }

  @doc """
  Write an object through a signed PUT.

  `:metadata` is accepted and dropped — see the note above. Accepted so that one
  `Storage` serves both transports; dropped because S3 would refuse the request.
  """
  @spec put(t(), String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(%__MODULE__{} = signed, key, body, opts \\ []) do
    headers = [{"content-type", Keyword.get(opts, :content_type, "application/octet-stream")}]

    with {:ok, url} <- sign(signed, :put, key) do
      case Req.put(url, body: body, headers: headers, decode_body: false, retry: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, %{key: key, version_id: nil, bytes: byte_size(body)}}

        {:ok, response} ->
          {:error, {:unexpected_status, response.status, response.body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Read an object through a signed GET."
  @spec get(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, :not_found | term()}
  def get(%__MODULE__{} = signed, key, _opts \\ []) do
    with {:ok, url} <- sign(signed, :get, key) do
      case Req.get(url, decode_body: false, retry: false) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, response} -> {:error, {:unexpected_status, response.status, response.body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  An object's size, and whatever metadata it has.

  A private session's objects have none, for the reason above; this still answers the
  size, and answers the metadata of anything a pod wrote, so the same `Storage` code
  reads both.
  """
  @spec head(t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def head(%__MODULE__{} = signed, key) do
    with {:ok, url} <- sign(signed, :head, key) do
      case Req.head(url, decode_body: false, retry: false) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, %{key: key, bytes: content_length(response), metadata: metadata_of(response)}}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, response} ->
          {:error, {:unexpected_status, response.status, response.body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Whether an object exists, without fetching it."
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = signed, key), do: match?({:ok, _}, head(signed, key))

  @doc "Every key under a prefix, listed by the plane because the caller cannot."
  @spec list(t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(%__MODULE__{list: list}, prefix), do: list.(prefix)

  defp sign(%__MODULE__{presign: presign}, method, key) do
    case presign.(method, [key]) do
      {:ok, %{^key => url}} -> {:ok, url}
      {:ok, _other} -> {:error, {:unsigned, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [value | _] -> String.to_integer(value)
      _ -> 0
    end
  end

  defp metadata_of(response) do
    response.headers
    |> Enum.flat_map(fn
      {"x-amz-meta-" <> name, [value | _]} -> [{name, value}]
      {"x-amz-meta-" <> name, value} when is_binary(value) -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end
end
