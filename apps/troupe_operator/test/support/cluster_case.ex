defmodule Troupe.Operator.ClusterCase do
  @moduledoc """
  A test that needs a real Kubernetes cluster.

  Skipped **loudly** when there isn't one — a conformance test that quietly does not
  run is worse than none — and otherwise driven against whatever `KUBECONFIG` points
  at, which `scripts/kind-up` puts there.

  Every test gets its own profile names, so two can run against the same cluster
  without meeting, and cleans up after itself.
  """

  use ExUnit.CaseTemplate

  alias Troupe.Operator.Conn

  using do
    quote do
      import Troupe.Operator.ClusterCase

      alias Troupe.Operator.{Names, Reconcilers, Resources}
    end
  end

  setup_all do
    case cluster() do
      {:ok, conn} ->
        {:ok, conn: conn}

      {:error, reason} ->
        IO.puts(:stderr, """

        SKIPPED: no Kubernetes cluster (#{inspect(reason)}).
        These prove the operator's done criteria and did not run.
        Bring one up with `scripts/kind-up` and install the chart:

            scripts/kind-up
            helm upgrade --install troupe charts/troupe -n troupe-system --create-namespace
        """)

        :ok
    end
  end

  setup context do
    if conn = context[:conn] do
      suffix = System.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()
      %{conn: conn, suffix: suffix}
    else
      :ok
    end
  end

  @doc "Whether a cluster with Troupe's CRDs installed is reachable."
  @spec cluster() :: {:ok, K8s.Conn.t()} | {:error, term()}
  def cluster do
    with {:ok, conn} <- Conn.get(),
         {:ok, _} <- K8s.Client.run(conn, K8s.Client.list("troupe.dev/v1alpha1", "WorkerProfile", namespace: "troupe-system")) do
      {:ok, conn}
    end
  end

  @doc "Apply a resource and return what the API server made of it."
  @spec apply!(K8s.Conn.t(), map()) :: map()
  def apply!(conn, resource) do
    {:ok, applied} = K8s.Client.run(conn, K8s.Client.apply(resource, field_manager: "troupe-test", force: true))
    applied
  end

  @doc """
  Apply a resource, retrying while admission refuses it.

  Removing a `ValidatingAdmissionPolicyBinding` does not take effect the instant the
  object is gone: the API server's admission plugin notices on its own schedule. A test
  that has just removed one has to wait for it to stop being enforced, and waiting for
  the object to disappear is not the same thing.
  """
  @spec apply_eventually!(K8s.Conn.t(), map(), pos_integer()) :: map()
  def apply_eventually!(conn, resource, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_apply_eventually(conn, resource, deadline)
  end

  defp do_apply_eventually(conn, resource, deadline) do
    case K8s.Client.run(conn, K8s.Client.apply(resource, field_manager: "troupe-test", force: true)) do
      {:ok, applied} ->
        applied

      {:error, error} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_apply_eventually(conn, resource, deadline)
        else
          ExUnit.Assertions.flunk("apply never succeeded: #{inspect(error)}")
        end
    end
  end

  @doc "Fetch a resource, or `nil`."
  @spec fetch(K8s.Conn.t(), String.t(), String.t(), keyword()) :: map() | nil
  def fetch(conn, api_version, kind, opts) do
    case K8s.Client.run(conn, K8s.Client.get(api_version, kind, opts)) do
      {:ok, resource} -> resource
      {:error, _} -> nil
    end
  end

  @doc "Delete a resource, tolerating its absence."
  @spec delete(K8s.Conn.t(), String.t(), String.t(), keyword()) :: :ok
  def delete(conn, api_version, kind, opts) do
    K8s.Client.run(conn, K8s.Client.delete(api_version, kind, opts))
    :ok
  end

  @doc "Wait for something to become true, or say what never happened."
  @spec eventually((-> boolean()), String.t(), pos_integer()) :: :ok
  def eventually(predicate, message, timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(predicate, message, deadline)
  end

  defp do_eventually(predicate, message, deadline) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(250)
        do_eventually(predicate, message, deadline)

      true ->
        ExUnit.Assertions.flunk(message)
    end
  end

  @doc "A WorkerProfile that sits inside the chart's default policy."
  @spec profile_resource(String.t(), keyword()) :: map()
  def profile_resource(name, overrides \\ []) do
    spec =
      %{
        "image" => %{"repository" => "ghcr.io/objective-mj/troupe-worker", "tag" => "0.2.0"},
        "replicas" => 2,
        "sessionsPerPod" => 4,
        "resources" => %{
          "requests" => %{"cpu" => "50m", "memory" => "64Mi"},
          "limits" => %{"cpu" => "1", "memory" => "1Gi"}
        },
        "llm" => %{
          "endpoint" => "https://api.anthropic.com",
          "secretRef" => %{"name" => "llm-credentials", "key" => "api-key"}
        },
        "egress" => %{"fqdns" => ["api.anthropic.com"], "gitHosts" => ["github.com"]},
        "teams" => [%{"name" => "dev", "mode" => "rw", "storageClassName" => "standard", "size" => "1Gi"}]
      }
      |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))

    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => name, "namespace" => "troupe-system"},
      "spec" => spec
    }
  end

  @doc "The value of one status condition, or `nil`."
  @spec condition(map() | nil, String.t()) :: map() | nil
  def condition(nil, _type), do: nil

  def condition(resource, type) do
    resource
    |> get_in(["status", "conditions"])
    |> List.wrap()
    |> Enum.find(&(&1["type"] == type))
  end
end
