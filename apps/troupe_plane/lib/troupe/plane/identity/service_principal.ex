defmodule Troupe.Plane.Identity.ServicePrincipal do
  @moduledoc """
  A credential a team owns, for work nobody starts by hand.

  Not a person and not a member. A principal is created by a team admin for one team,
  may use a subset of that team's grants, and administers nothing — `Admin.actor_for/1`
  answers `:none` for it. Its subject is `svc:<team>/<name>`, which is what every
  session it creates carries as `owner_subject`, so a person reading a transcript sees
  that a principal asked for this and not a human.

  The secret is never stored: only a salted SHA-256 of it is, and the secret itself has
  256 bits of entropy, which is what makes a plain hash acceptable here where it would
  not be for a password somebody chose.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_principals" do
    field(:subject, :string)
    belongs_to(:team, Troupe.Plane.Identity.Team)
    field(:name, :string)
    field(:description, :string)
    field(:profiles, {:array, :string}, default: [])
    field(:secret_hash, :string)
    field(:secret_salt, :string)
    field(:created_by, :string)
    field(:disabled_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The subject a principal is known by: `svc:<team>/<name>`."
  @spec subject(String.t(), String.t()) :: String.t()
  def subject(team_name, name), do: "svc:" <> team_name <> "/" <> name

  @doc "The team and name a subject encodes, or `:error` for a subject that is not one."
  @spec parse_subject(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_subject("svc:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [team, name] when team != "" and name != "" -> {:ok, team, name}
      _ -> :error
    end
  end

  def parse_subject(_subject), do: :error

  @doc "Whether a principal may still authenticate."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{disabled_at: nil}), do: true
  def enabled?(%__MODULE__{}), do: false

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(principal, attrs) do
    principal
    |> cast(attrs, [
      :subject,
      :team_id,
      :name,
      :description,
      :profiles,
      :secret_hash,
      :secret_salt,
      :created_by,
      :disabled_at,
      :last_used_at
    ])
    |> validate_required([:subject, :team_id, :name, :profiles, :secret_hash, :secret_salt])
    # A name is part of a subject and of a claim name, so it is a label: lowercase,
    # digits and dashes, the same shape a team name has.
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9-]{0,62}$/,
      message: "is lowercase letters, digits and dashes"
    )
    |> unique_constraint(:subject)
    |> unique_constraint([:team_id, :name])
  end
end
