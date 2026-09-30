defmodule Troupe.Plane.Triggers.Trigger do
  @moduledoc """
  A definition of work nobody starts by hand.

  What fires (`source`: a cron schedule, or a webhook an executor outside the plane
  terminates), as whom (`principal_id`), on which profile, with which prompt template
  and terms, and who is told. The plane stores it; the executor — Hatchet where it is
  deployed, the in-plane scheduler for cron where it is not — reads it when it fires.

  `concurrency` is the cap on live runs; a firing over it records a skipped run rather
  than a second session. `review` says whether a person is expected to close the loop,
  and `notify` who is granted collaborator on each run so that they can. `notify_url` is
  the other half of that: somebody else's system, told when a run ends. What may go in it
  is narrow on purpose — see `Troupe.Plane.Triggers.Notify`.

  A trigger may hold a **key of its own**, hashed as a principal's secret is, which is
  the whole of what `POST /trigger/<id>` accepts. It is narrower than any other
  credential the plane has: it fires this one trigger and does nothing else, which is
  what makes it the thing to give a CI job. The key is never readable after the rotation
  that minted it — the columns hold a hash and a salt, and neither reconstructs it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Plane.Triggers.{Cron, Notify, Source}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # What is expected to fire it. Not the same question as how a given firing arrived —
  # that is the run's `source`, and a schedule trigger run by hand is still a `manual`
  # firing. `manual` here means nothing fires it automatically: it exists to be run by a
  # person, by the API or by an agent.
  @source_kinds ~w(schedule webhook manual)
  @visibilities ~w(private team)
  @reviews ~w(required none)

  # The zones a schedule may name, which are UTC's names and none at all.
  @utc [nil, "UTC", "Etc/UTC"]

  schema "triggers" do
    belongs_to(:team, Troupe.Plane.Identity.Team)
    field(:name, :string)
    belongs_to(:principal, Troupe.Plane.Identity.ServicePrincipal)
    field(:profile, :string)
    field(:agent, :string)
    field(:enabled, :boolean, default: true)
    field(:source, Source, default: %{})
    field(:prompt_template, :string, default: "")
    field(:terms, :map, default: %{})
    field(:visibility, :string, default: "team")
    field(:review, :string, default: "required")
    field(:notify, {:array, :string}, default: [])
    field(:notify_url, :string)
    field(:concurrency, :integer, default: 1)
    field(:last_fired_at, :utc_datetime_usec)
    field(:created_by, :string)

    # Never in `@fields`: a key is written by `Triggers.rotate_key/2` and by nothing
    # else, so a `trigger.put` that carried a `key_hash` — from a caller replaying a
    # listing, say — sets nothing.
    field(:key_hash, :string)
    field(:key_salt, :string)
    field(:key_rotated_at, :utc_datetime_usec)
    field(:key_rotated_by, :string)

    # In GitOps mode, the generation of the `Trigger` resource this row was last read from
    # (Decision 737), and `nil` for a row no resource was ever read into. Not in `@fields`
    # either: the pass that reads the cluster writes it and nothing else does.
    field(:resource_generation, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :team_id,
    :name,
    :principal_id,
    :profile,
    :agent,
    :enabled,
    :source,
    :prompt_template,
    :terms,
    :visibility,
    :review,
    :notify,
    :notify_url,
    :concurrency,
    :last_fired_at,
    :created_by
  ]

  @doc "Every kind of thing a trigger's document says is expected to fire it."
  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  @doc """
  Whether a source's zone is one this plane keeps: UTC, or none, which is UTC.

  Only a row saved before the zone was checked has another, and the scheduler does not
  fire it: at three in UTC it would run at the wrong hour, and there is no time zone
  database here to say when three in its zone is.
  """
  @spec utc?(map()) :: boolean()
  def utc?(source), do: source["tz"] in @utc

  @doc "Set or replace the trigger's own key. Separate from `changeset/2` on purpose."
  @spec key_changeset(t(), map()) :: Ecto.Changeset.t()
  def key_changeset(trigger, attrs) do
    cast(trigger, attrs, [:key_hash, :key_salt, :key_rotated_at, :key_rotated_by])
  end

  @doc "Record the generation of the resource a row was read from, in GitOps mode."
  @spec generation_changeset(t() | Ecto.Changeset.t(), integer() | nil) :: Ecto.Changeset.t()
  def generation_changeset(trigger, generation) do
    cast(trigger, %{resource_generation: generation}, [:resource_generation])
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, @fields)
    |> validate_required([:team_id, :name, :principal_id, :profile, :source])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9-]{0,62}$/,
      message: "is lowercase letters, digits and dashes"
    )
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:review, @reviews)
    |> validate_number(:concurrency, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_length(:prompt_template, max: 65_536)
    |> validate_notify_url()
    |> validate_source()
    |> unique_constraint([:team_id, :name])
  end

  # A schedule needs a cron the scheduler can read, in UTC because there is no time zone
  # database in this release; a webhook names its provider and is otherwise the
  # executor's business.
  defp validate_source(changeset) do
    case get_field(changeset, :source) do
      %{"kind" => "schedule"} = source ->
        changeset
        |> validate_cron(source["cron"])
        |> validate_tz(source["tz"])

      %{"kind" => kind} when kind in @source_kinds ->
        changeset

      _other ->
        add_error(changeset, :source, "has a kind of #{Enum.join(@source_kinds, ", ")}")
    end
  end

  # Checked here so an administrator is told while they are still looking at the form,
  # and again at send, where the host is resolved. A name is not an address: a target
  # that was fine when it was saved can answer `127.0.0.1` today.
  defp validate_notify_url(changeset) do
    case Notify.validate(get_field(changeset, :notify_url)) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :notify_url, reason)
    end
  end

  defp validate_cron(changeset, cron) do
    case Cron.parse(cron) do
      {:ok, _parsed} -> changeset
      {:error, reason} -> add_error(changeset, :source, "cron is not readable: #{reason}")
    end
  end

  defp validate_tz(changeset, tz) when tz in @utc, do: changeset

  defp validate_tz(changeset, tz) do
    add_error(changeset, :source, "tz #{inspect(tz)} is not supported; this plane keeps UTC")
  end
end
