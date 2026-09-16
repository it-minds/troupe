defmodule Troupe.Plane.Triggers.Run do
  @moduledoc """
  One firing of a trigger: the record a person reads afterwards.

  The stored `state` is only what the plane decided at the moment of firing — `created`
  when a session was made, `skipped` when the concurrency cap said no, `failed` when the
  create itself failed. Everything after that is read from the session's status columns
  rather than written here, because a run that had to be told its session finished would
  be a second copy of a fact the index already holds; `Triggers.state_of/2` is where the
  two are combined.

  `event` is what the provider filter let through and is capped at 16 KiB: the issue key
  and its title, never the whole webhook body, so the run is a record and not a channel.

  `source` is how the firing arrived — one of seven, closed — and `payload_digest` is a
  hash of the event as it came in. The digest is over the whole payload while `event` is
  capped, so two firings can be compared for sameness even where the plane declined to
  keep the larger of them.

  `revision_id` names the trigger document this firing actually used. It is not null and
  it never changes: the trigger row an admin edits is what the *next* firing resolves,
  and a run that pointed at it would have its provenance rewritten by somebody fixing a
  typo six weeks later.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(created running waiting done failed skipped)
  @stored_states ~w(created failed skipped)

  # How the firing arrived. Seven, closed, and the same seven the durable `trigger_fired`
  # event carries — a run whose source were a free string would be a column nobody could
  # group by twice running.
  #
  # Not to be confused with the *trigger's* `source` document, which says what is
  # expected to fire it: a trigger written for a cron schedule is still fired by a
  # person's hand from the console, and that run's source is `manual`.
  @sources ~w(schedule webhook integration ci api manual agent)

  # What a caller at the plane's API may say about itself. The other four are vouched for
  # by the door rather than claimed: `schedule` is the scheduler's alone, `manual` the
  # console's, `webhook` the trigger-key ingress's, and `agent` the in-system MCP
  # projection's. A source anybody could claim is a discriminator that discriminates
  # nothing — an executor calling `/rpc` could label its runs `schedule` and disappear
  # into the cron rows.
  @claimable ~w(api ci integration)

  schema "trigger_runs" do
    belongs_to(:trigger, Troupe.Plane.Triggers.Trigger)
    belongs_to(:revision, Troupe.Plane.Triggers.Revision)
    field(:idempotency_key, :string)
    field(:session_id, :string)
    field(:fired_at, :utc_datetime_usec)
    field(:fired_by, :string)
    field(:source, :string)
    field(:event, :map, default: %{})
    field(:payload_digest, :string)
    field(:state, :string, default: "created")
    field(:reviewed_by, :string)
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Every state a run can be reported in, stored or derived."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Every way a firing can arrive."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "The sources a caller holding a credential may name for itself at `/rpc`."
  @spec claimable_sources() :: [String.t()]
  def claimable_sources, do: @claimable

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :trigger_id,
      :revision_id,
      :idempotency_key,
      :session_id,
      :fired_at,
      :fired_by,
      :source,
      :event,
      :payload_digest,
      :state,
      :reviewed_by,
      :reviewed_at
    ])
    |> validate_required([
      :trigger_id,
      :revision_id,
      :idempotency_key,
      :fired_at,
      :state,
      :source
    ])
    |> validate_inclusion(:state, @stored_states)
    |> validate_inclusion(:source, @sources)
    |> unique_constraint(:idempotency_key)
  end
end
