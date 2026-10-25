defmodule Troupe.Gateway.LocalOnly do
  @moduledoc """
  Which attached clients are in *Local only*, and which sessions are theirs.

  Local only is a promise a client makes its person: nothing of what they do there reaches a
  plane. The desktop app keeps it for its own requests (one gate, shut while the setting is
  on); the daemon keeps it for the sessions such a client runs, since an agent's `remember`,
  an offer for steering and the memory report all go to the plane from here, not from the
  client. A client says it is in Local only with `client_info.local_only: true` on
  `initialize`, and again with `client.mode` whenever its switch changes.

  **A session is under Local only** from when a Local-only client creates it or gives it work
  (input, a command, a goal, a loop) until a client that is not in Local only gives it work,
  or the client that put it there turns Local only off. It stays there when that client
  disconnects: a goal loop running after the window closed is still the work of somebody who
  asked for nothing to leave the machine. Turning Local only on puts the sessions that client
  has open under it.

  For such a session the daemon makes no plane call: an agent's `remember` with `level: "me"`
  is refused with a sentence that offers the repository, an offer for steering is refused,
  and what its turns read is left out of the report the memory poll carries; it reads the
  memory this machine already holds, and says so once in `instructions_loaded`
  (`Troupe.LocalOnly`). While every attached client is in Local only, the daemon's own polls
  of the plane (the memory, the version policy) wait. The daemon's own sign-in for sessions
  other clients offered (`Troupe.Gateway.Remote`) is not touched.

  Held in memory: a restarted daemon has no client attached, and the next client to give a
  session work says again what it is.
  """

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc """
  Say what an attached client is, at its `initialize` and at every `client.mode`: `true` for
  Local only. `open` are the sessions it has open, which turning Local only on puts under it.
  Turning it off takes the sessions this client put under it back out.
  """
  @spec client(pid(), boolean(), [String.t()]) :: :ok
  def client(pid, local_only?, open \\ []) when is_pid(pid) and is_boolean(local_only?),
    do: call({:client, pid, local_only?, open}, :ok)

  @doc """
  A client gave `session_id` work, or created it: the session is under Local only where that
  client is in it, and out of it where it is not.
  """
  @spec worked(pid(), String.t()) :: :ok
  def worked(pid, session_id) when is_pid(pid) and is_binary(session_id),
    do: call({:worked, pid, session_id}, :ok)

  @doc "Whether the client on this connection is in Local only."
  @spec client?(pid()) :: boolean()
  def client?(pid) when is_pid(pid), do: call({:client?, pid}, false)

  @doc "Whether `session_id` is under Local only."
  @spec session?(String.t() | nil) :: boolean()
  def session?(session_id) when is_binary(session_id), do: call({:session?, session_id}, false)
  def session?(_none), do: false

  @doc """
  Whether the daemon's own polls of the plane wait: some client is attached and every one is
  in Local only. With nobody attached they run, as they always did.
  """
  @spec paused?() :: boolean()
  def paused?, do: call(:paused?, false)

  @doc "What a refusal says, for whatever it refused."
  @spec sentence(String.t()) :: String.t()
  def sentence(what) do
    "#{what}: this session is under Local only, so the daemon makes no call to a plane for " <>
      "it. Turn Local only off in the client that started it to do this"
  end

  # Not running (a test that starts no daemon, a pod) is a client in no Local only.
  defp call(message, otherwise) do
    case Process.whereis(@name) do
      nil -> otherwise
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _gone -> otherwise
  end

  # -- server -------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe local only")
    # A session asks the daemon, through the harness's hook, whether it is under Local only.
    :ok = Troupe.LocalOnly.install(&__MODULE__.session?/1)
    {:ok, %{clients: %{}, sessions: %{}}}
  end

  @impl GenServer
  def handle_call({:client, pid, on?, open}, _from, state) do
    state = watch(state, pid)
    state = put_in(state.clients[pid].local_only, on?)

    sessions =
      if on?,
        do: Enum.reduce(open, state.sessions, &Map.put(&2, &1, pid)),
        else: Map.reject(state.sessions, fn {_session, by} -> by == pid end)

    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:worked, pid, session_id}, _from, state) do
    sessions =
      if local_only?(state, pid),
        do: Map.put(state.sessions, session_id, pid),
        else: Map.delete(state.sessions, session_id)

    {:reply, :ok, %{state | sessions: sessions}}
  end

  def handle_call({:client?, pid}, _from, state), do: {:reply, local_only?(state, pid), state}

  def handle_call({:session?, id}, _from, state),
    do: {:reply, Map.has_key?(state.sessions, id), state}

  def handle_call(:paused?, _from, state) do
    clients = Map.values(state.clients)
    {:reply, clients != [] and Enum.all?(clients, & &1.local_only), state}
  end

  # A client gone is no longer attached; the sessions it put under Local only stay there.
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | clients: Map.delete(state.clients, pid)}}

  defp watch(state, pid) do
    if Map.has_key?(state.clients, pid) do
      state
    else
      Process.monitor(pid)
      put_in(state.clients[pid], %{local_only: false})
    end
  end

  defp local_only?(state, pid), do: match?(%{local_only: true}, state.clients[pid])
end
