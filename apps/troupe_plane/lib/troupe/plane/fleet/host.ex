defmodule Troupe.Plane.Fleet.Host do
  @moduledoc """
  A machine registered to run a profile's workers, outside Kubernetes.

  A host that answers, rather than a host we built. The plane does not create these and
  cannot: somebody registers one, is given a secret once, and installs the worker on it
  however they install things. That is the whole contract, and it is what makes the
  single-developer case work — the laptop already exists.

  ## The secret does what a namespace does

  A pod proves which profile it is with a `TokenReview`: the namespace decides the profile,
  and a pod cannot mint a token from another namespace's ServiceAccount. A host has no
  namespace, so the equivalent is a secret issued to *this host, for this profile* — kept
  as a salted digest, the same shape a trigger key and a session share have, and for the
  same reason. A dump of this table is not a set of working credentials.

  The claim is exactly as strong as the pod's and no stronger, which is the honest way to
  put it: possession of a secret proves possession of a secret. What it is not is weaker in
  a way somebody could miss — a host presenting another host's secret is refused with the
  same refusal a pod from the wrong namespace gets, and the refusal does not say which
  check it failed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "worker_hosts" do
    field(:profile, :string)
    field(:name, :string)
    # Where a person would reach it. The plane never dials it — the worker dials the plane,
    # exactly as a pod does — so this is for somebody reading a listing and nothing else.
    field(:address, :string)
    # Its place in the profile, assigned at registration. Drain takes the highest first,
    # which needs a stable order and not a listing's.
    field(:ordinal, :integer)

    field(:secret_hash, :string)
    field(:secret_salt, :string)
    field(:secret_rotated_at, :utc_datetime_usec)
    field(:secret_rotated_by, :string)

    field(:registered_by, :string)
    field(:enabled, :boolean, default: true)
    field(:last_enrolled_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(host, attrs) do
    host
    |> cast(attrs, [
      :id,
      :profile,
      :name,
      :address,
      :ordinal,
      :secret_hash,
      :secret_salt,
      :secret_rotated_at,
      :secret_rotated_by,
      :registered_by,
      :enabled,
      :last_enrolled_at
    ])
    |> validate_required([
      :id,
      :profile,
      :name,
      :ordinal,
      :secret_hash,
      :secret_salt,
      :registered_by
    ])
    # The name is how a worker is addressed in a listing, an audit row and a drain, so two
    # hosts of one profile sharing one would be two answers to one question.
    |> unique_constraint([:profile, :name])
    |> unique_constraint([:profile, :ordinal])
    |> unique_constraint(:secret_hash)
    |> foreign_key_constraint(:profile)
  end

  @spec rotate_changeset(t(), map()) :: Ecto.Changeset.t()
  def rotate_changeset(host, attrs) do
    cast(host, attrs, [:secret_hash, :secret_salt, :secret_rotated_at, :secret_rotated_by])
  end

  @doc """
  Whether this host may enrol at all.

  Disabled is not deleted, deliberately. Somebody taking a build box out of service wants
  its sessions to drain and its name to stay in the listing; deleting the row would make
  the audit trail point at nothing.
  """
  @spec enrollable?(t()) :: boolean()
  def enrollable?(%__MODULE__{enabled: enabled}), do: enabled
end
