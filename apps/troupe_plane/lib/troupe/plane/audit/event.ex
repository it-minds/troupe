defmodule Troupe.Plane.Audit.Event do
  @moduledoc "One recorded administrative change."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_events" do
    field :actor, :string
    field :action, :string
    field :subject_kind, :string
    field :subject_id, :string
    field :detail, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:actor, :action, :subject_kind, :subject_id, :detail, :occurred_at])
    |> validate_required([:actor, :action, :subject_kind, :occurred_at])
  end
end
