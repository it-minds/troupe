defmodule Troupe.Plane.EnrolmentTest do
  @moduledoc """
  How a pod proves which profile it is.

  Against a real API server, because the mechanism *is* the API server: a `TokenReview`
  is the only thing that turns a bearer token into an identity, and a test that faked
  it would prove nothing about the two cases that matter — a token for another audience,
  and a token from another namespace.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Enrolment, Fleet}

  @moduletag timeout: 120_000

  setup_all do
    case cluster() do
      {:ok, conn} ->
        for namespace <- ["troupe-w-dev", "troupe-w-ux"] do
          ensure_namespace(conn, namespace)
          ensure_service_account(conn, namespace, "troupe-worker")
        end

        {:ok, conn: conn}

      {:error, reason} ->
        IO.puts(:stderr, """

        SKIPPED: no Kubernetes cluster (#{inspect(reason)}).
        Enrolment is a TokenReview, so these need a real API server.
        Bring one up with `scripts/kind-up`.
        """)

        :ok
    end
  end

  describe "verifying a token" do
    test "a pod's own token says which profile it is", context do
      conn = requires_cluster(context)
      token = mint(conn, "troupe-w-dev", "troupe-worker")

      assert {:ok, identity} = Enrolment.verify(token, conn: {:ok, conn})
      assert identity.profile == "dev"
      assert identity.namespace == "troupe-w-dev"
      assert identity.service_account == "troupe-worker"
    end

    test "a token from another namespace enrols as that namespace, not as dev", context do
      conn = requires_cluster(context)
      token = mint(conn, "troupe-w-ux", "troupe-worker")

      # The point of deriving the profile from the namespace: a ux pod cannot claim to
      # be dev, because it cannot mint a token from dev's ServiceAccount.
      assert {:ok, identity} = Enrolment.verify(token, conn: {:ok, conn})
      assert identity.profile == "ux"
      refute identity.profile == "dev"
    end

    test "a token minted for the API server is refused", context do
      conn = requires_cluster(context)
      # The default audience is the API server's. Projecting with `troupe-plane` is what
      # stops a token meant for one being replayed against the other.
      token = mint(conn, "troupe-w-dev", "troupe-worker", audiences: [])

      assert {:error, reason} = Enrolment.verify(token, conn: {:ok, conn})
      assert reason in [:unauthenticated, :wrong_audience]
    end

    test "a token for a different service account is refused", context do
      conn = requires_cluster(context)
      ensure_service_account(conn, "troupe-w-dev", "someone-else")
      token = mint(conn, "troupe-w-dev", "someone-else")

      assert {:error, {:wrong_service_account, "someone-else"}} =
               Enrolment.verify(token, conn: {:ok, conn})
    end

    test "a token from outside a worker namespace is refused", context do
      conn = requires_cluster(context)
      ensure_service_account(conn, "default", "troupe-worker")
      token = mint(conn, "default", "troupe-worker")

      assert {:error, {:not_a_worker_namespace, "default"}} =
               Enrolment.verify(token, conn: {:ok, conn})
    end

    test "nonsense is refused", context do
      conn = requires_cluster(context)
      assert {:error, _} = Enrolment.verify("not-a-token", conn: {:ok, conn})
    end
  end

  describe "enrolling" do
    test "records the pod under the profile its token proved", context do
      conn = requires_cluster(context)
      token = mint(conn, "troupe-w-dev", "troupe-worker")

      {:ok, identity} = Enrolment.verify(token, conn: {:ok, conn})

      assert {:ok, worker} =
               Enrolment.enrol(identity, %{
                 "pod_name" => "troupe-w-dev-2",
                 "capacity" => 4,
                 "endpoint" => "https://2-dev.workers.test",
                 "disk_total_bytes" => 1000
               })

      assert worker.profile == "dev"
      assert worker.namespace == "troupe-w-dev"
      assert worker.ordinal == 2
      assert worker.healthy
      assert worker.capacity == 4
    end

    test "enrolling twice is the same pod coming back, not a second one", context do
      conn = requires_cluster(context)
      token = mint(conn, "troupe-w-dev", "troupe-worker")
      {:ok, identity} = Enrolment.verify(token, conn: {:ok, conn})

      claims = %{"pod_name" => "troupe-w-dev-0", "capacity" => 4, "disk_total_bytes" => 1000}

      {:ok, first} = Enrolment.enrol(identity, claims)
      {:ok, second} = Enrolment.enrol(identity, claims)

      assert first.id == second.id

      assert Fleet.list_workers("dev")
             |> Enum.filter(&(&1.pod_name == "troupe-w-dev-0"))
             |> length() == 1
    end

    test "a pod whose name has no ordinal is refused", context do
      conn = requires_cluster(context)
      token = mint(conn, "troupe-w-dev", "troupe-worker")
      {:ok, identity} = Enrolment.verify(token, conn: {:ok, conn})

      assert {:error, {:not_a_stateful_set_pod, "some-pod"}} =
               Enrolment.enrol(identity, %{"pod_name" => "some-pod"})
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp requires_cluster(%{conn: conn}), do: conn
  defp requires_cluster(_), do: flunk("no cluster; see the message from setup_all")

  # A real token from the API server, the way a projected volume would have got one.
  # Through `kubectl` because the Elixir client does not know the `token` subresource,
  # and a token minted any other way would not be the thing under test.
  defp mint(_conn, namespace, account, opts \\ []) do
    audiences = Keyword.get(opts, :audiences, [Enrolment.audience()])
    audience_args = Enum.flat_map(audiences, &["--audience", &1])

    args =
      ["create", "token", account, "-n", namespace, "--duration", "10m"] ++
        audience_args ++ context_args()

    {token, 0} = System.cmd("kubectl", args)
    String.trim(token)
  end

  defp context_args do
    case System.get_env("TROUPE_KUBE_CONTEXT") do
      nil -> []
      context -> ["--context", context]
    end
  end

  defp cluster do
    with {:ok, conn} <- connection(),
         {:ok, _} <- K8s.Client.run(conn, K8s.Client.list("v1", "Namespace")) do
      {:ok, conn}
    end
  end

  defp connection do
    path = System.get_env("KUBECONFIG") || Path.join(System.user_home!(), ".kube/config")

    if File.exists?(path) do
      K8s.Conn.from_file(path, context: System.get_env("TROUPE_KUBE_CONTEXT"))
    else
      {:error, :no_kubeconfig}
    end
  end

  defp ensure_namespace(conn, name) do
    resource = %{"apiVersion" => "v1", "kind" => "Namespace", "metadata" => %{"name" => name}}
    K8s.Client.run(conn, K8s.Client.apply(resource, field_manager: "troupe-test", force: true))
  end

  defp ensure_service_account(conn, namespace, name) do
    resource = %{
      "apiVersion" => "v1",
      "kind" => "ServiceAccount",
      "metadata" => %{"name" => name, "namespace" => namespace}
    }

    K8s.Client.run(conn, K8s.Client.apply(resource, field_manager: "troupe-test", force: true))
  end
end
