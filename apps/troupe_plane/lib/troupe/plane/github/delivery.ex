defmodule Troupe.Plane.GitHub.Delivery do
  @moduledoc """
  One delivery the App's webhook took, by GitHub's own id: what it was and what the plane
  did with it. Never its body.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "github_deliveries" do
    field(:event, :string)
    field(:action, :string)
    field(:received_at, :utc_datetime_usec)
    field(:outcome, :map)
  end

  @type t :: %__MODULE__{}
end
