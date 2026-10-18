defmodule Troupe.Plane.Remote.Offer do
  @moduledoc """
  A laptop session its person offered to the plane: who, from which device, shared with
  whom, and since when the laptop has been away. Nothing the session says is here.

  `shares` is `%{"people" => [%{"subject", "display_name", "email", "role"}]}`, the people
  the laptop named when it offered the session, as this plane resolved them; the laptop
  keeps the same list and checks every relayed message against its own copy.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:session_id, :string, autogenerate: false}

  schema "remote_sessions" do
    field :owner_subject, :string
    field :device, :string
    field :workspace, :string
    field :shares, :map, default: %{"people" => []}
    field :offered_at, :utc_datetime_usec
    field :offline_since, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [:session_id, :owner_subject, :device, :workspace, :shares, :offered_at, :offline_since]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(offer, attrs) do
    offer
    |> cast(attrs, @fields)
    |> validate_required([:session_id, :owner_subject, :device, :offered_at])
    |> validate_length(:workspace, max: 255)
  end

  @doc "The people a session is shared with."
  @spec people(t()) :: [map()]
  def people(%__MODULE__{shares: %{"people" => people}}) when is_list(people), do: people
  def people(_offer), do: []
end
