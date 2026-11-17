defmodule Troupe.Plane.Artifacts.Keep do
  @moduledoc """
  An artifact one person keeps at the top of their own gallery
  (`Troupe.Plane.Artifacts.Keeps`), and when they did.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "artifact_keeps" do
    belongs_to(:user, Troupe.Plane.Identity.User, primary_key: true)
    field(:artifact_id, :string, primary_key: true)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
