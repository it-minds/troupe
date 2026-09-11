defmodule Troupe.Gateway.Presence do
  @moduledoc """
  Who is looking, and what they are doing — never written down.

  Joining, leaving, focusing an agent and typing are all the same kind of fact: true
  for as long as somebody is there, worthless a minute later, and worse than worthless
  in a log that a session replays forever. So presence goes out through
  `Troupe.Events.publish_ephemeral/4` and through nothing else.

  That is the whole enforcement, and it is structural rather than a filter: this module
  has no path to `Session.Log`, so there is no code here that could be changed to put
  presence in the log by accident. The spec forbids it; the shape of the call makes it
  impossible rather than discouraged.
  """

  @typedoc "`joined` and `left` are the connection's business; the rest are the client's."
  @type state :: String.t()

  @doc "Tell everyone attached to a session that somebody is there, or is not."
  @spec publish(String.t(), map() | nil, state(), [String.t()] | nil) :: :ok
  def publish(session_id, principal, presence_state, agent \\ nil) do
    data =
      %{"subject" => subject(principal), "state" => presence_state}
      |> put_unless_nil("display_name", principal && principal["display_name"])
      |> put_unless_nil("agent", agent)

    Troupe.Events.publish_ephemeral(session_id, "presence", agent, data)
  end

  defp subject(%{"subject" => subject}) when is_binary(subject), do: subject
  defp subject(_principal), do: "anonymous"

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
