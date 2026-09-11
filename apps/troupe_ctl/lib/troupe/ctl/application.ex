defmodule Troupe.Ctl.Application do
  @moduledoc """
  The command line's entry point.

  Inside a Burrito binary `Troupe.CLI` runs the command synchronously here and then
  halts the VM; `troupe daemon` is the one command that does not finish, and blocks
  instead. That is why this application is listed **last** in the release: by the time
  it blocks, the core and the gateway have started.

  Outside a packaged binary `Troupe.CLI` is a no-op, so `mix test` and `iex -S mix`
  are never taken over.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([Troupe.CLI], strategy: :one_for_one, name: Troupe.Ctl.Supervisor)
  end
end
