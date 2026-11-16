defmodule Troupe.Worker.UserMemory do
  @moduledoc """
  Where `remember` with `level: "me"` sends its entry on a pod (#55): `session.memory.put`
  over the control link, naming the session and nothing about whose memory it is. The plane
  reads the owner off the session row, so a pod adds only to the person whose session it
  holds, only one entry, and only at the person's level: it refuses any other.

  `remember` with `level: "team"` or `"organisation"` proposes instead: `session.memory.propose`,
  which the plane keeps for an administrator to review, for the session's own team where
  it is a team's.

  Installed as `Troupe.UserMemory`'s host when the pod starts, beside the person's
  credentials (`Troupe.Worker.Connections`). A pod whose link is down has nowhere to send it,
  and the agent is told the plane could not be reached.
  """

  alias Troupe.Worker.Plane.Link

  @doc "Install this pod as where an agent's entry for its person's own memory goes."
  @spec install() :: :ok
  def install do
    :ok = Troupe.UserMemory.install(&__MODULE__.append/3)
    Troupe.UserMemory.install_proposer(&__MODULE__.propose/4)
  end

  @doc """
  Send one proposed entry for the session's team's memory or the organisation's (`level`)
  as `session.memory.propose`: the plane reads the team and the person off the session, so
  `opts["team"]` is not sent. The plane's answer, or its refusal in its words.
  """
  @spec propose(String.t(), Troupe.Tool.Ctx.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def propose(entry, ctx, level, opts) do
    params =
      %{"session_id" => ctx.session_id, "scope" => level, "append" => entry, "agent" => agent(ctx)}
      |> then(&if(opts["topic"], do: Map.put(&1, "topic", opts["topic"]), else: &1))

    case request("session.memory.propose", params) do
      {:ok, answer} -> {:ok, Map.take(answer, ~w(id topic team entry state))}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  @doc """
  Send one entry, under `topic` (`nil` for the plane's `Notes`), for the owner of the session
  `ctx` names; the plane's answer or its refusal.
  """
  @spec append(String.t(), Troupe.Tool.Ctx.t(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def append(entry, ctx, topic \\ nil) do
    # The agent is named so the plane keeps who wrote the line; whose memory it is, it reads
    # off the session.
    params =
      %{"session_id" => ctx.session_id, "scope" => "user", "append" => entry, "agent" => agent(ctx)}
      |> then(&if(topic, do: Map.put(&1, "topic", topic), else: &1))

    case request("session.memory.put", params) do
      {:ok, answer} ->
        {:ok, %{"entry" => answer["entry"], "topic" => answer["topic"], "version" => answer["version"]}}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  defp refusal(%Troupe.Protocol.Error{data: data, message: message}), do: reason(data, message)
  defp refusal(%{"data" => %{"reason" => reason}}) when is_binary(reason), do: reason
  defp refusal(%{"message" => message}), do: "the plane refused it (#{message})"
  defp refusal(_reason), do: "the plane could not be reached from this pod; try again later"

  defp agent(%{definition: %{name: name}}) when is_binary(name), do: name
  defp agent(%{agent_path: [_ | _] = path}), do: List.last(path)
  defp agent(_ctx), do: nil

  defp reason(%{"reason" => reason}, _message) when is_binary(reason), do: reason
  defp reason(%{reason: reason}, _message) when is_binary(reason), do: reason
  defp reason(_data, message), do: "the plane refused it (#{message})"

  defp request(method, params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, method, params)
    end
  catch
    :exit, _gone -> {:error, :no_link}
  end
end
