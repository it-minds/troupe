defmodule Troupe.Events do
  @moduledoc """
  Session-scoped pub/sub over a duplicate-key `Registry`. **Internal to core.**

  Clients never touch this: they subscribe through the protocol, and the gateway is
  the only subscriber that matters. Keeping it internal is what makes the rule "if the
  TUI cannot do it through the protocol, nobody can" enforceable — there is no private
  channel for our own clients to take.

  Publishing is a fan-out of `send/2` into subscriber mailboxes and never waits on
  anyone: this is the boundary that keeps a slow or wedged client from applying
  backpressure to an agent. Subscribers receive
  `{:troupe_event, session_id, %Troupe.Protocol.Event{}}`.
  """

  alias Troupe.Protocol.Event

  @registry Troupe.EventsRegistry

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry, partitions: System.schedulers_online())
  end

  @doc """
  Subscribe the calling process to one session's events.

  Idempotent, and it has to be. A connection takes out more than one subscription on the
  same session — `session:<id>` and `presence:<id>`, or the same session at two levels —
  and each of them asks to follow it. Registering twice puts the process in the fan-out
  twice, so every event arrives twice and every subscription writes it twice; and because
  `Registry.unregister/2` removes *all* of a process's entries for a key, dropping one
  subscription would then take the other's delivery with it.

  So the registration is per process and per session rather than per subscription. Which
  subscriptions want an event is `Troupe.Gateway.Session.interested?/3`'s question, and it
  is the only place that should be asking it.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id) do
    if following?(session_id) do
      :ok
    else
      {:ok, _registered} = Registry.register(@registry, session_id, nil)
      :ok
    end
  end

  @doc "Whether the calling process already follows this session."
  @spec following?(String.t()) :: boolean()
  def following?(session_id) do
    @registry
    |> Registry.keys(self())
    |> Enum.member?(session_id)
  end

  @doc "Stop receiving one session's events."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id), do: Registry.unregister(@registry, session_id)

  @doc """
  Fan an event out to every subscriber of a session.

  Always returns `:ok`, including when nobody is listening — an agent must not care
  whether a client exists.
  """
  @spec publish(String.t(), Event.t()) :: :ok
  def publish(session_id, %Event{} = event) do
    message = {:troupe_event, session_id, event}

    Registry.dispatch(@registry, session_id, fn subscribers ->
      Enum.each(subscribers, fn {pid, _} -> send(pid, message) end)
    end)
  end

  @doc "Publish an ephemeral event: no seq, never persisted, droppable under load."
  @spec publish_ephemeral(String.t(), String.t(), [String.t()] | nil, map()) :: :ok
  def publish_ephemeral(session_id, type, agent, data) do
    publish(session_id, Event.ephemeral(type, agent, data))
  end

  @doc "How many processes are subscribed. Test and diagnostics only."
  @spec subscriber_count(String.t()) :: non_neg_integer()
  def subscriber_count(session_id), do: Registry.count_match(@registry, session_id, :_)
end
