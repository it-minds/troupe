defmodule Troupe.Plane.Settings.Stored do
  @moduledoc """
  One setting a platform admin has changed.

  A row exists only for a setting somebody overrode. Absence is not a null value, it is
  "whatever this plane was deployed with", which is why `Troupe.Plane.Settings` can reset
  a setting by deleting the row rather than by writing the default back into it — writing
  the default back would freeze today's default into the database and make the next
  deployment's change invisible.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  schema "platform_settings" do
    field(:value, :string)
    field(:updated_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(stored, attrs) do
    stored
    |> cast(attrs, [:key, :value, :updated_by])
    |> validate_required([:key, :value, :updated_by])
  end
end
