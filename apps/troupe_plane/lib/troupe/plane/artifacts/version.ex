defmodule Troupe.Plane.Artifacts.Version do
  @moduledoc """
  One version of one artifact, never updated: its files, each with its path, SHA-256,
  content type and size, the hash over all of them, who published it when and what they
  said of it. A file's bytes are in the object store under `artifacts/<id>/<n>/<path>`, or,
  for one a later version carried unchanged from an earlier (an edit of another file, a
  rollback), under the earlier version's `n`, which the file names as `stored_in`.
  """

  use Ecto.Schema

  @primary_key false

  schema "artifact_versions" do
    field(:artifact_id, :string, primary_key: true)
    field(:n, :integer, primary_key: true)
    field(:hash, :string)
    field(:bytes, :integer)
    field(:files, {:array, :map}, default: [])
    field(:published_by, :string)
    field(:published_at, :utc_datetime_usec)
    field(:note, :string)
    # The version a rollback republished, or nil.
    field(:rolled_back_to, :integer)
  end

  @type t :: %__MODULE__{}
end
