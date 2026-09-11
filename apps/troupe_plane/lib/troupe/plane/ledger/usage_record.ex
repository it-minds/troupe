defmodule Troupe.Plane.Ledger.UsageRecord do
  @moduledoc """
  One model call, as the spend ledger records it.

  The gateway's request id is the join with the outside world: both Troupe and the LLM
  gateway know it, so reconciliation can ask "what did you bill that I have no record
  of?" and get an answer that names requests rather than amounts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "usage_records" do
    field :session_id, :string
    belongs_to :team, Troupe.Plane.Identity.Team
    field :owner_subject, :string
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_micros, :integer, default: 0
    field :gateway_request_id, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :session_id,
      :team_id,
      :owner_subject,
      :model,
      :input_tokens,
      :output_tokens,
      :cost_micros,
      :gateway_request_id,
      :occurred_at
    ])
    |> validate_required([:session_id, :owner_subject, :model, :gateway_request_id, :occurred_at])
    |> unique_constraint(:gateway_request_id)
  end
end
