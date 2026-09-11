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
      └── Idle          shuts the daemon down after a quiet period

  `Troupe.Sessions` and the session trees themselves live in `troupe_core`'s own
  supervision tree, so the daemon can restart its listener without disturbing a
  running agent.
  """

  use Supervisor

  alias Troupe.Gateway.{Commands, Connections, Idle, Listener}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    Process.set_label("troupe daemon")

    children = [
      {Commands, opts},
      {Connections, opts},
      {Listener, opts},
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
