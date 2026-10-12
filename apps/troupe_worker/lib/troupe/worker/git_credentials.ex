defmodule Troupe.Worker.GitCredentials do
  @moduledoc """
  A session's GitHub installation token, for the git the pod runs for that session.

  The plane mints it with the plane's GitHub App, narrowed to the one repository the
  session was created with, and answers it over the control channel (`git.credential`)
  only for a session this pod holds. It is the session's the way a person's key-manager
  token is (`Troupe.Worker.Connections`): asked for when it is needed, held in this pod's
  memory for the activation, never on disk, never in the session's environment, its
  workspace or its log.

  ## Where it goes, and where it does not

  To the git the pod runs for the session itself, outside the agent's reach: the clone on
  the first activation (`Troupe.Worker.Session.Clone`), and in a later slice the push.
  That git is given the token in its own environment and a credential helper scoped to the
  one Git host, on its command line; the workspace's `.git/config` names the remote and
  no credential. The agent's `shell` never has it: not in its environment, not in a file,
  not through a helper it could call, which is why no tool's output can carry it.

  ## For how long

  A token lives an hour. One held here is handed out until five minutes before it runs
  out, and the next caller gets a new one; an activation starts with none, so a session
  activated again gets a new token rather than the last activation's; and the session's
  going away takes it (`forget/1`). Losing the table costs a round trip to the plane.
  """

  use GenServer

  alias Troupe.Worker.Plane.Link

  @table __MODULE__

  # Handed out until this close to the end, so a clone that starts with it finishes with it.
  @margin_seconds 300

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The session's credential: `%{"token", "expires_at", "url", "host", "username", "ref",
  "repository"}`, held or asked for. `{:error, reason}` names what the plane said, without
  a token in it: there is none to name.
  """
  @spec credential(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def credential(session_id, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    case lookup(session_id) do
      {:ok, %{"expires_at" => expires_at} = held} ->
        if usable?(expires_at, now), do: {:ok, held}, else: ask(session_id, opts)

      :none ->
        ask(session_id, opts)
    end
  end

  @doc "Drop a session's token: its activation starts, or the session has gone."
  @spec forget(String.t()) :: :ok
  def forget(session_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, session_id)
    :ok
  end

  @doc "Which sessions hold one, for tests. Never the tokens."
  @spec sessions() :: [String.t()]
  def sessions do
    case :ets.whereis(@table) do
      :undefined -> []
      _table -> @table |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe git credentials")
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  # -- asking the plane -------------------------------------------------------

  defp lookup(session_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :none

      _table ->
        case :ets.lookup(@table, session_id) do
          [{^session_id, held}] -> {:ok, held}
          [] -> :none
        end
    end
  end

  defp ask(session_id, opts) do
    link = Keyword.get(opts, :link, Link)

    case Link.request(link, "git.credential", %{"session_id" => session_id}) do
      {:ok, %{"token" => token} = credential} when is_binary(token) ->
        if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {session_id, credential})
        {:ok, credential}

      {:ok, _other} ->
        {:error, :no_token}

      {:error, %Troupe.Protocol.Error{} = error} ->
        {:error, {:refused, error.message, reason_of(error.data)}}

      {:error, %{"message" => message} = error} ->
        {:error, {:refused, message, reason_of(error["data"])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reason_of(%{"reason" => reason}), do: reason
  defp reason_of(%{reason: reason}), do: reason
  defp reason_of(_data), do: nil

  defp usable?(expires_at, now) do
    case DateTime.from_iso8601(to_string(expires_at)) do
      {:ok, at, _offset} -> DateTime.to_unix(at) - now > @margin_seconds
      _unreadable -> false
    end
  end
end
