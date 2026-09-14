defmodule Troupe.Gateway.Daemon do
  @moduledoc """
  The local daemon: it owns every session for the user, and clients attach to it.

  Moving sessions out of the TUI process is the point of this stage. A client is now
  something that connects, subscribes, and steers; it holds no session state and its
  death costs nothing. The built-in TUI has no private access — if it cannot do
  something through the protocol, nobody can.

  The tree:

      Daemon (one_for_one)
      ├── Commands      idempotency ledger: command_id -> acknowledgement
      ├── Connections   DynamicSupervisor, one process per attached client
      ├── Listener      accepts on the transport and hands sockets to Connections
      ├── Loopback      a WebSocket on 127.0.0.1, which is the only door a browser has
      └── Idle          shuts the daemon down after a quiet period

  `Troupe.Sessions` and the session trees themselves live in `troupe_core`'s own
  supervision tree, so the daemon can restart its listener without disturbing a
  running agent.
  """

  use Supervisor

  alias Troupe.Gateway.{Commands, Connections, Idle, Listener, Loopback}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @instance_key {__MODULE__, :instance_id}

  @doc """
  This daemon's identity for as long as it is running.

  A client that reconnects and finds a different one is talking to a daemon that has
  been restarted, which means its own view of any session is stale and it must replay
  rather than resume. Without this the client cannot tell a reconnection from a
  restart, and a restart looks exactly like a very quiet session.
  """
  @spec instance_id() :: String.t()
  def instance_id do
    case :persistent_term.get(@instance_key, nil) do
      nil ->
        id = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        :persistent_term.put(@instance_key, id)
        id

      id ->
        id
    end
  end

  @impl Supervisor
  def init(opts) do
    Process.set_label("troupe daemon")
    :persistent_term.erase(@instance_key)
    _ = instance_id()

    children = [
      {Commands, opts},
      {Connections, opts},
      {Listener, opts},
      # After the Listener, so that `rest_for_one` republishes the WebSocket entry if
      # the Listener ever restarts and rewrites the discovery file underneath it.
      {Loopback, Keyword.get(opts, :loopback, [])},
      {Idle, opts}
    ]

    # rest_for_one: the Listener hands sockets to Connections and the Idle watcher
    # counts them, so anything that restarts must restart what depends on it.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 10)
  end
end

defmodule Troupe.Gateway.Connections do
  @moduledoc "The DynamicSupervisor holding one process per attached client."

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 256)

  @doc "Start a connection process owning an accepted socket."
  @spec attach(keyword()) :: DynamicSupervisor.on_start_child()
  def attach(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Troupe.Gateway.Connection, opts})
  end

  @doc "How many clients are attached."
  @spec count() :: non_neg_integer()
  def count, do: DynamicSupervisor.count_children(__MODULE__).active

  @spec list() :: [pid()]
  def list do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid), do: [pid], else: [] end)
  end
end
