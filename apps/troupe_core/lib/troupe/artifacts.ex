defmodule Troupe.Artifacts do
  @moduledoc """
  Where `publish_artifact` sends what it publishes (#62): the plane, as an artifact of the
  session's person, at an address on the plane's artifacts host.

  A function the host installs, as `Troupe.UserMemory`'s is, because reaching the plane is
  not `troupe_core`'s to know: a laptop's daemon sends it as `artifact.publish` with its
  person's sign-in, and a pod as `session.artifact.publish` over its control link, where the
  plane reads whose it is off the session. Installing it is also what gives a session the
  tool: a host that installs nothing (a test's, the offline bench's) offers no tool that
  could only be refused. A host with no sign-in says so, and the agent says where the file is.

  What is sent is the artifact: its title, kind, visibility and files, each `{path,
  content_type, bytes}` with the bytes in base64, and `id` to republish one.
  """

  @typedoc "The plane's answer: the artifact as it now stands, its `url` and `version` among it."
  @type published :: %{String.t() => term()}

  @doc """
  Publish `params` for the session's person. `{:error, :signed_out}` where this host has no
  plane to send it to; `{:error, sentence}` where the plane refused it.
  """
  @spec publish(map(), Troupe.Tool.Ctx.t()) ::
          {:ok, published()} | {:error, :signed_out | String.t()}
  def publish(params, ctx) when is_map(params) do
    case Application.get_env(:troupe_core, :artifacts) do
      fun when is_function(fun, 2) -> fun.(params, ctx)
      _none -> {:error, :signed_out}
    end
  end

  @doc "Whether this host installed somewhere for an artifact to go."
  @spec reachable?() :: boolean()
  def reachable?, do: is_function(Application.get_env(:troupe_core, :artifacts), 2)

  @doc """
  Install `fun` as where artifacts go, for the host that can reach the plane, and give its
  sessions `publish_artifact`.
  """
  @spec install((map(), Troupe.Tool.Ctx.t() -> {:ok, published()} | {:error, term()})) :: :ok
  def install(fun) when is_function(fun, 2) do
    Application.put_env(:troupe_core, :artifacts, fun)
    tools = Application.get_env(:troupe_core, :extra_tools, [])

    unless Troupe.Tools.PublishArtifact in tools,
      do: Application.put_env(:troupe_core, :extra_tools, tools ++ [Troupe.Tools.PublishArtifact])

    :ok
  end

  @doc "Take the host away again, and the tool with it: for a test that installed one."
  @spec uninstall() :: :ok
  def uninstall do
    Application.delete_env(:troupe_core, :artifacts)

    Application.put_env(
      :troupe_core,
      :extra_tools,
      List.delete(
        Application.get_env(:troupe_core, :extra_tools, []),
        Troupe.Tools.PublishArtifact
      )
    )
  end
end
