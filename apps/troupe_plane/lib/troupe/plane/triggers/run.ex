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
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(created running waiting done failed skipped)
  @stored_states ~w(created failed skipped)

  schema "trigger_runs" do
    belongs_to(:trigger, Troupe.Plane.Triggers.Trigger)
    field(:idempotency_key, :string)
    field(:session_id, :string)
    field(:fired_at, :utc_datetime_usec)
    field(:fired_by, :string)
    field(:event, :map, default: %{})
    field(:state, :string, default: "created")
    field(:reviewed_by, :string)
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Every state a run can be reported in, stored or derived."
  @spec states() :: [String.t()]
  def states, do: @states

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :trigger_id,
      :idempotency_key,
      :session_id,
      :fired_at,
      :fired_by,
      :event,
      :state,
      :reviewed_by,
      :reviewed_at
    ])
    |> validate_required([:trigger_id, :idempotency_key, :fired_at, :state])
    |> validate_inclusion(:state, @stored_states)
    |> unique_constraint(:idempotency_key)
  end
end
