defmodule Troupe.Worker.UserMemory do
  @moduledoc """
  Where `remember` with `level: "me"` sends its entry on a pod (#55): `session.memory.put`
  over the control link, naming the session and nothing about whose memory it is. The plane
  reads the owner off the session row, so a pod adds only to the person whose session it
  holds, only one entry, and only at the person's level: it refuses any other.

  Installed as `Troupe.UserMemory`'s host when the pod starts, beside the person's
  credentials (`Troupe.Worker.Connections`). A pod whose link is down has nowhere to send it,
  and the agent is told the plane could not be reached.
  """

  alias Troupe.Worker.Plane.Link

  @doc "Install this pod as where an agent's entry for its person's own memory goes."
  @spec install() :: :ok
  def install, do: Troupe.UserMemory.install(&__MODULE__.append/2)

  @doc "Send one entry for the owner of the session `ctx` names; the plane's answer or its refusal."
  @spec append(String.t(), Troupe.Tool.Ctx.t()) :: {:ok, map()} | {:error, String.t()}
  def append(entry, ctx) do
    params = %{"session_id" => ctx.session_id, "scope" => "user", "append" => entry}

    case request(params) do
      {:ok, answer} ->
        {:ok, %{"entry" => answer["entry"], "version" => answer["version"]}}

      {:error, %Troupe.Protocol.Error{data: data, message: message}} ->
        {:error, reason(data, message)}

      {:error, %{"data" => %{"reason" => reason}}} when is_binary(reason) ->
        {:error, reason}

      {:error, %{"message" => message}} ->
        {:error, "the plane refused it (#{message})"}

      {:error, _reason} ->
        {:error, "the plane could not be reached from this pod; try again later"}
    end
  end

  defp reason(%{"reason" => reason}, _message) when is_binary(reason), do: reason
  defp reason(%{reason: reason}, _message) when is_binary(reason), do: reason
  defp reason(_data, message), do: "the plane refused it (#{message})"

  defp request(params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, "session.memory.put", params)
    end
  catch
    :exit, _gone -> {:error, :no_link}
  end
end
