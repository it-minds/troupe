defmodule Troupe.Ctl.Application do
  @moduledoc """
  The command line's entry point.

  Inside a packaged binary this runs the command synchronously and halts the VM;
  outside one it is a no-op, so `mix test` and `iex -S mix` are never taken over.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [Troupe.CLI]
    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Ctl.Supervisor)
  end
end
