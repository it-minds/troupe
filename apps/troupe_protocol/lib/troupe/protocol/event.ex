defmodule Troupe.Protocol.Event do
  @moduledoc """
  The two kinds of event a client sees.

  **Durable** events are the session. They carry `seq`, `prev_hash`, `ts`, `actor`,
  `agent`, `type`, `v` and `data`, are persisted, and replay in exactly that order
  forever. Every client view and every audit is a fold over them.

  **Ephemeral** events — model deltas, progress, presence — carry no `seq`, are never
  persisted, and may be dropped under load. Nothing is lost when they are: every
  completed model message also lands as a durable `llm_response`.

  The hash chain is what makes the log verifiable without trusting the server:
  `prev_hash` is the canonical-JSON digest of the previous event, computed over the
  event *without* its own `prev_hash` field, so a verifier can recompute it from
  stored data alone.
  """

  alias Troupe.Protocol.Canonical

  defmodule Actor do
    @moduledoc "Who caused an event: a principal, or the system itself."

    @enforce_keys [:kind]
    defstruct [:kind, :subject, :display_name]

    @type t :: %__MODULE__{
            kind: :user | :system | :service,
            subject: String.t() | nil,
            display_name: String.t() | nil
          }

    @spec system() :: t()
    def system, do: %__MODULE__{kind: :system}

    @spec user(String.t(), String.t() | nil) :: t()
    def user(subject, display_name \\ nil) do
      %__MODULE__{kind: :user, subject: subject, display_name: display_name}
    end

    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{kind: :system}), do: %{"kind" => "system"}

    def to_json(%__MODULE__{} = actor) do
      %{"kind" => Atom.to_string(actor.kind), "subject" => actor.subject}
      |> maybe_put("display_name", actor.display_name)
    end

    @spec from_json(map() | nil) :: t()
    def from_json(nil), do: system()

    def from_json(%{"kind" => kind} = json) do
      %__MODULE__{
        kind: String.to_existing_atom(kind),
        subject: Map.get(json, "subject"),
        display_name: Map.get(json, "display_name")
      }
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end

  @enforce_keys [:type, :data]
  defstruct [
    :seq,
    :prev_hash,
    :ts,
    :actor,
    :agent,
    :type,
    :data,
    v: 1,
    ephemeral?: false
  ]

  @type t :: %__MODULE__{
          seq: pos_integer() | nil,
          prev_hash: String.t() | nil,
          ts: String.t() | nil,
          actor: Actor.t() | nil,
          agent: [String.t()] | nil,
          type: String.t(),
          data: map(),
          v: pos_integer(),
          ephemeral?: boolean()
        }

  @doc "An ephemeral event. No seq, never persisted, droppable."
  @spec ephemeral(String.t(), [String.t()] | nil, map()) :: t()
  def ephemeral(type, agent, data) do
    %__MODULE__{type: type, agent: agent, data: data, ephemeral?: true}
  end

  @doc """
  Seal a durable event: assign its sequence, timestamp and `prev_hash`.

  `previous` is the event this one follows, or `nil` at `seq` 1.
  """
  @spec seal(t(), pos_integer(), t() | nil, String.t() | nil) :: t()
  def seal(%__MODULE__{} = event, seq, previous, ts \\ nil) do
    %{
      event
      | seq: seq,
        ts: ts || DateTime.utc_now() |> DateTime.to_iso8601(),
        prev_hash: if(previous, do: hash(previous)),
        ephemeral?: false
    }
  end

  @doc """
  The digest of an event, over its canonical JSON *without* `prev_hash`.

  Excluding `prev_hash` is what lets a verifier recompute the chain: each link is a
  function of the event's own content, not of the link already recorded.
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = event) do
    event |> to_json() |> Map.delete("prev_hash") |> Canonical.hash()
  end

  @doc """
  Walk a chain and report the first `seq` whose `prev_hash` does not match.

  Returns `:ok`, or `{:error, seq, reason}`.
  """
  @spec verify([t()]) :: :ok | {:error, pos_integer(), atom()}
  def verify(events), do: do_verify(events, nil)

  defp do_verify([], _previous), do: :ok

  defp do_verify([event | rest], previous) do
    expected = if previous, do: hash(previous)

    cond do
      event.prev_hash != expected -> {:error, event.seq, :prev_hash_mismatch}
      previous && event.seq != previous.seq + 1 -> {:error, event.seq, :seq_gap}
      true -> do_verify(rest, event)
    end
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{ephemeral?: true} = event) do
    %{"ephemeral" => true, "type" => event.type, "data" => event.data}
    |> maybe_put("agent", event.agent)
  end

  def to_json(%__MODULE__{} = event) do
    %{
      "seq" => event.seq,
      "prev_hash" => event.prev_hash,
      "ts" => event.ts,
      "actor" => Actor.to_json(event.actor || Actor.system()),
      "agent" => event.agent,
      "type" => event.type,
      "v" => event.v,
      "data" => event.data
    }
  end

  @spec from_json(map()) :: t()
  def from_json(%{"ephemeral" => true} = json) do
    %__MODULE__{
      type: json["type"],
      agent: Map.get(json, "agent"),
      data: Map.get(json, "data", %{}),
      ephemeral?: true
    }
  end

  def from_json(json) do
    %__MODULE__{
      seq: json["seq"],
      prev_hash: Map.get(json, "prev_hash"),
      ts: Map.get(json, "ts"),
      actor: Actor.from_json(Map.get(json, "actor")),
      agent: Map.get(json, "agent"),
      type: json["type"],
      v: Map.get(json, "v", 1),
      data: Map.get(json, "data", %{})
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
