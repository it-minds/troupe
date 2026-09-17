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

  ## A sponsor, who is a person

  Every principal names one, and a principal without one cannot be created. It is the
  answer to "who is answerable for this" for work nobody starts by hand: a spend that
  counts against somebody's cap, a trigger that fires at four in the morning, an outbound
  call made with a credential a team owns. A principal whose sponsor leaves is disabled
  at the next SCIM push and reported as *needing a sponsor* rather than as broken — the
  distinction matters, because one of those is somebody's job to fix in a minute and the
  other sends people looking for a fault.

  By subject rather than by row: a subject survives a provider re-creating a user, and it
  is what every other reference to a person here already uses.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @sponsor_left "sponsor_left"

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
    field(:sponsor_subject, :string)
    field(:disabled_at, :utc_datetime_usec)
    field(:disabled_reason, :string)
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

  @doc """
  Why a principal is not firing, in the words a console should use.

  `:needs_sponsor` and `:disabled` are different things to a person looking at a list.
  One of them is a name to put in a field; the other is somebody's decision. Reporting
  both as "disabled" is how an afternoon goes missing.
  """
  @spec state(t()) :: :enabled | :needs_sponsor | :disabled
  def state(%__MODULE__{disabled_at: nil, sponsor_subject: sponsor}) when is_binary(sponsor),
    do: :enabled

  # A row from before sponsors existed, and a row whose sponsor has left, are the same
  # thing to the person who has to fix it: a field with nobody in it.
  def state(%__MODULE__{disabled_at: nil}), do: :needs_sponsor
  def state(%__MODULE__{disabled_reason: @sponsor_left}), do: :needs_sponsor
  def state(%__MODULE__{}), do: :disabled

  @doc "The reason a departing sponsor leaves behind, so one spelling is used everywhere."
  @spec sponsor_left() :: String.t()
  def sponsor_left, do: @sponsor_left

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
      :sponsor_subject,
      :disabled_at,
      :disabled_reason,
      :last_used_at
    ])
    |> validate_required([:subject, :team_id, :name, :profiles, :secret_hash, :secret_salt])
    |> validate_required([:sponsor_subject],
      message: "is required: a principal has somebody answerable for it"
    )
    # A name is part of a subject and of a claim name, so it is a label: lowercase,
    # digits and dashes, the same shape a team name has.
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9-]{0,62}$/,
      message: "is lowercase letters, digits and dashes"
    )
    |> unique_constraint(:subject)
    |> unique_constraint([:team_id, :name])
  end
end
