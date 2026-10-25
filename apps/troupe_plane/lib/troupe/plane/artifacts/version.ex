defmodule Troupe.Plane.Artifacts.Version do
  @moduledoc """
  One version of one artifact, never updated: its files, each with its path, SHA-256,
  content type and size, the hash over all of them, and who published it when. The bytes
  are in the object store under `artifacts/<id>/<n>/<path>`.
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
  end

  @type t :: %__MODULE__{}
end
