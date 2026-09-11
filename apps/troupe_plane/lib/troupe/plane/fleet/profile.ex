defmodule Troupe.Plane.Fleet.Profile do
  @moduledoc """
  What the plane remembers about a `WorkerProfile` it wrote.

  A cache of desired state so placement can answer "how many sessions fit" without
  asking Kubernetes on every create. The custom resource is the source of truth and the
  operator reads only that; this row is written whenever the plane writes the resource.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :name}

  schema "profiles" do
    field :replicas, :integer, default: 1
    field :sessions_per_pod, :integer, default: 4
    field :config_bundle_channel, :string, default: "stable"
    field :image, :string
    field :workers_domain, :string
    field :spec, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :replicas, :sessions_per_pod, :config_bundle_channel, :image, :workers_domain, :spec])
    |> validate_required([:name])
    |> validate_number(:sessions_per_pod, greater_than: 0)
  end
end
