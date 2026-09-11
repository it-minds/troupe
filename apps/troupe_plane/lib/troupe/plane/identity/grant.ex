defmodule Troupe.Plane.Identity.Grant do
  @moduledoc """
  A team may use a profile.

  This is the whole of authorisation for creating sessions: a user's profiles are the
  profiles granted to the teams they are in, and a user in no enabled team has none.

  The operator never reads this. The plane projects it into
  `WorkerProfile.spec.teams`, which is how the volumes get mounted, and that projection
  is the only place the two meet.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "grants" do
    belongs_to :team, Troupe.Plane.Identity.Team
    field :profile, :string
    field :role, :string, default: "use"
    field :volume_mode, :string, default: "ro"
    field :granted_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:team_id, :profile, :role, :volume_mode, :granted_by])
    |> validate_required([:team_id, :profile])
    |> validate_inclusion(:role, ["use"])
    |> validate_inclusion(:volume_mode, ["ro", "rw"])
    |> unique_constraint([:team_id, :profile])
  end
end
