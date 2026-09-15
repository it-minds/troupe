defmodule Troupe.Plane.Triggers.Revision do
  @moduledoc """
  A trigger document, frozen and content-addressed.

  `trigger_runs` used to point at the mutable `triggers` row, so editing a prompt
  template rewrote the provenance of every run that had used the old one. A run names a
  revision instead, and a revision is never updated — the only two things that can
  happen to one are being created and being read.

  **A revision is a property of the document, not of the source.** The fields it covers
  are the ones that decide what a run *is*: which profile and agent, as which principal,
  from which template, under which terms, at which visibility, with which review, cap
  and notify list — and the `source` document itself, which carries a cron for a
  schedule and a provider for a webhook and will carry a discriminator for every other
  way a trigger is fired. Nothing here is cron-shaped, and nothing in the hash says how
  the firing arrived. That is the point: a firing from a schedule, a webhook, an API
  call or a person's hand names the same revision when the document has not moved.

  `enabled` is deliberately excluded. Switching a trigger off does not change what a run
  would be, and a revision per toggle would be a history made of noise.

  Content-addressed the way a bundle is: `Troupe.Protocol.Canonical` gives the stable
  encoding, and the `(trigger_id, hash)` index is what makes a `trigger.put` that
  changes nothing create nothing — and an admin who edits back to a previous wording
  land back on that revision rather than making a third.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Plane.Triggers.Trigger
  alias Troupe.Protocol.Canonical

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "trigger_revisions" do
    belongs_to(:trigger, Trigger)
    field(:revision, :integer)
    field(:hash, :string)

    field(:profile, :string)
    field(:agent, :string)
    belongs_to(:principal, Troupe.Plane.Identity.ServicePrincipal)
    field(:prompt_template, :string, default: "")
    field(:terms, :map, default: %{})
    field(:visibility, :string, default: "team")
    field(:review, :string, default: "required")
    field(:notify, {:array, :string}, default: [])
    field(:concurrency, :integer, default: 1)
    field(:source, :map, default: %{})

    field(:reconstructed, :boolean, default: false)
    field(:created_by, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  # The document, in the order a reader would want it and the order the migration that
  # backfilled revision 1 used. Changing this list changes every hash, which is why it
  # is one list in one place rather than a `Map.take` at each call site.
  @document ~w(profile agent principal_id prompt_template terms visibility review notify
               concurrency source)a

  @doc "The field names the hash covers."
  @spec document_fields() :: [atom()]
  def document_fields, do: @document

  @doc """
  The document of a trigger or a revision, as the hash sees it.

  Takes either, so "what would this trigger's revision be" and "what was this revision"
  are the same question asked of two rows.
  """
  @spec document(Trigger.t() | t()) :: map()
  def document(%{} = struct) do
    Map.new(@document, fn field -> {Atom.to_string(field), Map.fetch!(struct, field)} end)
  end

  @doc """
  The `sha256:` hash of a trigger's or a revision's document.

      iex> alias Troupe.Plane.Triggers.{Revision, Trigger}
      iex> a = %Trigger{profile: "p", principal_id: "x", source: %{"kind" => "schedule"}}
      iex> Revision.hash(a) == Revision.hash(%{a | enabled: false})
      true
  """
  @spec hash(Trigger.t() | t()) :: String.t()
  def hash(struct), do: struct |> document() |> Canonical.hash()

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(revision, attrs) do
    revision
    |> cast(
      attrs,
      [:trigger_id, :revision, :hash, :reconstructed, :created_by | @document]
    )
    |> validate_required([:trigger_id, :revision, :hash, :profile, :principal_id])
    |> unique_constraint([:trigger_id, :revision])
    |> unique_constraint([:trigger_id, :hash])
  end

  @doc "A revision as a listing shows it: the number, the hash, and when."
  @spec json(t()) :: map()
  def json(%__MODULE__{} = revision) do
    %{
      "id" => revision.id,
      "revision" => revision.revision,
      "hash" => revision.hash,
      "reconstructed" => revision.reconstructed,
      "created_by" => revision.created_by,
      "created_at" => revision.inserted_at && DateTime.to_iso8601(revision.inserted_at)
    }
  end
end
