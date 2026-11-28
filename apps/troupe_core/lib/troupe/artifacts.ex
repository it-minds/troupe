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

  What is sent is the artifact: its title, kind, visibility, teams and files, each `{path,
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
  Whether `publish_artifact` can publish from this session now, as the harness tells its
  agent where a file goes: `:none` where this host installed nowhere for one to go,
  `{:closed, why}` for a session under Local only or a host that is not signed in to a plane
  (the host's `ready` says), else `:open`. Whether the plane takes artifacts at all is the
  plane's to say when one is sent.
  """
  @spec ready(String.t() | nil) :: :open | :none | {:closed, String.t()}
  def ready(session_id) do
    cond do
      not reachable?() -> :none
      Troupe.LocalOnly.session?(session_id) -> {:closed, "this session is under Local only"}
      not signed_in?(session_id) -> {:closed, "the person is not signed in to a plane here"}
      true -> :open
    end
  end

  defp signed_in?(session_id) do
    case Application.get_env(:troupe_core, :artifacts_ready) do
      fun when is_function(fun, 1) -> fun.(session_id) == true
      _none -> true
    end
  end

  @doc """
  Install `fun` as where artifacts go, for the host that can reach the plane, and give its
  sessions `publish_artifact`. `ready:` is how the host says whether a session can publish
  now (signed in to a plane); without one it always can, as a pod's session can.
  """
  @spec install((map(), Troupe.Tool.Ctx.t() -> {:ok, published()} | {:error, term()}), keyword()) ::
          :ok
  def install(fun, opts \\ []) when is_function(fun, 2) do
    case Keyword.get(opts, :ready) do
      ready when is_function(ready, 1) -> Application.put_env(:troupe_core, :artifacts_ready, ready)
      nil -> Application.delete_env(:troupe_core, :artifacts_ready)
    end

    Application.put_env(:troupe_core, :artifacts, fun)
    tools = Application.get_env(:troupe_core, :extra_tools, [])

    unless Troupe.Tools.PublishArtifact in tools,
      do: Application.put_env(:troupe_core, :extra_tools, tools ++ [Troupe.Tools.PublishArtifact])

    :ok
  end

  @doc """
  The files of one of the person's artifacts, for a session's workspace (#920): what
  `fs.upload` with `artifact` writes there. `ask` names `session_id`, `subject` (who asked),
  `artifact`, and `version` and `file` where given. Through the host, as `publish/2` is: a
  laptop's daemon asks the plane's `artifact.files` with its person's sign-in, a pod asks
  `session.artifact.files` over its control link for the person who asked. The answer is the
  plane's, `{id, title, version, files}`, each file `{path, content_type, bytes}` in base64.
  `{:error, :signed_out}` where this host has nowhere to ask.
  """
  @spec files(map()) :: {:ok, map()} | {:error, term()}
  def files(ask) when is_map(ask) do
    case Application.get_env(:troupe_core, :artifact_files) do
      fun when is_function(fun, 1) -> fun.(ask)
      _none -> {:error, :signed_out}
    end
  end

  @doc """
  What the plane says of a publication before the person is asked about it, for the gate
  (`Troupe.Tools.PublishArtifact.publication/2`): `ask` is `{id}` for a new version of one,
  `{}` for a new one. The answer is the plane's: `access`, who reads that one now in words,
  and for a new one `teams`, the teams it would be given by default. Through the host, as
  `publish/2` is; `{:error, :signed_out}` where this host installed no way to ask.
  """
  @spec about(map(), Troupe.Tool.Ctx.t() | map()) :: {:ok, map()} | {:error, term()}
  def about(ask, ctx) when is_map(ask) do
    case Application.get_env(:troupe_core, :artifact_about) do
      fun when is_function(fun, 2) -> fun.(ask, ctx)
      _none -> {:error, :signed_out}
    end
  end

  @doc "Install `fun` as where `about/2` asks."
  @spec install_about((map(), Troupe.Tool.Ctx.t() -> {:ok, map()} | {:error, term()})) :: :ok
  def install_about(fun) when is_function(fun, 2),
    do: Application.put_env(:troupe_core, :artifact_about, fun)

  @doc "Install `fun` as where `files/1` asks."
  @spec install_files((map() -> {:ok, map()} | {:error, term()})) :: :ok
  def install_files(fun) when is_function(fun, 1),
    do: Application.put_env(:troupe_core, :artifact_files, fun)

  @doc "Take the host away again, and the tool with it: for a test that installed one."
  @spec uninstall() :: :ok
  def uninstall do
    Application.delete_env(:troupe_core, :artifacts)
    Application.delete_env(:troupe_core, :artifacts_ready)
    Application.delete_env(:troupe_core, :artifact_files)
    Application.delete_env(:troupe_core, :artifact_about)

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
