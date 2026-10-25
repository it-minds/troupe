defmodule Troupe.Gateway.Artifacts do
  @moduledoc """
  Publishing an artifact on the plane from this machine (#62), as its person, with this
  daemon's sign-in: what `publish_artifact` sends from a session running here (`publish/2`,
  installed as `Troupe.Artifacts`'s host when the daemon starts), and what a client's
  "Publish…" sends (`artifact.publish`, through `put/1`).

  The plane's `artifact.publish` takes it as it is, the session it came from and the agent
  that called the tool named as its provenance. Signed out, there is nowhere to send it, and
  the answer says so; the tool then says where the file is.
  """

  alias Troupe.Gateway.{Memory, Plane}

  @keys ~w(title kind visibility files id session_id agent)

  @doc "Install this daemon as where its sessions' artifacts go."
  @spec install() :: :ok
  def install, do: Troupe.Artifacts.install(&__MODULE__.publish/2)

  @doc "What `publish_artifact` sends from a session here: `put/1`, naming the session and its agent."
  @spec publish(map(), Troupe.Tool.Ctx.t()) :: {:ok, map()} | {:error, :signed_out | String.t()}
  def publish(params, ctx) do
    params
    |> Map.put("session_id", ctx.session_id)
    |> Map.put("agent", agent(ctx))
    |> put()
    |> case do
      {:ok, artifact} -> {:ok, artifact}
      {:error, :signed_out} -> {:error, :signed_out}
      {:error, reason} -> {:error, Memory.sentence(reason)}
    end
  end

  @doc "Publish `params` on the linked plane as this daemon's person: the plane's answer."
  @spec put(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def put(params) do
    with url when is_binary(url) <- Plane.url(),
         true <- Plane.linked?(),
         {:ok, artifact} <- Plane.call("artifact.publish", Map.take(params, @keys)) do
      {:ok, Map.put(artifact, "plane_url", url)}
    else
      {:error, :unlinked} -> {:error, :signed_out}
      {:error, reason} -> {:error, reason}
      _signed_out -> {:error, :signed_out}
    end
  end

  defp agent(%{definition: %{name: name}}) when is_binary(name), do: "agent:" <> name
  defp agent(%{agent_path: [_ | _] = path}), do: "agent:" <> List.last(path)
  defp agent(_ctx), do: nil
end
