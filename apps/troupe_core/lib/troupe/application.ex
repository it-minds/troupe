defmodule Troupe.Application do
  @moduledoc """
  The application root.

  `one_for_one`, and the ordering matters only in that the two registries must exist
  before anything that registers in them. Sessions and the UI are siblings: the UI is
  a subscriber to `Troupe.Events`, never something a session depends on, so it can
  crash, restart and reattach without touching a running session.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [
        Troupe.Registry,
        Troupe.Events,
        Troupe.Sessions.Index,
        Troupe.Sessions,
        Troupe.UI.Supervisor
      ] ++
        List.wrap(Troupe.Wrapper.child_spec_if_wrapped()) ++
        [
          # Last, and a no-op outside a packaged binary: inside one it runs the
          # command synchronously and halts the VM when it finishes.
          Troupe.CLI
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Supervisor)
  end
end

defmodule Troupe.UI.Supervisor do
  @moduledoc """
  Where a TUI or a headless printer lives.

  Empty at boot: the CLI attaches a UI after it has decided what kind to run. Keeping
  it outside the session tree is what makes "the UI can never apply backpressure to an
  agent" structural.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Attach a UI process. It subscribes to `Troupe.Events` itself."
  @spec attach(Supervisor.child_spec() | {module(), term()} | module()) ::
          DynamicSupervisor.on_start_child()
  def attach(child_spec), do: DynamicSupervisor.start_child(__MODULE__, child_spec)
end
