defmodule Troupe.Protocol.Origin do
  @moduledoc """
  What started a session, in one shape, so that seven ways of starting one read alike.

  A cron minute, an executor's webhook, a custom integration, a CI job, an API call, a
  person's "run now" and an agent starting a sibling used to differ in the log by more
  than they differed in fact. Each produced a session, and a reader comparing two of them
  had to know which path had written which fields.

  The plane writes this block into `session.create`'s `origin`; the worker turns it into
  the durable `trigger_fired` event on the new session's log. Both halves live here so
  that adding a field is one edit rather than two that can disagree.

  ## Why the payload is a digest, and why it is optional in the event

  `payload_digest` is a hash and never a payload. A webhook body is content, and content
  belongs in the session's workspace where the retention policy reaches it — not in a
  durable event that outlives the session, and not in a row an administrator lists. The
  digest is enough to answer the only question a log needs to: whether two firings
  carried the same thing. It is optional in the event for the same reason `revision` is:
  a session started before there was a digest has none, and writing one would be
  inventing a hash of a payload nobody kept.

  ## Why `revision` is optional

  `revision` names the trigger document, frozen and content-addressed, that decided what
  the run *is*. A session started through the A2A facade has no such document — the
  caller is an agent that is not ours, with its own card — so the field is absent rather
  than filled with something that is not a revision. Absent means there was no document,
  which is a fact worth being able to read.
  """

  alias Troupe.Protocol.Principal

  @sources ~w(schedule webhook integration ci api manual agent)

  @doc "Every way a session can be started by something other than a person at a keyboard."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  A person at a keyboard, optionally naming the device they are at.

  The one origin with no `source`: nothing fired it, somebody typed.
  """
  @spec user(String.t() | nil) :: map()
  def user(device \\ nil), do: put_present(%{"kind" => "user"}, "device", device)

  @doc """
  A trigger firing: the name, how the firing arrived, and what decided it.

  `:source`, `:idempotency_key`, `:payload_digest` and `:principal` are required, because
  a firing missing any of them is a firing a reader cannot place. `:revision` is required
  here even though the event allows its absence — a trigger always has a document.
  """
  @spec trigger(String.t(), keyword()) :: map()
  def trigger(name, opts) do
    %{
      "kind" => "trigger",
      "trigger" => name,
      "source" => Keyword.fetch!(opts, :source),
      "idempotency_key" => Keyword.fetch!(opts, :idempotency_key),
      "revision" => Keyword.fetch!(opts, :revision),
      "payload_digest" => Keyword.fetch!(opts, :payload_digest),
      "principal" => Principal.to_json(Keyword.fetch!(opts, :principal))
    }
  end

  @doc """
  An agent that is not ours, through the A2A facade: `integration`.

  `caller` is the external agent's subject and `task` the A2A task id, which is also the
  idempotency key — the facade already refuses a duplicate task, so the two are the same
  fact and are written once.
  """
  @spec integration(keyword()) :: map()
  def integration(opts) do
    %{
      "kind" => "a2a",
      "source" => "integration",
      "caller" => Keyword.fetch!(opts, :caller),
      "task" => Keyword.fetch!(opts, :task),
      "idempotency_key" => Keyword.fetch!(opts, :task),
      "payload_digest" => Keyword.fetch!(opts, :payload_digest),
      "principal" => Principal.to_json(Keyword.fetch!(opts, :principal))
    }
  end

  @doc """
  An agent already inside the system, starting a sibling: `agent`.

  `parent` is the session that asked. The key is derived from both ids rather than
  supplied, because a spawn has no natural idempotency key — nobody is retrying it
  blindly — and a key that named only the parent would make every sibling look like a
  replay of the first.
  """
  @spec agent(keyword()) :: map()
  def agent(opts) do
    parent = Keyword.fetch!(opts, :parent)
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      "kind" => "agent",
      "source" => "agent",
      "parent" => parent,
      "idempotency_key" => "spawn:#{parent}:#{session_id}",
      "payload_digest" => Keyword.fetch!(opts, :payload_digest),
      "principal" => Principal.to_json(Keyword.fetch!(opts, :principal))
    }
  end

  @doc "How the firing arrived, or `nil` where a person started it."
  @spec source(map() | nil) :: String.t() | nil
  def source(%{"source" => source}) when source in @sources, do: source
  def source(_origin), do: nil

  @doc """
  The `trigger_fired` data for this origin, or `nil` where nothing fired it.

  Tolerant of what was written before there were seven sources: a trigger origin from
  then names its run under `run` and carries no digest, and what it does have is read
  rather than being dropped on the floor. What such an origin does not have is left out,
  never guessed — a digest invented here would be a hash of nothing that read as a hash
  of the payload.
  """
  @spec fired(map() | nil) :: map() | nil
  def fired(origin) when is_map(origin) do
    case {source(origin), key_of(origin)} do
      {nil, _key} -> nil
      {_source, nil} -> nil
      {source, key} -> fired_data(origin, source, key)
    end
  end

  def fired(_origin), do: nil

  defp fired_data(origin, source, key) do
    %{
      "source" => source,
      "idempotency_key" => key,
      "principal" => Principal.to_json(principal_of(origin))
    }
    |> put_present("revision", origin["revision"])
    |> put_present("payload_digest", origin["payload_digest"])
  end

  # A firing whose principal was never written stands for whoever the session belongs to,
  # which the worker fills in from `session_created`'s owner. `"unknown"` here rather than
  # a missing key: the pair is the one field of this event that is never absent.
  defp principal_of(origin) do
    Principal.from_json(origin["principal"]) || Principal.of("unknown")
  end

  defp key_of(origin), do: origin["idempotency_key"] || origin["run"]

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
