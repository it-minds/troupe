defmodule Troupe.Session.Usage do
  @moduledoc """
  What a session's log says it spent.

  A projection, not a record. Every model call a session makes is already a durable
  `llm_response` event carrying the tokens, the model and — where a gateway sat in front
  of the provider — that gateway's request id and price. Turning those events into
  ledger rows is therefore a fold, and the fold is the only place the two shapes meet.

  That it is a fold is the whole point. A pod that could not reach the plane for an hour
  does not have to have kept a queue: it folds its own log forward from the last sequence
  the plane acknowledged and sends what is missing. A pod that crashes mid-flush loses
  nothing for the same reason. And because the plane's `usage_records` table is unique on
  the request id, sending the same record twice is not a second charge — so the fold may
  be run again whenever it is cheaper to re-fold than to remember.

  ## Sessions that ran before there was a gateway to ask

  An `llm_response` written by an earlier build has tokens and nothing else. Those are
  still real tokens, so they are still recorded, with a cost of zero and a request id
  synthesised from the session and the sequence — `seq:<session>:<n>`. That shape is
  deliberately not one a gateway would ever mint, which is what lets
  `Troupe.Plane.Reconcile` count them as cost the gateway knows about and the ledger does
  not, rather than as a call the gateway never made.
  """

  alias Troupe.Protocol.Event

  defmodule Sink do
    @moduledoc """
    Where a usage record goes once the log has it.

    A behaviour rather than a call, because a session runs in three places that want
    three different answers. On a worker pod the sink is
    `Troupe.Worker.Usage`, which collects records for the plane's ledger. On a laptop
    there is no plane and no sink at all, and the accounting is simply not done. In a
    test the sink is whatever the test wants to look at.

    `put/2` is called from the log process, immediately after the event is durable and
    published. It must not block: an implementation that needs to do work should write
    somewhere cheap and do the work elsewhere.
    """

    @callback put(session_id :: String.t(), usage :: Troupe.Session.Usage.t()) :: :ok
  end

  @type t :: %{
          seq: pos_integer(),
          request_id: String.t(),
          model: String.t() | nil,
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost_micros: non_neg_integer(),
          occurred_at: DateTime.t() | nil
        }

  @doc """
  Every usage record implied by these events, in sequence order.

  Events that are not `llm_response` are ignored, so a caller may pass a whole replay.
  """
  @spec records(String.t(), [Event.t()]) :: [t()]
  def records(session_id, events) when is_binary(session_id) and is_list(events) do
    events
    |> Enum.filter(&match?(%Event{type: "llm_response"}, &1))
    |> Enum.map(&record(session_id, &1))
    |> Enum.sort_by(& &1.seq)
  end

  @doc """
  One record from one `llm_response`.

  Public because the live path folds a single event as it arrives and the catch-up path
  folds a list; both must produce the same row for the same event, and the way to
  guarantee that is for there to be one function.
  """
  @spec record(String.t(), Event.t()) :: t()
  def record(session_id, %Event{type: "llm_response", seq: seq, data: data} = event) do
    usage = data["usage"] || %{}
    gateway = data["gateway"] || %{}

    %{
      seq: seq,
      request_id: gateway["request_id"] || synthetic_request_id(session_id, seq),
      model: data["model"],
      input_tokens: count(usage["input_tokens"]),
      output_tokens: count(usage["output_tokens"]),
      cost_micros: count(gateway["cost_micros"]),
      occurred_at: occurred_at(event)
    }
  end

  @doc """
  The request id given to a call no gateway named.

  Stable for a given session and sequence, so re-folding the same log produces the same
  id and the ledger's uniqueness does the deduplication for free.
  """
  @spec synthetic_request_id(String.t(), pos_integer()) :: String.t()
  def synthetic_request_id(session_id, seq), do: "seq:#{session_id}:#{seq}"

  @doc """
  Hand one durable event to the configured sink.

  Called by `Troupe.Session.Log` for every event it writes, and a no-op for all but one
  type and for every deployment with no sink configured — which is every laptop, since
  there is no ledger to report to.
  """
  @spec observe(String.t(), Event.t()) :: :ok
  def observe(session_id, %Event{type: "llm_response"} = event) do
    case Application.get_env(:troupe_core, :usage_sink) do
      nil -> :ok
      module -> module.put(session_id, record(session_id, event))
    end
  end

  def observe(_session_id, %Event{}), do: :ok

  @doc "The wire shape of a record, as `usage.batch` carries it."
  @spec to_json(t()) :: map()
  def to_json(record) do
    %{
      "seq" => record.seq,
      "gateway_request_id" => record.request_id,
      "model" => record.model,
      "input_tokens" => record.input_tokens,
      "output_tokens" => record.output_tokens,
      "cost_micros" => record.cost_micros,
      "occurred_at" => record.occurred_at && DateTime.to_iso8601(record.occurred_at)
    }
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_other), do: 0

  # The event's own timestamp, which is when the call actually finished, rather than
  # when the plane happened to hear about it. A record folded out of a log an hour later
  # must not land in the wrong billing window.
  defp occurred_at(%Event{ts: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp occurred_at(_event), do: nil
end
