defmodule Troupe.Plane.FakeWorkerProfiles do
  @moduledoc """
  A Kubernetes that knows one kind, `WorkerProfile`, and what its status says.

  For the tests where what the operator reported is the subject and a cluster is not. The
  plane reads a profile's conditions with its own client, discovery and `GET`, unchanged;
  this is the `K8s.Client.Provider` underneath, the seam the client library offers for
  exactly this, answering in place of the network. A profile it was not given is
  `NotFound`, which is what a profile the operator has not reconciled yet looks like.

  `start/1` puts its connection where the plane looks for one, so everything else that
  reads `:k8s_conn` in the same test asks this too, and gets `NotFound` for any other kind.
  Only for tests that are not `async`: both are application environment.
  """

  @behaviour K8s.Client.Provider

  alias K8s.Client.APIError

  @group_version "troupe.dev/v1alpha1"

  @doc "Answer for these profiles' statuses, by name, for the rest of the test."
  @spec start(%{String.t() => map()}) :: K8s.Conn.t()
  def start(statuses) do
    conn = %K8s.Conn{url: "https://kubernetes.example.test", http_provider: __MODULE__}

    previous = Application.get_env(:troupe_plane, :k8s_conn)
    Application.put_env(:troupe_plane, :k8s_conn, conn)
    Application.put_env(:troupe_plane, __MODULE__, statuses)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:troupe_plane, __MODULE__)

      if previous,
        do: Application.put_env(:troupe_plane, :k8s_conn, previous),
        else: Application.delete_env(:troupe_plane, :k8s_conn)
    end)

    conn
  end

  @doc "The status an operator writes, with the one condition a test is about."
  @spec egress_by_hostname(boolean()) :: map()
  def egress_by_hostname(holds?) do
    %{
      "conditions" => [
        %{
          "type" => "EgressByHostname",
          "status" => if(holds?, do: "True", else: "False"),
          "reason" => if(holds?, do: "CiliumFQDN", else: "NoCilium")
        }
      ]
    }
  end

  @impl K8s.Client.Provider
  def request(:get, %URI{path: "/apis/troupe.dev/v1alpha1"}, _body, _headers, _opts) do
    {:ok,
     %{
       "kind" => "APIResourceList",
       "groupVersion" => @group_version,
       "resources" => [
         %{
           "name" => "workerprofiles",
           "singularName" => "workerprofile",
           "namespaced" => true,
           "kind" => "WorkerProfile",
           "verbs" => ["get", "list"]
         }
       ]
     }}
  end

  def request(:get, %URI{path: path}, _body, _headers, _opts) do
    with ["", "apis", "troupe.dev", "v1alpha1", "namespaces", namespace, "workerprofiles", name] <-
           String.split(path, "/"),
         {:ok, status} <- Map.fetch(Application.get_env(:troupe_plane, __MODULE__, %{}), name) do
      {:ok,
       %{
         "apiVersion" => @group_version,
         "kind" => "WorkerProfile",
         "metadata" => %{"name" => name, "namespace" => namespace, "generation" => 1},
         "spec" => %{},
         "status" => status
       }}
    else
      _other -> not_found()
    end
  end

  def request(_method, _uri, _body, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def stream(_method, _uri, _body, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def stream_to(_method, _uri, _body, _headers, _opts, _stream_to), do: not_found()

  @impl K8s.Client.Provider
  def websocket_request(_uri, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def websocket_stream(_uri, _headers, _opts), do: not_found()

  @impl K8s.Client.Provider
  def websocket_stream_to(_uri, _headers, _opts, _stream_to), do: not_found()

  defp not_found do
    APIError.from_kubernetes_error(%{
      "kind" => "Status",
      "apiVersion" => "v1",
      "status" => "Failure",
      "reason" => "NotFound",
      "message" => "not found",
      "code" => 404
    })
  end
end
