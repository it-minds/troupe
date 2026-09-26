defmodule Troupe.Operator.ReconcilerTest do
  @moduledoc """
  What a reconcile pass takes away.

  A pass lists what carries the operator's marker, kind by kind, and deletes whatever the
  profile no longer implies. The kinds it lists are checked against what `Resources`
  renders; the pass itself runs against `FakeCluster`, an API server in memory, so what
  it deletes and what it leaves alone can be seen without a cluster.
  """

  # The settings are application environment and the fake API server is one process by
  # name, so these cannot run beside each other.
  use ExUnit.Case, async: false

  import Troupe.Operator.Fixtures

  alias Troupe.Operator.{FakeCluster, Reconciler, Reconcilers, Resources, Settings}
  alias Troupe.Policy
  alias Troupe.WorkerProfile, as: Profile

  @cilium_policy {"cilium.io/v2", "CiliumNetworkPolicy", "troupe-w-dev", "troupe-egress"}

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

  test "whatever a profile implies only under some settings is a kind a pass prunes" do
    policy = Policy.from_resource(policy())

    everything =
      profile()
      |> Profile.from_resource()
      |> Resources.for_profile(policy, %Settings{cilium_available: true})

    least =
      [replicas: 0, teams: [], orgMount: false]
      |> profile()
      |> Profile.from_resource()
      |> Resources.for_profile(policy, %Settings{cilium_available: false})

    prunable = MapSet.new(Reconciler.prunable())
    sometimes = MapSet.difference(kinds(everything), kinds(least))

    # A kind that comes and goes and is not listed stays behind once it goes.
    assert MapSet.member?(sometimes, {"cilium.io/v2", "CiliumNetworkPolicy"})

    assert MapSet.subset?(sometimes, prunable),
           "never pruned: #{inspect(MapSet.difference(sometimes, prunable))}"

    # And nothing the operator never writes, which would make it responsible for somebody
    # else's objects.
    assert MapSet.subset?(prunable, kinds(everything))
  end

  describe "the CiliumNetworkPolicy" do
    test "is deleted when Cilium is switched off" do
      conn = FakeCluster.start([policy(), profile()])

      assert {:ok, _result} = reconcile(conn, cilium: true)
      assert get(@cilium_policy)
      assert condition("EgressByHostname")["reason"] == "CiliumFQDN"

      assert {:ok, %{pruned: 1}} = reconcile(conn, cilium: false)
      refute get(@cilium_policy)
      assert FakeCluster.deleted() == [@cilium_policy]
      assert condition("EgressByHostname")["reason"] == "NoCilium"
      assert %{"status" => "True", "message" => message} = condition("Ready")
      assert message =~ "1 removed"
    end

    test "stays while Cilium stays on" do
      conn = FakeCluster.start([policy(), profile()])

      assert {:ok, _result} = reconcile(conn, cilium: true)
      assert {:ok, %{pruned: 0}} = reconcile(conn, cilium: true)
      assert get(@cilium_policy)
      assert FakeCluster.deleted() == []
    end

    test "is neither written nor deleted while Cilium stays off" do
      conn = FakeCluster.start([policy(), profile()])

      assert {:ok, %{pruned: 0}} = reconcile(conn, cilium: false)
      assert {:ok, %{pruned: 0}} = reconcile(conn, cilium: false)
      refute get(@cilium_policy)
      assert FakeCluster.deleted() == []
    end

    test "is no error to look for on a cluster without Cilium's CRD" do
      # Discovery answers `NotFound` for `cilium.io/v2`, as a cluster that never had
      # Cilium does, so the pass's listing of the kind fails at discovery and is never sent.
      conn = FakeCluster.start([policy(), profile()], cilium: false)

      assert {:ok, %{pruned: 0}} = reconcile(conn, cilium: false)
      assert {:get, "/apis/cilium.io/v2"} in FakeCluster.requests()
      assert %{"status" => "True", "reason" => "Reconciled"} = condition("Ready")
      assert condition("EgressByHostname")["reason"] == "NoCilium"
      assert FakeCluster.deleted() == []
    end

    test "that the operator did not write is left alone" do
      # One somebody wrote into the worker namespace, and the operator's own for another
      # profile. Neither carries this profile's marker, so a pass for it never lists them.
      theirs = cilium_policy("allow-registry", "troupe-w-dev", %{"team" => "platform"})

      other_profile =
        cilium_policy("troupe-egress", "troupe-w-ux", %{
          "troupe.dev/managed" => "operator",
          "troupe.dev/profile" => "ux"
        })

      conn = FakeCluster.start([policy(), profile(), theirs, other_profile])

      assert {:ok, _result} = reconcile(conn, cilium: true)
      assert {:ok, %{pruned: 1}} = reconcile(conn, cilium: false)

      assert FakeCluster.deleted() == [@cilium_policy]
      assert get({"cilium.io/v2", "CiliumNetworkPolicy", "troupe-w-dev", "allow-registry"})
      assert get({"cilium.io/v2", "CiliumNetworkPolicy", "troupe-w-ux", "troupe-egress"})
    end
  end

  # One pass, with the installation's settings as Helm would have rendered them, over the
  # profile as the cluster holds it now: with the status the last pass wrote.
  defp reconcile(conn, cilium: cilium?) do
    Application.put_env(:troupe_operator, :settings, cilium_available: cilium?)

    Reconcilers.reconcile(
      conn,
      get({"troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev"})
    )
  end

  defp condition(type) do
    {"troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev"}
    |> get()
    |> get_in(["status", "conditions"])
    |> Enum.find(&(&1["type"] == type))
  end

  defp get({api_version, kind, namespace, name}),
    do: FakeCluster.get(api_version, kind, namespace, name)

  defp cilium_policy(name, namespace, labels) do
    %{
      "apiVersion" => "cilium.io/v2",
      "kind" => "CiliumNetworkPolicy",
      "metadata" => %{"name" => name, "namespace" => namespace, "labels" => labels},
      "spec" => %{"endpointSelector" => %{}, "egress" => []}
    }
  end

  defp kinds(resources), do: MapSet.new(resources, &{&1["apiVersion"], &1["kind"]})
end
