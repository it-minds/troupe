defmodule Troupe.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    :ok = Troupe.LLM.UsageLog.attach()

    children = [
      {Registry, keys: :unique, name: Troupe.Registry},
      {Registry, keys: :duplicate, name: Troupe.Events},
      {DynamicSupervisor, name: Troupe.Sessions, strategy: :one_for_one},
      {DynamicSupervisor, name: Troupe.Providers, strategy: :one_for_one},
      Troupe.Remote.Supervisor,
      Troupe.UI.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Supervisor)
  end
end
