defmodule Troupe.Plane.Ledger.Reservation do
  @moduledoc """
  A promise a running session has made against its team's budget.

  Held while the session runs, released when it goes dormant or is erased. Never part
  of what has been *spent*: reservations are how the plane avoids promising the same
  money twice, and usage records are what the money actually went on.

  Against a team's budget and against a person's. `owner_subject` is who the promise is
  attributed to, which for a session a trigger started is the principal's **sponsor** —
  the person answerable for the run, not the credential that made it. A reservation that
  named only its team could be summed for the team and for nobody in it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "budget_reservations" do
    belongs_to :team, Troupe.Plane.Identity.Team
    field :owner_subject, :string
    field :session_id, :string
    field :amount_micros, :integer
    field :released_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [:team_id, :owner_subject, :session_id, :amount_micros, :released_at])
    |> validate_required([:team_id, :session_id, :amount_micros])
    |> unique_constraint(:session_id)
  end
end
