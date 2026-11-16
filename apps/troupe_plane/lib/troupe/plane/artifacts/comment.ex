defmodule Troupe.Plane.Artifacts.Comment do
  @moduledoc """
  One comment in an artifact's thread (`Troupe.Plane.Artifacts.Comments`): who wrote it,
  the text and when. The author's subject is kept beside the person, so a thread still says
  who wrote a comment after its author's record is gone.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifact_comments" do
    field(:artifact_id, :string)
    belongs_to(:author, Troupe.Plane.Identity.User)
    field(:author_subject, :string)
    field(:body, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
