defmodule Troupe.Remote.Supervisor do
  @moduledoc """
  Everything the remote client owns: the token store, the plane connections and
  the per-session journals and worker connections.

  `one_for_one`, so a plane that cannot be reached does not take the attached
  sessions down with it — which is exactly the degraded mode the contract asks
  for, expressed as a supervision strategy rather than as a flag.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Troupe.Remote.Tokens,
      {DynamicSupervisor, name: Troupe.Remote.Connections, strategy: :one_for_one},
      {DynamicSupervisor, name: Troupe.Remote.Sessions, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
