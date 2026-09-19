defmodule Troupe.Client.Events do
  @moduledoc """
  Pub/sub fan-out for session events, backed by a duplicate-key Registry.
  Subscribers receive `{:troupe_event, %Troupe.Event{}}`.
  """

  alias Troupe.Event

  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id) when is_binary(session_id) do
    case Registry.register(__MODULE__, session_id, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) do
    Registry.unregister(__MODULE__, session_id)
  end

  @spec publish(Event.t()) :: :ok
  def publish(%Event{session_id: session_id} = event) do
    Registry.dispatch(__MODULE__, session_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:troupe_event, event})
    end)
  end

  @doc "Publishes a transient event (not persisted)."
  @spec notify(String.t(), String.t(), atom(), map()) :: :ok
  def notify(session_id, agent_path, type, data) do
    publish(Event.transient(session_id, agent_path, type, data))
  end
end
