defmodule Troupe.Plane.Identity.Team do
  @moduledoc """
  A Troupe object that draws its members from identity-provider groups.

  It used to *be* a group, one for one and for ever, which meant the shape of a team was
  whatever shape the provider's groups happened to have. It links to any number of them
  now — `Troupe.Plane.Identity.TeamGroupLink` — and its membership is the union.

  `group_id` is which group it was first enabled from. It is a record rather than a
  resolution: nothing derives membership from it any more.

  Everything a team owns is the team's: budget, retention, default visibility, volume,
  grants and administrators. Membership is still the provider's — removing somebody from
  a linked group removes them from the team, everywhere, at the next login or SCIM push.

  Retention lives here because it is a property of the team's work rather than of any
  one session — how long an idle session keeps its actor tree, how long a dormant one
  keeps a cache, and when it is erased.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # What a name may be. It is not a label: it is the address a team has everywhere —
  # a grant, a session's team, an audit row, an API argument — and it is also *part of
  # other names*. The worker keys a session under `troupe/teams/<name>/sessions/<id>` in
  # OpenBao, and the operator names a team's volume claim `team-<name>` in Kubernetes,
  # which accepts lowercase letters, digits and dashes and nothing else, in at most 63
  # characters. Fifty-eight here leaves room for the `team-`.
  #
  # `Admin Buddies` is the name that found this. It was accepted, and every session create
  # then failed at the pod: the worker sent the space raw in an OpenBao URL, and the HTTP
  # client refused the request before it left the building. A worker new enough to encode
  # the segment would have got further and failed later, at the volume claim.
  @name_format ~r/^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$/
  @name_rule "lowercase letters, digits and dashes, starting and ending with a letter or digit, at most 58 characters — it becomes part of a Kubernetes name and an OpenBao path"

  @doc "What a team name must be, in words, for a form to show beside the field."
  @spec name_rule() :: String.t()
  def name_rule, do: @name_rule

  # What a budget is measured over: the calendar month in UTC, or nothing — a ceiling that
  # never turns over. `Troupe.Plane.Ledger.period_start/1` is where that is read.
  # The one list: the Teams page and the admin API offer it, and the platform's default
  # period is tested against it. `daily` was offered by all three and refused here.
  @budget_periods ~w(monthly never)

  @doc "The periods a team's budget may be measured over."
  @spec budget_periods() :: [String.t()]
  def budget_periods, do: @budget_periods

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

    # Whether this team may be granted a profile whose substrate does not enforce. A
    # platform admin's, per team, and `false` until one says otherwise — see the migration
    # for why it is not a platform-wide switch.
    field :allow_unenforced_workers, :boolean, default: false

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
    :volume_size,
    :allow_unenforced_workers
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(team, attrs) do
    team
    |> cast(attrs, @fields)
    |> validate_required([:group_id, :name])
    |> validate_format(:name, @name_format, message: @name_rule)
    |> validate_inclusion(:budget_period, @budget_periods)
    |> validate_number(:idle_timeout_seconds, greater_than: 0)
    # The name, not the group. A team is addressed by name everywhere — a grant, a
    # session's team, an audit row — so two called `engineering` would be two answers to
    # one question; but one group may be two teams, which is the whole of what a link
    # table is for.
    |> unique_constraint(:name)
  end
end
