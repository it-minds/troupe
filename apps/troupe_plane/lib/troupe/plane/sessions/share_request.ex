defmodule Troupe.Plane.Sessions.ShareRequest do
  @moduledoc """
  A share of a sensitive session beyond the people who read it now, held for a team
  administrator's yes because the session's profile says `sensitive.sharing: ask`.

  `kind` is what was asked: `visibility` (giving it to the team), `invite` (a person by
  name, `params.subject` and `params.role`), `grant` (`params.subject`, `params.role`) or
  `artifact` (an artifact the session published, moved to `params.visibility` or shared
  with `params.person`). `requested_by` is the owner who asked; once answered, `state` is
  `approved` or `declined`, with who answered and when. The present readers go on reading
  while it waits.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "session_share_requests" do
    field(:session_id, :string)
    field(:team, :string)
    field(:kind, :string)
    field(:params, :map, default: %{})
    field(:requested_by, :string)
    field(:state, :string, default: "pending")
    field(:decided_by, :string)
    field(:decided_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}

  @kinds ~w(visibility invite grant artifact)

  @doc "What may be held: the kinds of share a sensitive session's owner may ask for."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The request as a client is sent it."
  @spec json(t()) :: map()
  def json(%__MODULE__{} = request) do
    %{
      "id" => request.id,
      "session_id" => request.session_id,
      "team" => request.team,
      "kind" => request.kind,
      "params" => request.params,
      "requested_by" => request.requested_by,
      "state" => request.state,
      "decided_by" => request.decided_by,
      "decided_at" => request.decided_at && DateTime.to_iso8601(request.decided_at),
      "at" => DateTime.to_iso8601(request.inserted_at)
    }
  end
end
