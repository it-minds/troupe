defmodule Troupe.Operator.Settings do
  @moduledoc """
  What the operator knows about the cluster it is running in.

  Everything here comes from Helm values rather than from a `WorkerProfile`, because it
  is true of the installation and not of any one pool of workers: where the plane
  listens, where OpenBao is, which ingress class to use. A profile that could set these
  could point its workers at another installation's plane.
  """

  defstruct plane_control_host: "troupe-plane-control.troupe-system.svc",
            plane_control_port: 4001,
            plane_namespace: "troupe-system",
            bao_address: "http://openbao.troupe-system.svc:8200",
            object_store_endpoint: "http://minio.troupe-system.svc:9000",
            object_store_bucket: "troupe-sessions",
            ingress_class_name: "nginx",
            tls_secret_name: nil,
            image_pull_secrets: [],
            cilium_available: false,
            drain_timeout_seconds: 300

  @type t :: %__MODULE__{}

  @doc "Settings from application configuration, which Helm renders into the operator's env."
  @spec from_env() :: t()
  def from_env do
    config = Application.get_env(:troupe_operator, :settings, [])
    struct(__MODULE__, config)
  end
end
