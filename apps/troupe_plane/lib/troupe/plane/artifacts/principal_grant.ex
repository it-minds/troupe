defmodule Troupe.Plane.Artifacts.PrincipalGrant do
  @moduledoc """
  A team's service principal an owner shared one artifact with by name
  (`Troupe.Plane.Artifacts.People`), as a person is: the role it gives, who gave it and when.
  What lets a trigger's runs, which are its principal's, publish the next version of an
  artifact its sponsor owns alone. Gone with the principal.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "artifact_principals" do
    field(:artifact_id, :string, primary_key: true)
    belongs_to(:principal, Troupe.Plane.Identity.ServicePrincipal, primary_key: true)
    field(:role, :string)
    field(:granted_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
