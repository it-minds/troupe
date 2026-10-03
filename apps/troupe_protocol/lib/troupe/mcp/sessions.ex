defmodule Troupe.MCP.Sessions do
  @moduledoc """
  The MCP sessions one caller holds with the servers it calls (Decision 746).

  A server that keeps state per client hands one an `Mcp-Session-Id` in its answer to
  `initialize` and wants it on every request after; `Troupe.MCP.Client` opens the session
  and this keeps it, so every call to that server reuses it rather than opening its own.
  The caller is whoever lives as long as the sessions should: a local session keeps one of
  these in its supervision tree, a worker pod one in its application's, and the sessions
  end when it stops.

  **The key is the server and the credential that went out.** A server binds a session to
  whoever opened it, so a person's token and a profile's are never one session, and a
  credential that changes (a token refreshed) opens a new one. The credential is hashed into
  the key, not held in it.

  **A credential that replaced another ends the other's session** (Decision 757). Each
  session is also kept for a configured server and whose credential it carries
  (`kept_for/1`), and a session kept for the same as an older one, under another key, is a
  token renewed or a sign-in refreshed: the older one is taken out and ended. Not a
  person-mode server's, where every person is a caller of their own and nothing here tells
  one person's renewed token from another person's. A server the caller no longer calls
  has its sessions ended too (`retain/2`).

  **Ending them is best-effort.** When the holder stops, each session the server issued is
  ended with a `DELETE`, which a server may refuse with `405` and which nothing waits on
  for long; a server forgets an idle session in time anyway. That `DELETE` needs the
  credential the session was opened with, so it is kept beside the session, except a
  person's credential on a pod, which the pod holds only for as long as a call takes
  (`Troupe.MCP.person_credential/2`): that session is left to the server's own expiry.

  An ETS table rather than this process's state, because a lookup is on the path of every
  call to every server and must not queue behind another. It is public: the callers write
  their sessions into it, and the race of two opening at once is settled by
  `:ets.insert_new/2`, the loser ending its own.
  """

  use GenServer

  alias Troupe.MCP.Client

  @typedoc """
  A session, as a server issued it: its id (`nil` when the server keeps none), the
  protocol version it chose, where it is, the headers that end it (`nil` when they are
  not held), and what it is kept for.
  """
  @type session :: %{
          id: String.t() | nil,
          version: String.t(),
          url: String.t(),
          ends_with: [{String.t(), String.t()}] | nil,
          kept_for: kept_for()
        }

  @typedoc "A configured server, by URL and name, and whose credential it carries."
  @type kept_for :: {String.t(), String.t(), atom()}

  @type table :: :ets.tid() | nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The table a `Troupe.MCP.Server` carries as its `sessions`; `nil` when there is no holder."
  @spec table(GenServer.server() | nil) :: table()
  def table(nil), do: nil

  def table(holder) do
    GenServer.call(holder, :table)
  catch
    :exit, _ -> nil
  end

  @doc "Where a server's session is filed: its URL and the headers a call to it carries, hashed."
  @spec key(String.t(), [{String.t(), String.t()}]) :: {String.t(), binary()}
  def key(url, headers), do: {url, :crypto.hash(:sha256, :erlang.term_to_binary(headers))}

  @doc """
  What a server's session is kept for besides its credential: the server's URL, its name,
  and whose credential a call to it carries. Two names for one URL are two callers, as are
  a person-mode server and a profile's.
  """
  @spec kept_for(Troupe.MCP.Server.t()) :: kept_for()
  def kept_for(%{url: url, name: name, credential_mode: mode}), do: {url, name, mode}

  @doc "The session kept under a key, or `nil`."
  @spec lookup(table(), term()) :: session() | nil
  def lookup(nil, _key), do: nil

  def lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, session}] -> session
      [] -> nil
    end
  rescue
    # The holder has gone, and its table with it: there is nothing kept.
    ArgumentError -> nil
  end

  @doc """
  Keep a session just opened: `:kept`, `{:taken, session}` when another call kept one
  under the same key first, or `:not_kept` when there is nowhere to keep it.
  """
  @spec keep(table(), term(), session()) :: :kept | {:taken, session()} | :not_kept
  def keep(nil, _key, _session), do: :not_kept

  def keep(table, key, session) do
    if :ets.insert_new(table, {key, session}) do
      :kept
    else
      case lookup(table, key) do
        nil -> keep(table, key, session)
        other -> {:taken, other}
      end
    end
  rescue
    ArgumentError -> :not_kept
  end

  @doc "Drop a session the server has forgotten, unless another call has already replaced it."
  @spec forget(table(), term(), session()) :: :ok
  def forget(nil, _key, _session), do: :ok

  def forget(table, key, session) do
    :ets.delete_object(table, {key, session})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Take out the sessions a session just kept under `key` replaces, for the caller to end:
  those kept for the same server and caller under another credential, which a renewed
  token or a refreshed sign-in leaves behind. None for a person-mode server, whose
  credentials are as many people's.
  """
  @spec superseded(table(), term(), session()) :: [session()]
  def superseded(nil, _key, _session), do: []
  def superseded(_table, _key, %{kept_for: {_url, _name, :person}}), do: []

  def superseded(table, key, %{kept_for: kept_for}) do
    table
    |> entries()
    |> Enum.filter(fn {other, older} -> other != key and older.kept_for == kept_for end)
    |> take(table)
  end

  @doc """
  Keep only the sessions of these servers, and end the others: what a caller does when a
  server it called is no longer one it calls. Each is taken out, and ended as the holder's
  stopping ends them, a few seconds at most.
  """
  @spec retain(table(), [Troupe.MCP.Server.t()]) :: :ok
  def retain(nil, _servers), do: :ok

  def retain(table, servers) do
    kept = MapSet.new(servers, &kept_for/1)

    table
    |> entries()
    |> Enum.reject(fn {_key, session} -> MapSet.member?(kept, session.kept_for) end)
    |> take(table)
    |> end_all()
  end

  defp entries(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  # Each exactly as it was found, so a session another call has just kept under the same
  # key stays.
  defp take(entries, table) do
    Enum.each(entries, &:ets.delete_object(table, &1))
    Enum.map(entries, fn {_key, session} -> session end)
  rescue
    # The holder has gone, and ended them as it went.
    ArgumentError -> []
  end

  defp end_all(sessions) do
    sessions
    |> Enum.filter(&(is_binary(&1.id) and is_list(&1.ends_with)))
    |> Task.async_stream(&Client.end_session/1,
      max_concurrency: 8,
      timeout: 4_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  # -- the holder ---------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe mcp sessions")
    # Trapped, so a supervisor's shutdown runs `terminate/2`, which is where they end.
    Process.flag(:trap_exit, true)
    {:ok, :ets.new(__MODULE__, [:set, :public, read_concurrency: true])}
  end

  @impl GenServer
  def handle_call(:table, _from, table), do: {:reply, table, table}

  @impl GenServer
  def handle_info(_message, table), do: {:noreply, table}

  @impl GenServer
  def terminate(_reason, table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, session} -> session end)
    |> end_all()
  end
end
