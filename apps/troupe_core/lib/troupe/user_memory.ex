defmodule Troupe.UserMemory do
  @moduledoc """
  Where `remember` with `level: "me"` sends an entry (#55): the person's own memory on the
  plane, the one level of it an agent may write.

  A function the host installs, as `Troupe.MCP`'s person credential is, because reaching the
  plane is not `troupe_core`'s to know: a laptop's daemon sends it as `me.memory.put` with its
  person's sign-in, and a pod as `session.memory.put` over its control link, where the plane
  reads whose memory it is off the session. A host that installs nothing, or one with no
  sign-in, has nowhere to send it, and says so, so the agent can offer the repository's
  memory instead.

  What is sent is one entry, never a document: the plane puts it under the day's heading,
  below what is there, and nothing an agent sends replaces a word of it.
  """

  @typedoc "What the plane did with the entry: the entry as kept, and the version now in force."
  @type saved :: %{String.t() => term()}

  @doc """
  Add `entry` to the session's person's own memory on the plane. `{:error, :signed_out}` where
  this host has no plane to send it to; `{:error, sentence}` where the plane refused it.
  """
  @spec append(String.t(), Troupe.Tool.Ctx.t()) ::
          {:ok, saved()} | {:error, :signed_out | String.t()}
  def append(entry, ctx) when is_binary(entry) do
    case Application.get_env(:troupe_core, :user_memory) do
      fun when is_function(fun, 2) -> fun.(entry, ctx)
      _none -> {:error, :signed_out}
    end
  end

  @doc "Whether this host installed somewhere for an entry to go."
  @spec reachable?() :: boolean()
  def reachable?, do: is_function(Application.get_env(:troupe_core, :user_memory), 2)

  @doc "Install `fun` as where entries go, for the host that can reach the plane."
  @spec install((String.t(), Troupe.Tool.Ctx.t() -> {:ok, saved()} | {:error, term()})) :: :ok
  def install(fun) when is_function(fun, 2),
    do: Application.put_env(:troupe_core, :user_memory, fun)
end
