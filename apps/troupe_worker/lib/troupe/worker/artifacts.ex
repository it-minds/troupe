defmodule Troupe.Worker.Artifacts do
  @moduledoc """
  Where `publish_artifact` sends what it publishes on a pod (#62): `session.artifact.publish`
  over the control link, naming the session and the agent and nothing about whose it is. The
  plane reads the owner off the session row, so a pod publishes only for the person whose
  session it holds, counted against the session's team. Files past what one message carries
  comfortably go to the object store first, by a handle `session.artifact.upload.begin` gives
  for the session's owner, as a daemon's go by `artifact.upload.begin`
  (`Troupe.Gateway.Artifacts.carried/2`): the pod reaches the store as it does to seal.

  Installed as `Troupe.Artifacts`'s host when the pod starts, beside the person's own memory
  (`Troupe.Worker.Connections`). A pod whose link is down has nowhere to send it, and the
  agent is told the plane could not be reached.
  """

  alias Troupe.Worker.Plane.Link

  @doc "Install this pod as where its sessions' artifacts go."
  @spec install() :: :ok
  def install do
    :ok = Troupe.Artifacts.install_files(&__MODULE__.files/1)
    Troupe.Artifacts.install(&__MODULE__.publish/2)
  end

  @doc """
  The files of one of a person's artifacts for a session on this pod (`fs.upload` with
  `artifact`, #920): `session.artifact.files` over the control link, naming the session and
  who asked. The plane reads the artifact as that person, only for someone who steers the
  session, and the bytes come down to this pod without passing through the person's client.
  """
  @spec files(map()) :: {:ok, map()} | {:error, term()}
  def files(ask) do
    params =
      %{
        "session_id" => ask["session_id"],
        "subject" => ask["subject"],
        "artifact" => ask["artifact"],
        "version" => ask["version"],
        "path" => ask["file"]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case request("session.artifact.files", params) do
      {:ok, answer} -> {:ok, answer}
      {:error, :no_link} -> {:error, "the plane could not be reached from this pod; try again later"}
      {:error, refused} -> {:error, refused}
    end
  end

  @doc "Send the artifact for the owner of the session `ctx` names; the plane's answer or its refusal."
  @spec publish(map(), Troupe.Tool.Ctx.t()) :: {:ok, map()} | {:error, String.t()}
  def publish(params, ctx) do
    params =
      params
      |> Map.take(~w(title kind visibility owner files id note))
      |> Troupe.Gateway.Artifacts.own_only_new()
      |> Map.put("session_id", ctx.session_id)
      |> put_agent(ctx)

    # Past what one message of the link carries comfortably, the files go to the object store
    # by a handle the plane gives for the session's owner, as a daemon's do.
    begin =
      &request("session.artifact.upload.begin", %{"session_id" => ctx.session_id, "files" => &1})

    sent =
      with {:ok, params} <- Troupe.Gateway.Artifacts.carried(params, begin),
           do: request("session.artifact.publish", params)

    case sent do
      {:ok, artifact} ->
        {:ok, artifact}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

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

  defp request(method, params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, method, params)
    end
  catch
    :exit, _gone -> {:error, :no_link}
  end
end
