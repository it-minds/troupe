defmodule Troupe.Ctl.Application do
  @moduledoc """
  The command line's entry point.

  What it supervises depends on the command. `troupe daemon` is a tree that has to
  stay up, so the daemon is the application's child; every other command is a task
  that finishes and halts the VM, so `Troupe.CLI` is. Blocking inside `start/2` for
  the life of a daemon would leave the release half-booted for as long as it ran.

  Outside a packaged binary this is always the second case, and `Troupe.CLI` is a
  no-op — `mix test` and `iex -S mix` are never taken over.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(Troupe.CLI.boot_children(),
      strategy: :one_for_one,
      name: Troupe.Ctl.Supervisor
    )
  end
end
