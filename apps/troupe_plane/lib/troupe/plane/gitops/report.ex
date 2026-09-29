defmodule Troupe.Plane.Gitops.Report do
  @moduledoc """
  One thing the last GitOps pass could not use or could not find (Decision 736).

  `problem` is one of:

    * `refused` — a resource that fails the plane's own checks, at `generation`. Not used:
      a new one has no row, and a changed one leaves its row as the last version that
      passed.
    * `missing` — a row the cluster has no resource for, which the plane had before it
      read the cluster and keeps until somebody commits its manifest or deletes it.
    * `plane_only` — a resource in use that only the plane has ever written, so nothing
      applies it from a repository yet and the plane writes none of its fields.

  `reasons` are sentences, because a person reads them on the console and a model reads
  them in `admin.profiles.list`, and neither can act on a tuple.
  """

  use Ecto.Schema

  @primary_key false

  schema "gitops_reports" do
    field(:kind, :string, primary_key: true)
    field(:name, :string, primary_key: true)
    field(:problem, :string)
    field(:generation, :integer)
    field(:reasons, {:array, :string}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
