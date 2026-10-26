defmodule Troupe.Worker.Artifacts do
  @moduledoc """
  Where `publish_artifact` sends what it publishes on a pod (#62): `session.artifact.publish`
  over the control link, naming the session and the agent and nothing about whose it is. The
  plane reads the owner off the session row, so a pod publishes only for the person whose
  session it holds, counted against the session's team.

  Installed as `Troupe.Artifacts`'s host when the pod starts, beside the person's own memory
  (`Troupe.Worker.Connections`). A pod whose link is down has nowhere to send it, and the
  agent is told the plane could not be reached.
  """

  alias Troupe.Worker.Plane.Link

  @doc "Install this pod as where its sessions' artifacts go."
  @spec install() :: :ok
  def install, do: Troupe.Artifacts.install(&__MODULE__.publish/2)

  @doc "Send the artifact for the owner of the session `ctx` names; the plane's answer or its refusal."
  @spec publish(map(), Troupe.Tool.Ctx.t()) :: {:ok, map()} | {:error, String.t()}
  def publish(params, ctx) do
    params =
      params
      |> Map.take(~w(title kind visibility files id note))
      |> Map.put("session_id", ctx.session_id)
      |> put_agent(ctx)

    case request(params) do
      {:ok, artifact} ->
        {:ok, artifact}

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

  defp put_agent(params, %{definition: %{name: name}}) when is_binary(name),
    do: Map.put(params, "agent", "agent:" <> name)

  defp put_agent(params, %{agent_path: [_ | _] = path}),
    do: Map.put(params, "agent", "agent:" <> List.last(path))

  defp put_agent(params, _ctx), do: params

  defp reason(%{"reason" => reason}, _message) when is_binary(reason), do: reason
  defp reason(%{reason: reason}, _message) when is_binary(reason), do: reason
  defp reason(_data, message), do: "the plane refused it (#{message})"

  defp request(params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, "session.artifact.publish", params)
    end
  catch
    :exit, _gone -> {:error, :no_link}
  end
end
