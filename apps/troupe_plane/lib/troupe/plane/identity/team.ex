defmodule Troupe.Plane.Identity.Team do
  @moduledoc """
  A group a platform admin has enabled.

  Enabling is the only thing Troupe adds to a group, and it is what a grant, a budget
  and a volume hang off. Membership is still the IdP's: removing someone from the group
  removes them from the team, everywhere, at the next login or SCIM push.

  Retention lives here because it is a property of the team's work rather than of any
  one session — how long an idle session keeps its actor tree, how long a dormant one
  keeps a cache, and when it is erased.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "teams" do
    belongs_to :group, Troupe.Plane.Identity.Group
    field :name, :string
    field :enabled_at, :utc_datetime_usec
    field :enabled_by, :string

    # Whether `team` visibility grants control as well as observe.
    field :members_may_control, :boolean, default: false

    field :idle_timeout_seconds, :integer, default: 1800
    field :cache_eviction_days, :integer, default: 7
    field :erase_after_days, :integer, default: 365
    field :pins_allowed, :boolean, default: true

    field :budget_micros, :integer, default: 0
    field :budget_period, :string, default: "monthly"

    field :volume_storage_class, :string
    field :volume_size, :string, default: "10Gi"

    has_many :grants, Troupe.Plane.Identity.Grant

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :group_id,
    :name,
    :enabled_at,
    :enabled_by,
    :members_may_control,
    :idle_timeout_seconds,
    :cache_eviction_days,
    :erase_after_days,
    :pins_allowed,
    :budget_micros,
    :budget_period,
    :volume_storage_class,
    :volume_size
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(team, attrs) do
    team
    |> cast(attrs, @fields)
    |> validate_required([:group_id, :name])
    |> validate_inclusion(:budget_period, ["monthly", "never"])
    |> validate_number(:idle_timeout_seconds, greater_than: 0)
    |> unique_constraint(:group_id)
    |> unique_constraint(:name)
  end
end
