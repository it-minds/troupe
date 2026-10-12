defmodule Troupe.Plane.GitHub.App do
  @moduledoc """
  The plane's one GitHub App, as a row: who it is, where its API is, which installations
  it may use, and what is known about its private key.

  What is known, not the key. The key is in OpenBao's transit engine, imported there by
  `Troupe.Plane.GitHub.Key`, and nothing can read it back; the row keeps its type, the
  fingerprint GitHub shows beside it, and the version transit holds it at, so a person
  can match the key the plane signs with against the ones registered on the App.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "github_app" do
    field(:app_id, :integer)
    field(:api_url, :string)
    field(:installations, {:array, :map}, default: [])
    field(:key_type, :string)
    field(:key_fingerprint, :string)
    field(:key_version, :integer)
    field(:updated_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The one row's key: a plane has one App."
  @spec id() :: String.t()
  def id, do: "app"
end
