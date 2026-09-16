defmodule Troupe.Plane.Fleet.Profile do
  @moduledoc """
  What the plane remembers about a `WorkerProfile` it wrote.

  A cache of desired state so placement can answer "how many sessions fit" without
  asking Kubernetes on every create. The custom resource is the source of truth and the
  operator reads only that; this row is written whenever the plane writes the resource.

  Three of these fields are an administrator's and the rest are derived. `size_class`
  says how demanding a session is here, `max_sessions` how far this may grow — in
  sessions at once, not workers — and `warm_workers` whether to keep one up when nothing
  is running. `replicas`, `sessions_per_pod` and the resource and storage numbers in
  `spec` follow from the class and from what is actually running, and the plane writes
  them the way it already writes `spec.teams`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Plane.Fleet.SizeClass

  @primary_key {:name, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :name}

  schema "profiles" do
    field :replicas, :integer, default: 1
    field :sessions_per_pod, :integer, default: 4

    # What an administrator actually answers.
    field :size_class, :string, default: "standard"
    # `nil` is no ceiling, bounded by the team's money. A ceiling is a decision somebody
    # makes, and a default would be a refusal nobody chose.
    field :max_sessions, :integer
    field :warm_workers, :integer, default: 0
    # When the last session here stopped being active, so scale-to-zero waits rather
    # than removing a worker the instant somebody's session goes dormant.
    field :idle_since, :utc_datetime_usec
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
    |> cast(attrs, [
      :name,
      :replicas,
      :sessions_per_pod,
      :size_class,
      :max_sessions,
      :warm_workers,
      :idle_since,
      :config_bundle_channel,
      :image,
      :workers_domain,
      :spec
    ])
    |> validate_required([:name])
    |> validate_number(:sessions_per_pod, greater_than: 0)
    |> validate_inclusion(:size_class, SizeClass.names())
    |> validate_number(:max_sessions, greater_than: 0)
    |> validate_number(:warm_workers, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> derive_from_class()
  end

  # The class is the answer, so the fields it decides are written from it rather than
  # taken from the caller. A profile whose `sessionsPerPod` disagreed with its class
  # would be a profile with two opinions about the same number, and the one an
  # administrator could see would be the wrong one.
  defp derive_from_class(changeset) do
    class = get_field(changeset, :size_class)

    if SizeClass.valid?(class) do
      put_change(changeset, :sessions_per_pod, SizeClass.sessions_per_pod(class))
    else
      changeset
    end
  end
end
