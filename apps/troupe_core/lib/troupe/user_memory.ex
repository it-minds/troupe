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

  What is sent is one entry and its topic, never a document: the plane puts it at the end of
  the topic's `## <topic>` section, making the section where there is none, and nothing an
  agent sends replaces a word of it.
  """

  alias Troupe.Session
  alias Troupe.Session.Log

  @typedoc "What the plane did with the entry: the entry as kept, its topic, and the version now in force."
  @type saved :: %{String.t() => term()}

  @typedoc "Where an entry goes: the entry, the session's context, and the topic it is under."
  @type host :: (String.t(), Troupe.Tool.Ctx.t(), String.t() | nil -> {:ok, saved()} | {:error, term()})

  @doc """
  Add `entry` under `topic` (`nil` for the plane's default, `Notes`) to the session's person's
  own memory on the plane. `{:error, :signed_out}` where this host has no plane to send it
  to; `{:error, sentence}` where the plane refused it.
  """
  @spec append(String.t(), Troupe.Tool.Ctx.t(), String.t() | nil) ::
          {:ok, saved()} | {:error, :signed_out | String.t()}
  def append(entry, ctx, topic \\ nil) when is_binary(entry) do
    case Application.get_env(:troupe_core, :user_memory) do
      fun when is_function(fun, 3) -> fun.(entry, ctx, topic)
      # A host from before topics takes the entry alone.
      fun when is_function(fun, 2) -> fun.(entry, ctx)
      _none -> {:error, :signed_out}
    end
  end

  @typedoc """
  Where a proposal goes: the entry, the session's context, the level (`"team"` or
  `"organisation"`) and `%{"topic" => ..., "team" => ...}`, either `nil`.
  """
  @type proposer :: (String.t(), Troupe.Tool.Ctx.t(), String.t(), map() -> {:ok, map()} | {:error, term()})

  @doc """
  Propose `entry` for a team's memory or the organisation's (`level`), for an administrator
  to accept or decline: the plane keeps it and writes it into no document. `opts` is
  `%{"topic" => ..., "team" => ...}`. `{:error, :signed_out}` where this host has no plane to
  send it to; `{:error, sentence}` where the plane refused it. Answers what the plane kept:
  the proposal's `id`, `topic`, `team` and `state`.
  """
  @spec propose(String.t(), Troupe.Tool.Ctx.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :signed_out | String.t()}
  def propose(entry, ctx, level, opts \\ %{}) when is_binary(entry) and level in ~w(team organisation) do
    case Application.get_env(:troupe_core, :memory_proposal) do
      fun when is_function(fun, 4) -> fun.(entry, ctx, level, opts)
      _none -> {:error, :signed_out}
    end
  end

  @doc """
  Tell a running session what became of a proposal one of its agents made: `message`, the
  plane's sentence, as a `config_note` under its root (key `memory_proposals`, `proposal`
  its id), once: a session whose log says it already is told nothing again, so a poll that
  hears the same decision twice writes one line. `{:error, :not_running}` for a session not
  running here.
  """
  @spec decided(String.t(), String.t(), String.t()) :: :ok | {:error, :not_running}
  def decided(session_id, proposal, message)
      when is_binary(session_id) and is_binary(proposal) and is_binary(message) do
    said? =
      session_id
      |> Log.replay()
      |> Enum.any?(&(&1.type == "config_note" and &1.data["proposal"] == proposal))

    unless said? do
      {:ok, _seq} =
        Log.append(session_id, Session.root_path(), :config_note, %{
          "key" => "memory_proposals",
          "message" => message,
          "proposal" => proposal
        })
    end

    :ok
  catch
    :exit, _not_running -> {:error, :not_running}
  end

  @doc "Whether this host installed somewhere for a proposal to go."
  @spec proposes?() :: boolean()
  def proposes?, do: is_function(Application.get_env(:troupe_core, :memory_proposal), 4)

  @doc "Install `fun` as where proposals go, for the host that can reach the plane."
  @spec install_proposer(proposer()) :: :ok
  def install_proposer(fun) when is_function(fun, 4),
    do: Application.put_env(:troupe_core, :memory_proposal, fun)

  @doc "Whether this host installed somewhere for an entry to go."
  @spec reachable?() :: boolean()
  def reachable? do
    fun = Application.get_env(:troupe_core, :user_memory)
    is_function(fun, 3) or is_function(fun, 2)
  end

  @doc "Install `fun` as where entries go, for the host that can reach the plane."
  @spec install(host() | (String.t(), Troupe.Tool.Ctx.t() -> {:ok, saved()} | {:error, term()})) :: :ok
  def install(fun) when is_function(fun, 3) or is_function(fun, 2),
    do: Application.put_env(:troupe_core, :user_memory, fun)
end
