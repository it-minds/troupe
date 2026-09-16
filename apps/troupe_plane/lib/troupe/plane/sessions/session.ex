defmodule Troupe.Plane.Sessions.Session do
  @moduledoc """
  The plane's row for a session: metadata, never content.

  Everything here is something a listing or a placement decision needs. What was said,
  what was read, what was written — none of it crosses into this database, and a done
  item proves it by looking for a marker string in a dump.

  `epoch` is the one field with teeth. It is minted here and nowhere else, it appears in
  the object keys of every segment written under it, and a seal report from an older
  epoch is rejected. That is what stops a pod presumed lost from appending to a session
  that has moved on.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id

  # `pending` is a session that exists and has no worker yet: the profile is full but
  # growing, and the plane has asked for another. It is not a failure and not a queue
  # entry — it is the session, waiting for the room somebody is already bringing up.
  @states ~w(pending active dormant read_only erased)
  # Whose session it is, which decides where it can run. A team session is placed on a
  # pod of a profile; a private one runs on its owner's machine and is never placed at
  # all. Not the same question as `visibility`, which is who else may see it.
  @kinds ~w(team private)
  @visibilities ~w(private team)
  # What the worker reports the session is doing. `state` above is the plane's word on
  # whether a tree exists; `status` is the worker's on what the tree is up to.
  @statuses ~w(idle thinking acting waiting done interrupted)
  @origins ~w(user trigger a2a agent)

  schema "sessions" do
    belongs_to(:owner, Troupe.Plane.Identity.User)
    field(:owner_subject, :string)
    belongs_to(:team, Troupe.Plane.Identity.Team)
    field(:profile, :string)
    field(:kind, :string, default: "team")
    field(:visibility, :string, default: "private")
    field(:state, :string, default: "active")

    field(:epoch, :integer, default: 1)
    belongs_to(:worker, Troupe.Plane.Fleet.Worker)
    # The machine that last sealed a private session. A name the person chose, not an
    # identifier we can check, which is all a conflict display needs it to be.
    field(:device, :string)

    field(:title, :string)
    field(:workspace_source, :map)
    field(:bundle_version, :integer)
    field(:retention_class, :string)
    field(:pinned, :boolean, default: false)
    field(:pinned_by, :string)
    field(:pinned_at, :utc_datetime_usec)

    field(:last_active_at, :utc_datetime_usec)
    field(:last_seq, :integer, default: 0)
    field(:head_hash, :string)
    field(:object_bytes, :integer, default: 0)
    field(:workspace_bytes, :integer, default: 0)

    # Lifecycle the worker reports, so a queue can be listed without reading a log.
    field(:status, :string, default: "idle")
    field(:done_reason, :string)
    field(:pending_approvals, :integer, default: 0)
    field(:cost_micros, :integer, default: 0)

    # How far the ledger has got through this session's log. A cursor between the pod's
    # log and `usage_records`, carried back to the pod on every batch so it knows what
    # it still owes; behind is safe and costs a re-fold, ahead is not possible.
    field(:usage_seq, :integer, default: 0)

    # Fixed at creation: what started this session, and what it was allowed.
    field(:origin, :map)
    field(:terms, :map)
    # Held only while a session waits for a worker, and cleared when it gets one.
    field(:pending_prompt, :string)

    field(:reviewed_by, :string)
    field(:reviewed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The four states a session can be in."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "What a worker may say a session is doing."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Whose session it is: a team's, or a person's own."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The kinds of thing that start a session."
  @spec origins() :: [String.t()]
  def origins, do: @origins

  @fields [
    :id,
    :owner_id,
    :owner_subject,
    :team_id,
    :profile,
    :kind,
    :visibility,
    :state,
    :epoch,
    :worker_id,
    :device,
    :title,
    :workspace_source,
    :bundle_version,
    :retention_class,
    :pinned,
    :pinned_by,
    :pinned_at,
    :last_active_at,
    :last_seq,
    :head_hash,
    :object_bytes,
    :workspace_bytes,
    :status,
    :done_reason,
    :pending_approvals,
    :cost_micros,
    :usage_seq,
    :origin,
    :pending_prompt,
    :terms,
    :reviewed_by,
    :reviewed_at
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @fields)
    |> validate_required([:id, :owner_subject])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_shape()
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:pending_approvals, greater_than_or_equal_to: 0)
    |> validate_number(:cost_micros, greater_than_or_equal_to: 0)
    |> validate_number(:usage_seq, greater_than_or_equal_to: 0)
    |> check_constraint(:kind, name: :sessions_kind_shape)
  end

  # The database has the same rule as a constraint, because the row is what a placement
  # reads and application code is not the only thing that writes it. This is here so the
  # caller gets a field and a sentence rather than a constraint error.
  defp validate_shape(changeset) do
    case get_field(changeset, :kind) do
      "private" -> refute_present(changeset, [:profile, :team_id, :worker_id])
      _team -> validate_required(changeset, [:profile])
    end
  end

  defp refute_present(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_field(acc, field) do
        nil -> acc
        _set -> add_error(acc, field, "a private session has no #{field}")
      end
    end)
  end
end
