defmodule Troupe.Operator.ReconcilerTest do
  @moduledoc """
  What a reconcile pass takes away, and what it says about the pods it does not touch.

  A pass lists what carries the operator's marker, kind by kind, and deletes whatever the
  profile no longer implies. The kinds it lists are checked against what `Resources`
  renders; the pass itself runs against `FakeCluster`, an API server in memory, so what
  it deletes and what it leaves alone can be seen without a cluster. So can the pods it
  reports behind on the StatefulSet's revision, and the one of them it deletes once the
  plane has recorded it drained.
  """

  # The settings are application environment and the fake API server is one process by
  # name, so these cannot run beside each other.
  use ExUnit.Case, async: false

  import Troupe.Operator.Fixtures

  alias Troupe.Operator.{FakeCluster, Names, Reconciler, Reconcilers, Resources, Settings}
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
      [mcpIdentities: [identity()]]
      |> profile()
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

  describe "EndpointUnreachable (Decision 749)" do
    # In gitops mode a profile is applied by something else, so nothing refuses it where
    # it is written: the operator says on the profile what its workers will not reach, as
    # it says a Secret is missing, and the console shows it.

    test "without Cilium, names each endpoint a worker's NetworkPolicy cannot reach" do
      conn = FakeCluster.start([unreachable_policy(), unreachable_profile()])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert %{"status" => "True", "reason" => "NoCilium", "message" => message} =
               condition("EndpointUnreachable")

      assert message =~ "llm.endpoint https://llm.internal.test:8443/v1 is on port 8443"
      assert message =~ "MCP server tickets at https://10.20.0.5/tickets is at 10.20.0.5"
      assert message =~ "without Cilium"
      assert message =~ "operator.ciliumAvailable"

      # Beside `Ready`, as `SecretMissing` is: everything the profile implies was made.
      assert condition("Ready")["status"] == "True"
    end

    test "with Cilium, the same profile reaches them" do
      conn = FakeCluster.start([unreachable_policy(), unreachable_profile()])

      assert {:ok, _result} = reconcile(conn, cilium: true)
      assert %{"status" => "False", "reason" => "Cilium"} = condition("EndpointUnreachable")
    end

    test "without Cilium, public names on 443 and hosts in the cluster are reached" do
      in_cluster = %{"name" => "tools", "url" => "http://tools.mcp.svc:8080/mcp"}
      profile = update_in(profile(), ["spec", "mcpServers"], &(&1 ++ [in_cluster]))
      allowed = policy()["spec"]["allowedEgress"] ++ ["tools.mcp.svc"]
      conn = FakeCluster.start([policy(allowedEgress: allowed), profile])

      assert {:ok, _result} = reconcile(conn, cilium: false)
      assert %{"status" => "False", "reason" => "Reachable"} = condition("EndpointUnreachable")
    end
  end

  # A server the bundle calls as the profile's own identity (Decision 747).
  describe "MCPIdentityMissing" do
    @marked %{
      "name" => "jira",
      "url" => "https://mcp.internal.test/jira",
      "credentialMode" => "client_credentials"
    }

    test "says which server has no identity, and the pods are made anyway" do
      conn = FakeCluster.start([policy(), profile(mcpServers: [@marked])])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert %{"status" => "True", "reason" => "IdentityMissing", "message" => message} =
               condition("MCPIdentityMissing")

      assert message =~ "mcp server jira is called with client credentials"
      assert get({"apps/v1", "StatefulSet", "troupe-w-dev", "troupe-w-dev"})
    end

    test "is false with an identity, whose ConfigMap goes once the identity does" do
      identities = {"v1", "ConfigMap", "troupe-w-dev", Names.mcp_identities()}

      conn =
        FakeCluster.start([policy(), profile(mcpServers: [@marked], mcpIdentities: [identity()])])

      assert {:ok, _result} = reconcile(conn, cilium: false)
      assert %{"status" => "False"} = condition("MCPIdentityMissing")
      assert get(identities)

      without =
        {"troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev"}
        |> get()
        |> put_in(["spec", "mcpServers"], [])
        |> put_in(["spec", "mcpIdentities"], [])

      assert {:ok, %{pruned: 1}} = Reconcilers.reconcile(conn, without)
      refute get(identities)
    end
  end

  describe "UpgradePending" do
    # The StatefulSet rolls `OnDelete`, so after an upgrade a pod keeps its old image
    # until somebody deletes it, and this condition is the only thing that says which
    # pods those are. The pods here carry what the StatefulSet controller gives them: the
    # template's labels and the revision they were made from.

    test "names each pod still on an older revision, and no other" do
      conn =
        FakeCluster.start([
          policy(),
          profile(),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a"),
          pod("troupe-w-dev-0", "troupe-w-dev-a"),
          pod("troupe-w-dev-1", "troupe-w-dev-b"),
          # Somebody's debugging pod in the same namespace is not the StatefulSet's, and
          # has no revision to be behind on.
          debug_pod("toolbox")
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert %{"status" => "True", "reason" => "WaitingForIdle", "message" => message} =
               condition("UpgradePending")

      assert message == "1 pod(s) run an older revision: troupe-w-dev-0 waits to be drained"

      # And the same, for the plane, with the uid that tells this pod from the one that
      # will replace it under the same name.
      assert status()["podsBehind"] == [
               %{"pod" => "troupe-w-dev-0", "uid" => "uid-troupe-w-dev-0", "revision" => "troupe-w-dev-a"}
             ]
    end

    test "is false once every pod runs the revision the StatefulSet wants" do
      conn =
        FakeCluster.start([
          policy(),
          profile(),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a"),
          pod("troupe-w-dev-0", "troupe-w-dev-b"),
          pod("troupe-w-dev-1", "troupe-w-dev-b")
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)
      assert %{"status" => "False", "reason" => "UpToDate"} = condition("UpgradePending")
      assert status()["podsBehind"] == []
    end

    test "trusts the pods over currentRevision, which OnDelete never moves" do
      # A template put back to the revision the StatefulSet still calls current: both
      # revisions are `a`, and both pods run `b`.
      conn =
        FakeCluster.start([
          policy(),
          profile(),
          stateful_set(update: "troupe-w-dev-a", current: "troupe-w-dev-a"),
          pod("troupe-w-dev-0", "troupe-w-dev-b"),
          pod("troupe-w-dev-1", "troupe-w-dev-b")
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert %{"status" => "True", "message" => message} = condition("UpgradePending")
      assert message =~ "2 pod(s)"
      assert message =~ "troupe-w-dev-0 waits to be drained, troupe-w-dev-1 waits to be drained"
    end
  end

  describe "finishing an upgrade" do
    # The plane records a pod once its drain has finished, with the revision it ran, and
    # the pod stops being Ready as its drain starts. The operator deletes a pod only when
    # all three say so, and the StatefulSet makes it again on the new revision.

    test "deletes a pod that is behind and that the plane has drained" do
      conn =
        FakeCluster.start([
          policy(),
          drained_profile(%{"troupe-w-dev-1" => "troupe-w-dev-a"}),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-b"),
          pod("troupe-w-dev-1", "troupe-w-dev-a", ready: false)
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert FakeCluster.deleted() == [{"v1", "Pod", "troupe-w-dev", "troupe-w-dev-1"}]

      assert condition("UpgradePending")["message"] ==
               "1 pod(s) run an older revision: troupe-w-dev-1 is being replaced"

      # Being replaced is the operator's business now, not a pod for the plane to drain.
      assert status()["podsBehind"] == []
    end

    test "keeps a pod that is behind and that the plane has not drained" do
      # Not Ready, so a drain has started, and its sessions may still be being sealed.
      conn =
        FakeCluster.start([
          policy(),
          profile(),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-a"),
          pod("troupe-w-dev-1", "troupe-w-dev-a", ready: false)
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert FakeCluster.deleted() == []

      assert condition("UpgradePending")["message"] ==
               "2 pod(s) run an older revision: troupe-w-dev-0 waits to be drained, troupe-w-dev-1 is draining"
    end

    test "keeps a drained pod that is Ready again, or was drained on another revision" do
      # Ordinal 1 restarted after its drain was recorded, so it is taking work again.
      # Ordinal 0 was recorded on a revision it no longer runs.
      conn =
        FakeCluster.start([
          policy(),
          drained_profile(%{"troupe-w-dev-0" => "troupe-w-dev-z", "troupe-w-dev-1" => "troupe-w-dev-a"}),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-a", ready: false),
          pod("troupe-w-dev-1", "troupe-w-dev-a")
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)
      assert FakeCluster.deleted() == []
    end

    test "replaces one pod at a time, the highest ordinal first" do
      conn =
        FakeCluster.start([
          policy(),
          drained_profile(%{
            "troupe-w-dev-0" => "troupe-w-dev-a",
            "troupe-w-dev-1" => "troupe-w-dev-a",
            "troupe-w-dev-2" => "troupe-w-dev-a"
          }),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 3),
          pod("troupe-w-dev-0", "troupe-w-dev-a", ready: false),
          pod("troupe-w-dev-1", "troupe-w-dev-a", ready: false),
          pod("troupe-w-dev-2", "troupe-w-dev-a", ready: false)
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert FakeCluster.deleted() == [{"v1", "Pod", "troupe-w-dev", "troupe-w-dev-2"}]

      assert condition("UpgradePending")["message"] ==
               "3 pod(s) run an older revision: troupe-w-dev-0 is drained and waits its turn, " <>
                 "troupe-w-dev-1 is drained and waits its turn, troupe-w-dev-2 is being replaced"
    end

    test "replaces none while another pod is going or has not come back" do
      drained = %{"troupe-w-dev-0" => "troupe-w-dev-a"}

      terminating =
        FakeCluster.start([
          policy(),
          drained_profile(drained),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-a", ready: false),
          pod("troupe-w-dev-1", "troupe-w-dev-a", ready: false, terminating: true)
        ])

      assert {:ok, _result} = reconcile(terminating, cilium: false)
      assert FakeCluster.deleted() == []

      assert condition("UpgradePending")["message"] ==
               "2 pod(s) run an older revision: troupe-w-dev-0 is drained and waits its turn, " <>
                 "troupe-w-dev-1 is being replaced"

      stop_supervised!(FakeCluster)

      # Ordinal 1 is gone and the StatefulSet has not made it again yet.
      missing =
        FakeCluster.start([
          policy(),
          drained_profile(drained),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-a", ready: false)
        ])

      assert {:ok, _result} = reconcile(missing, cilium: false)
      assert FakeCluster.deleted() == []
    end

    test "never deletes a pod on the current revision, whatever the plane recorded" do
      conn =
        FakeCluster.start([
          policy(),
          drained_profile(%{"troupe-w-dev-0" => "troupe-w-dev-b", "troupe-w-dev-1" => "troupe-w-dev-b"}),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-b", ready: false),
          pod("troupe-w-dev-1", "troupe-w-dev-b", ready: false)
        ])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert FakeCluster.deleted() == []
      assert %{"status" => "False"} = condition("UpgradePending")
    end

    test "deletes nothing for a profile outside the policy" do
      conn =
        FakeCluster.start([
          policy(maxReplicas: 1),
          drained_profile(%{"troupe-w-dev-1" => "troupe-w-dev-a"}),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-b"),
          pod("troupe-w-dev-1", "troupe-w-dev-a", ready: false)
        ])

      assert {:error, {:policy_violation, _}} = reconcile(conn, cilium: false)
      assert FakeCluster.deleted() == []
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
    status()
    |> Map.get("conditions")
    |> Enum.find(&(&1["type"] == type))
  end

  defp status do
    {"troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev"}
    |> get()
    |> Map.get("status")
  end

  # A gateway on 8443 and an MCP server at an address on the office network, which the
  # policy allows and a worker without Cilium does not reach.
  defp unreachable_profile do
    profile(
      llm: %{
        "endpoint" => "https://llm.internal.test:8443/v1",
        "secretRef" => %{"name" => "llm-credentials", "key" => "api-key"}
      },
      mcpServers: [%{"name" => "tickets", "url" => "https://10.20.0.5/tickets"}]
    )
  end

  defp unreachable_policy,
    do: policy(allowedEgress: ["*.anthropic.com", "llm.internal.test", "github.com", "10.20.0.5"])

  defp identity do
    %{
      "server" => "jira",
      "clientId" => "client-dev",
      "transitKey" => "troupe-w-dev.jira",
      "certificateThumbprint" => String.duplicate("A", 43)
    }
  end

  # The profile with the plane's record of the drains it has finished.
  defp drained_profile(drained) do
    put_in(profile(), ["metadata", "annotations"], %{
      Profile.drained_annotation() => Profile.encode_drained(drained)
    })
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

  # The profile's StatefulSet as the cluster reports it, with the selector the operator
  # gave it and the two revisions its controller keeps.
  defp stateful_set(opts) do
    spec =
      %{"selector" => %{"matchLabels" => Names.labels("dev")}}
      |> then(&if(opts[:replicas], do: Map.put(&1, "replicas", opts[:replicas]), else: &1))

    %{
      "apiVersion" => "apps/v1",
      "kind" => "StatefulSet",
      "metadata" => %{"name" => "troupe-w-dev", "namespace" => "troupe-w-dev"},
      "spec" => spec,
      "status" => %{"updateRevision" => opts[:update], "currentRevision" => opts[:current]}
    }
  end

  # A pod the StatefulSet made: its template's labels, which are not the operator's
  # marker, the revision it was made from, and whether it is Ready — which a worker is
  # not once its drain has started — or already going.
  defp pod(name, revision, opts \\ []) do
    labels =
      "dev"
      |> Names.labels()
      |> Map.merge(%{
        "controller-revision-hash" => revision,
        "statefulset.kubernetes.io/pod-name" => name
      })

    metadata =
      %{"name" => name, "namespace" => "troupe-w-dev", "uid" => "uid-" <> name, "labels" => labels}
      |> then(&if(opts[:terminating], do: Map.put(&1, "deletionTimestamp", "2026-09-29T10:00:00Z"), else: &1))

    ready = if Keyword.get(opts, :ready, true), do: "True", else: "False"

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => metadata,
      "status" => %{"conditions" => [%{"type" => "Ready", "status" => ready}]}
    }
  end

  defp debug_pod(name) do
    metadata = %{"name" => name, "namespace" => "troupe-w-dev", "labels" => %{"run" => name}}
    %{"apiVersion" => "v1", "kind" => "Pod", "metadata" => metadata}
  end

  defp kinds(resources), do: MapSet.new(resources, &{&1["apiVersion"], &1["kind"]})
end
