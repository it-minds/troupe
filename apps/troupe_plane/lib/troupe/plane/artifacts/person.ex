defmodule Troupe.Plane.Artifacts.Person do
  @moduledoc """
  A person an owner shared one artifact with by name (`Troupe.Plane.Artifacts.People`): the
  role it gives them, `view`, `comment` or `edit`, who gave it and when.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "artifact_people" do
    field(:artifact_id, :string, primary_key: true)
    belongs_to(:user, Troupe.Plane.Identity.User, primary_key: true)
    field(:role, :string)
    field(:granted_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
