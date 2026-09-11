defmodule Troupe.Operator.Application do
  @moduledoc """
  The operator's supervision tree.

  Empty unless `:autostart` says otherwise, for the same reason the gateway's is: the
  operator is a release that also gets compiled into developer machines and test runs,
  and booting it should not start watching somebody's cluster.

  In the cluster it runs one reconciler per `WorkerProfile` and per `TeamVolume` under a
  `DynamicSupervisor`, driven by watch events plus a periodic resync, and holds a
  Kubernetes `Lease` for leadership. Only the leader reconciles.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:troupe_operator, :autostart, false) do
        [Troupe.Operator.Supervisor]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Operator.Root)
  end
end
