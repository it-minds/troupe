defmodule Troupe.Operator.IngressCheckTest do
  @moduledoc """
  The ingress controller's namespace carries `troupe.dev/ingress=true`, or a profile says
  it does not, with the line that fixes it (#765).

  Every worker admits HTTP only from such a namespace. Named by the installation, the
  operator labels it and checks it runs a pod; not named, some namespace carrying the label
  and running a pod is a precondition each profile reports as `IngressNamespaceMissing`.
  Run against `FakeCluster`, an API server in memory.
  """

  use ExUnit.Case, async: false

  import Troupe.Operator.Fixtures

  alias Troupe.Operator.{FakeCluster, Reconcilers}

  setup do
    previous = Application.get_env(:troupe_operator, :settings)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_operator, :settings, previous),
        else: Application.delete_env(:troupe_operator, :settings)
    end)

    start_supervised!(Reconcilers)
    :ok
  end

  test "no namespace carrying the label is IngressNamespaceMissing, with the kubectl line" do
    conn =
      FakeCluster.start([
        policy(),
        profile(),
        namespace("ingress-nginx", %{}),
        pod("ingress-nginx")
      ])

    assert {:ok, _result} = reconcile(conn)

    assert %{"status" => "True", "reason" => "NoNamespaceLabelled", "message" => message} =
             condition("IngressNamespaceMissing")

    assert message =~ "every worker Ingress answers 503"

    assert message =~
             "kubectl label namespace <the ingress controller's namespace> troupe.dev/ingress=true"

    assert message =~ "operator.ingressNamespace"
  end

  test "a labelled namespace that runs a pod is enough, where none is named" do
    conn =
      FakeCluster.start([policy(), profile(), namespace("ingress", labelled()), pod("ingress")])

    assert {:ok, _result} = reconcile(conn)

    assert %{"status" => "False", "reason" => "Labelled", "message" => message} =
             condition("IngressNamespaceMissing")

    assert message =~ "ingress carries troupe.dev/ingress=true and runs pods"
  end

  test "a labelled namespace that runs no pod is not the controller's" do
    finished = put_in(pod("ingress"), ["status", "phase"], "Succeeded")
    conn = FakeCluster.start([policy(), profile(), namespace("ingress", labelled()), finished])

    assert {:ok, _result} = reconcile(conn)

    assert %{"status" => "True", "reason" => "NoControllerPods"} =
             condition("IngressNamespaceMissing")
  end

  test "a named namespace is labelled by the operator" do
    conn =
      FakeCluster.start([
        policy(),
        profile(),
        namespace("ingress-nginx", %{"app.kubernetes.io/name" => "ingress-nginx"}),
        pod("ingress-nginx")
      ])

    assert {:ok, _result} = reconcile(conn, ingress_namespace: "ingress-nginx")

    labels = FakeCluster.get("v1", "Namespace", nil, "ingress-nginx")["metadata"]["labels"]
    assert labels["troupe.dev/ingress"] == "true"
    assert %{"status" => "False"} = condition("IngressNamespaceMissing")
  end

  test "a named namespace is left as it is with labelling off, and its missing label said" do
    conn =
      FakeCluster.start([
        policy(),
        profile(),
        namespace("ingress-nginx", %{}),
        namespace("elsewhere", labelled()),
        pod("elsewhere")
      ])

    assert {:ok, _result} =
             reconcile(conn, ingress_namespace: "ingress-nginx", label_ingress_namespace: false)

    refute FakeCluster.get("v1", "Namespace", nil, "ingress-nginx")["metadata"]["labels"][
             "troupe.dev/ingress"
           ]

    assert %{"status" => "True", "reason" => "NamedNamespaceUnlabelled", "message" => message} =
             condition("IngressNamespaceMissing")

    assert message =~ "kubectl label namespace ingress-nginx troupe.dev/ingress=true"
  end

  # An apply would make it: a name that is wrong is said, not created.
  test "a named namespace that does not exist is said, and not made" do
    conn = FakeCluster.start([policy(), profile()])

    assert {:ok, _result} = reconcile(conn, ingress_namespace: "ingress-nginx")

    refute FakeCluster.get("v1", "Namespace", nil, "ingress-nginx")

    assert %{"status" => "True", "reason" => "NamedNamespaceNotFound"} =
             condition("IngressNamespaceMissing")
  end

  # -- helpers ----------------------------------------------------------------

  defp labelled, do: %{"troupe.dev/ingress" => "true"}

  defp namespace(name, labels) do
    %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => name, "labels" => labels}
    }
  end

  defp pod(namespace) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{"name" => "controller", "namespace" => namespace},
      "status" => %{"phase" => "Running"}
    }
  end

  defp current,
    do: FakeCluster.get("troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev")

  defp reconcile(conn, settings \\ []) do
    Application.put_env(:troupe_operator, :settings, settings)
    Reconcilers.reconcile(conn, current())
  end

  defp condition(type), do: Enum.find(current()["status"]["conditions"], &(&1["type"] == type))
end
