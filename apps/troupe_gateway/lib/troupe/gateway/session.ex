defmodule Troupe.Gateway.Session do
  @moduledoc """
  Subscription bookkeeping: what a client asked to see, and what counts as seeing it.

  A subscription is a cursor over the durable log plus a filter. `detail` is every
  event for one session; `summary` is the throttled projection plus lifecycle;
  `fleet` is lifecycle only, across every session the principal can see.
  """

  alias Troupe.Protocol.Event

  defmodule Subscription do
    @moduledoc "One live subscription on one connection."

    @enforce_keys [:id, :topic, :level]
    defstruct [:id, :topic, :level, :session_id, cursor: 0, replay: []]

    @type t :: %__MODULE__{
            id: String.t(),
            topic: String.t(),
            level: :summary | :detail,
            session_id: String.t() | nil,
            cursor: non_neg_integer(),
            replay: [Event.t()]
          }
  end

  # Lifecycle is what `fleet` and `summary` carry: enough to know a session exists and
  # what became of it, never enough to read its work.
  @lifecycle ~w(
    session_created agent_started agent_restarted agent_done session_dormant
    session_activated session_resumed session_archived session_erased
    budget_exhausted cancelled approval_requested approval_decided
  )

  @doc "Event types that reach a `fleet` or `summary` subscriber."
  @spec lifecycle_types() :: [String.t()]
  def lifecycle_types, do: @lifecycle

  @doc "Parse a topic string into its parts."
  @spec parse_topic(String.t()) :: {:ok, :fleet, nil} | {:ok, :session, String.t()} | :error
  def parse_topic("fleet"), do: {:ok, :fleet, nil}

  def parse_topic("session:" <> session_id) when session_id != "",
    do: {:ok, :session, session_id}

  def parse_topic(_topic), do: :error

  @doc "Whether an event belongs on a subscription."
  @spec interested?(Subscription.t(), String.t(), Event.t()) :: boolean()
  def interested?(%Subscription{topic: "fleet"}, _session_id, %Event{} = event) do
    event.type in @lifecycle
  end

  def interested?(%Subscription{session_id: id, level: level}, session_id, %Event{} = event) do
    id == session_id and level_allows?(level, event)
  end

  defp level_allows?(:detail, _event), do: true

  defp level_allows?(:summary, %Event{type: type, ephemeral?: ephemeral?}) do
    type == "summary_diff" or (not ephemeral? and type in @lifecycle)
  end

  @doc """
  Start receiving a topic's events.

  Registering happens *before* the head is read, so an event published during the
  replay lands in the mailbox and is delivered after it — which is what makes the
  handover from replay to live gapless and duplicate-free.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe("fleet") do
    # Fleet spans every session, so the connection follows each of them and filters.
    Enum.each(Troupe.session_ids(), &Troupe.subscribe/1)
    :ok
  end

  def subscribe("session:" <> session_id), do: Troupe.subscribe(session_id)

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe("fleet") do
    Enum.each(Troupe.session_ids(), &Troupe.unsubscribe/1)
    :ok
  end

  def unsubscribe("session:" <> session_id), do: Troupe.unsubscribe(session_id)
end
