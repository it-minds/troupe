defmodule Troupe.Worker.Harness do
  @moduledoc """
  Where harnesses attach to sessions on this pod.

  The same JSON-RPC the local daemon speaks, over the same gateway code, reached through
  the pod's own Ingress host. Only the authentication differs: locally the socket's
  permissions are the whole story, and here it is a token whose audience is this pod
  alone.

  Reusing the gateway rather than writing a second server is the point. A remote session
  and a local one enforce the same scopes with the same table, stream the same events
  through the same backpressure, and answer the same methods — so there is one protocol
  implementation and not two that drift.
  """

  alias Troupe.Gateway.Listener
  alias Troupe.Protocol.Endpoint
  alias Troupe.Worker.Auth

  @default_port 4100

  @doc "The child spec for a pod's harness listener."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    auth = Keyword.get(opts, :auth, Auth)
    port = Keyword.get(opts, :port, Application.get_env(:troupe_worker, :harness_port, @default_port))

    Listener.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      endpoint: Endpoint.remote(port, Auth.authenticator(auth), guard: Auth.guard(auth))
    )
  end
end
