defmodule Troupe.Worker.GitCredentials do
  @moduledoc """
  A session's GitHub installation token, for the git the pod runs for that session.

  The plane mints it with the plane's GitHub App, narrowed to the one repository the
  session was created with, and answers it over the control channel (`git.credential`)
  only for a session this pod holds. It is the session's the way a person's key-manager
  token is (`Troupe.Worker.Connections`): asked for when it is needed, held in this pod's
  memory for the activation, never on disk, never in the session's environment, its
  workspace or its log.

  ## Two of them: the clone's and the fix loop's

  `access: :read`, the default, is the clone's: `contents: read`. `access: :write` is the
  fix loop's: what the session's worker profile grants, which the plane reads from the
  profile and the pod cannot widen. Each is held apart, so the clone's git is never given
  a token that could write.

  ## Where it goes, and where it does not

  To the pod's own work for the session, outside the agent's reach: the git of the clone
  on the first activation (`Troupe.Worker.Session.Clone`), given the token in its own
  environment and a credential helper scoped to the one Git host on its command line; and
  the fix loop's calls to GitHub's API (`Troupe.Worker.GitHub`), made from this VM with
  the token in a request header. The workspace's `.git/config` names the remote and no
  credential. The agent's `shell` never has it: not in its environment, not in a file,
  not through a helper it could call, which is why no tool's output can carry it.

  ## For how long

  A token lives an hour. One held here is handed out until five minutes before it runs
  out, and the next caller gets a new one; an activation starts with none, so a session
  activated again gets a new token rather than the last activation's; and the session's
  going dormant or stopping takes it and revokes it at GitHub (`forget/2`), so no token
  outlives the activation it was minted for. Losing the table costs a round trip to the
  plane.
  """

  use GenServer

  alias Troupe.Worker.GitHub.API
  alias Troupe.Worker.Plane.Link

  require Logger

  @table __MODULE__

  # Handed out until this close to the end, so a clone that starts with it finishes with it.
  @margin_seconds 300

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The session's credential: `%{"token", "expires_at", "url", "host", "username", "ref",
  "repository", "permissions"}`, and for `access: :write` the `"api_url"` too, held or
  asked for. `{:error, reason}` names what the plane said, without a token in it: there
  is none to name.
  """
  @spec credential(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def credential(session_id, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    access = Keyword.get(opts, :access, :read)

    case lookup({session_id, access}) do
      {:ok, %{"expires_at" => expires_at} = held} ->
        if usable?(expires_at, now), do: {:ok, held}, else: ask(session_id, access, opts)

      :none ->
        ask(session_id, access, opts)
    end
  end

  @doc """
  Drop a session's tokens, and revoke them at GitHub: its activation starts, or the
  session has gone dormant or stopped. `access:` drops only that one, which is how the fix
  loop gives up a token whose permissions the plane has narrowed since.

  A dropped token is revoked rather than left to run out its hour: each is sent to
  GitHub's `DELETE /installation/token` at the API URL the plane put in it, after this
  returns and out of the caller's way. One GitHub cannot be reached for (a profile that
  declares the Git host and not the API's, for a clone-only session) is said in the log
  by session and expiry, never by token, and runs out on its own.
  """
  @spec forget(String.t(), keyword()) :: :ok
  def forget(session_id, opts \\ []) do
    if :ets.whereis(@table) != :undefined do
      dropped =
        case Keyword.fetch(opts, :access) do
          {:ok, access} ->
            :ets.take(@table, {session_id, access})

          :error ->
            held = :ets.match_object(@table, {{session_id, :_}, :_})
            :ets.match_delete(@table, {{session_id, :_}, :_})
            held
        end

      revoke(session_id, dropped)
    end

    :ok
  end

  defp revoke(_session_id, []), do: :ok

  defp revoke(session_id, dropped) do
    now = System.system_time(:second)

    live =
      for {{_id, access}, held} <- dropped,
          unexpired?(held["expires_at"], now),
          do: {access, held}

    if live != [], do: {:ok, _pid} = Task.start(fn -> revoke_all(session_id, live) end)
    :ok
  end

  defp revoke_all(session_id, live) do
    Process.set_label("troupe git credentials revoke")
    Enum.each(live, fn {access, held} -> revoke_one(session_id, access, held) end)
  end

  defp revoke_one(session_id, access, held) do
    case API.revoke(held) do
      :ok ->
        Logger.info("troupe worker: revoked #{session_id}'s #{access} GitHub token at GitHub")

      {:error, reason} ->
        Logger.info(
          "troupe worker: could not revoke #{session_id}'s #{access} GitHub token " <>
            "(#{API.explain(reason)}); it runs out at #{held["expires_at"]}"
        )
    end
  end

  @doc "Which sessions hold one, for tests. Never the tokens."
  @spec sessions() :: [String.t()]
  def sessions do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _table ->
        @table
        |> :ets.tab2list()
        |> Enum.map(fn {{id, _access}, _} -> id end)
        |> Enum.uniq()
        |> Enum.sort()
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

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :none

      _table ->
        case :ets.lookup(@table, key) do
          [{^key, held}] -> {:ok, held}
          [] -> :none
        end
    end
  end

  defp ask(session_id, access, opts) do
    link = Keyword.get(opts, :link, Link)

    params =
      if access == :write,
        do: %{"session_id" => session_id, "access" => "write"},
        else: %{"session_id" => session_id}

    case Link.request(link, "git.credential", params) do
      {:ok, %{"token" => token} = credential} when is_binary(token) ->
        if :ets.whereis(@table) != :undefined,
          do: :ets.insert(@table, {{session_id, access}, credential})

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

  defp unexpired?(expires_at, now) do
    case DateTime.from_iso8601(to_string(expires_at)) do
      {:ok, at, _offset} -> DateTime.to_unix(at) > now
      _unreadable -> false
    end
  end

  defp usable?(expires_at, now) do
    case DateTime.from_iso8601(to_string(expires_at)) do
      {:ok, at, _offset} -> DateTime.to_unix(at) - now > @margin_seconds
      _unreadable -> false
    end
  end
end
