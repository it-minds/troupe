defmodule Troupe.A2A do
  @moduledoc """
  The A2A facade: every Troupe profile as an agent that other agents can call.

  A caller that speaks the A2A protocol — LiteLLM's gateway, another agent framework,
  a script — sends a task to `/a2a/<profile>` and gets an answer back, without learning
  anything about sessions, pods or the human protocol. Behind the route the facade is
  one more client: it exchanges the caller's credential at the plane's `/auth/exchange`,
  calls `/rpc` as that principal, and attaches to worker pods over the same WebSocket
  the TUI uses. It holds no database and no credential of its own.

  What it must remember between requests — which task is which session, and whose —
  is the session row itself: the task id *is* the session id, and the plane records
  `origin.kind: a2a` on the row at create. A restarted facade recovers everything from
  the plane.

  This module is the configuration. Everything is read from the application
  environment at call time rather than at boot, so a test can point the facade at a
  stub plane on a port of its own.
  """

  @app :troupe_a2a

  @doc "Whether the listener starts. Off unless a release says otherwise."
  @spec autostart?() :: boolean()
  def autostart?, do: Application.get_env(@app, :autostart, false)

  @doc "The port the facade listens on."
  @spec port() :: :inet.port_number()
  def port, do: Application.get_env(@app, :port, 4002)

  @doc "Where the plane's `/rpc` and `/auth/exchange` are, without a trailing slash."
  @spec plane_url() :: String.t()
  def plane_url do
    @app
    |> Application.get_env(:plane_url, "http://localhost:4000")
    |> String.trim_trailing("/")
  end

  @doc """
  What the facade calls itself in the URLs it hands out: the card's `url` and every
  artifact `uri`. Behind an Ingress this is the public origin, not the pod's.
  """
  @spec public_url() :: String.t()
  def public_url do
    @app
    |> Application.get_env(:public_url, "http://localhost:#{port()}")
    |> String.trim_trailing("/")
  end

  @doc "How many `message/stream` sockets one replica holds open at once."
  @spec max_streams() :: pos_integer()
  def max_streams, do: Application.get_env(@app, :max_streams, 200)

  @doc """
  The visibility a task's session is created with. `private` by default: a session
  another agent asked for is the calling principal's, and a team that wants to audit
  what other agents ask of its profiles sets `team` here.
  """
  @spec visibility() :: String.t()
  def visibility, do: Application.get_env(@app, :visibility, "private")

  @doc "The version this build reports to pods as its `client_info`."
  @spec version() :: String.t()
  def version do
    case Application.spec(@app, :vsn) do
      nil -> "0"
      vsn -> List.to_string(vsn)
    end
  end
end
