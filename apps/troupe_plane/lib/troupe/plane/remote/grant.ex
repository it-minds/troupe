defmodule Troupe.Plane.Remote.Grant do
  @moduledoc """
  A laptop daemon's own sign-in for steering (#58 slice 2): one per person and device.

  The daemon holds `rg_<id>.<secret>` in its operating system's credential store and
  exchanges it at `/auth/relay` for a fifteen-minute token whose audience is the laptop's
  door alone (`Troupe.Plane.Remote.laptop_audience/0`), naming the device. The plane keeps
  the secret's hash and when it was last used, never the secret.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "remote_grants" do
    field :subject, :string
    field :device, :string
    field :secret_hash, :binary
    field :used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:subject, :device, :secret_hash, :used_at])
    |> validate_required([:subject, :device, :secret_hash])
    |> unique_constraint([:subject, :device])
  end
end
