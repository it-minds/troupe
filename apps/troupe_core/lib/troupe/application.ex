defmodule Troupe.Application do
  @moduledoc """
  The core's supervision tree: sessions and the machinery they need, nothing else.

  `one_for_one`, and the ordering matters only in that the registries and the event
  bus must exist before anything that uses them.

  Notably absent is anything that renders or accepts commands. A UI is a client of the
  daemon now, in its own application, so nothing here can be made to wait on a
  terminal — which is what makes "the UI can never apply backpressure to an agent"
  structural rather than a rule someone has to remember.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Troupe.Registry,
      Troupe.Events,
      Troupe.Sessions.Index,
      Troupe.Sessions
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Supervisor)
  end
end
