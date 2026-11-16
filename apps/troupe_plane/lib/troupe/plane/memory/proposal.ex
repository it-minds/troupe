defmodule Troupe.Plane.Memory.Proposal do
  @moduledoc """
  One entry an agent proposed for a team's or the organisation's memory
  (`Troupe.Plane.Memory.Proposals`): the entry and its topic, the session, the agent and the
  person it came from, and what became of it. Pending, it is in no document and no session
  reads it; accepted, `version` is the version of the document it came in; declined,
  `reason` is the sentence the session was told.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(team organisation)
  @states ~w(pending accepted declined)
  @wheres ~w(pod machine)

  schema "memory_proposals" do
    field(:scope, :string)
    belongs_to(:team, Troupe.Plane.Identity.Team)
    field(:topic, :string)
    field(:entry, :string)
    field(:session_id, :string)
    field(:agent, :string)
    field(:where, :string)
    belongs_to(:proposer, Troupe.Plane.Identity.User)
    field(:proposer_subject, :string)
    field(:state, :string, default: "pending")
    field(:decided_by, :string)
    field(:decided_at, :utc_datetime_usec)
    field(:reason, :string)
    field(:version, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The levels a proposal may be for."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:scope, :team_id, :topic, :entry, :session_id, :agent, :where, :proposer_id, :proposer_subject])
    |> validate_required([:scope, :topic, :entry, :where, :proposer_subject])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:where, @wheres)
    |> validate_inclusion(:state, @states)
  end
end
