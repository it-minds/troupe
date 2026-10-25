defmodule Troupe.Plane.Artifacts.Previews do
  @moduledoc """
  An edit's preview (#62): the text a person is editing in the console, kept for an hour so
  the artifacts host can serve it at `/p/<nonce>/` over the version it was made on. The
  console frames that address, sandboxed, and never draws an artifact itself.

  The nonce is the address's only key: 24 random bytes, good for an hour, and the host reads
  again at every request whether its person may still put to the artifact. Rows older than
  that are swept at the next preview; nothing of a preview reaches the object store.
  """

  import Ecto.Query

  alias Troupe.Plane.Repo

  @seconds 3600

  @doc "How long a preview's address answers, in seconds."
  @spec seconds() :: pos_integer()
  def seconds, do: @seconds

  @doc "Keep `text` as `path` over version `base` of `artifact_id` for `subject`; the nonce."
  @spec put(String.t(), String.t(), pos_integer(), String.t(), String.t(), binary()) :: String.t()
  def put(artifact_id, subject, base, path, content_type, text) do
    now = NaiveDateTime.utc_now()
    Repo.delete_all(from(p in "artifact_previews", where: p.inserted_at < ^NaiveDateTime.add(now, -@seconds)))
    nonce = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    {1, _} =
      Repo.insert_all("artifact_previews", [
        %{
          nonce: nonce,
          artifact_id: artifact_id,
          subject: subject,
          base: base,
          path: path,
          content_type: content_type,
          body: text,
          inserted_at: now
        }
      ])

    nonce
  end

  @doc "A preview younger than an hour, or `:error`."
  @spec get(term()) :: {:ok, map()} | :error
  def get(nonce) when is_binary(nonce) and byte_size(nonce) <= 64 do
    since = NaiveDateTime.add(NaiveDateTime.utc_now(), -@seconds)

    from(p in "artifact_previews",
      where: p.nonce == ^nonce and p.inserted_at >= ^since,
      select: %{
        artifact_id: p.artifact_id,
        subject: p.subject,
        base: p.base,
        path: p.path,
        content_type: p.content_type,
        body: p.body
      }
    )
    |> Repo.one()
    |> case do
      nil -> :error
      preview -> {:ok, preview}
    end
  end

  def get(_nonce), do: :error
end
