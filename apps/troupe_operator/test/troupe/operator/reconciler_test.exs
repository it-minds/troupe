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

  alias Troupe.Operator.{FakeCluster, Names, Reconciler, Reconcilers, Resources, Settings, SkipObserved}
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

  # The plane's control CA, read from the file the chart mounts on every pass: a renewed CA
  # reaches the namespace at the next pass, one this pass could not read leaves the CA
  # there, and an installation that stops giving pods one has it taken away.
  describe "the plane's CA" do
    @plane_ca {"v1", "ConfigMap", "troupe-w-dev", "troupe-plane-ca"}

    @tag :tmp_dir
    test "follows the file, and stays when the file is gone for a pass", %{tmp_dir: dir} do
      path = Path.join(dir, "ca.crt")
      conn = FakeCluster.start([policy(), profile()])

      first = ca_pem()
      File.write!(path, first)
      assert {:ok, _result} = reconcile(conn, plane_ca_path: path)
      assert get(@plane_ca)["data"] == %{"ca.crt" => first}

      renewed = ca_pem()
      File.write!(path, renewed)
      assert {:ok, %{pruned: 0}} = reconcile(conn, plane_ca_path: path)
      assert get(@plane_ca)["data"] == %{"ca.crt" => renewed}

      File.rm!(path)
      assert {:ok, %{pruned: 0}} = reconcile(conn, plane_ca_path: path)
      assert get(@plane_ca)["data"] == %{"ca.crt" => renewed}
      assert FakeCluster.deleted() == []
    end

    @tag :tmp_dir
    test "is taken away when the installation gives pods none", %{tmp_dir: dir} do
      path = Path.join(dir, "ca.crt")
      File.write!(path, ca_pem())
      conn = FakeCluster.start([policy(), profile()])

      assert {:ok, _result} = reconcile(conn, plane_ca_path: path)
      assert get(@plane_ca)

      assert {:ok, %{pruned: 1}} = reconcile(conn, plane_ca_path: nil)
      refute get(@plane_ca)
      assert FakeCluster.deleted() == [@plane_ca]
    end

    # Beside `SecretMissing`: the profile reconciled, and its pods wait for a file the
    # namespace does not have yet, which only the operator's log said.
    @tag :tmp_dir
    test "missing from the namespace is PlaneCAMissing, until a pass writes it", %{tmp_dir: dir} do
      path = Path.join(dir, "ca.crt")
      conn = FakeCluster.start([policy(), profile()])

      assert {:ok, _result} = reconcile(conn, plane_ca_path: path)
      refute get(@plane_ca)

      assert %{"status" => "True", "reason" => "NotWritten", "message" => message} =
               condition("PlaneCAMissing")

      assert message =~ "troupe-plane-ca"
      assert message =~ path

      File.write!(path, ca_pem())
      assert {:ok, _result} = reconcile(conn, plane_ca_path: path)
      assert %{"status" => "False", "reason" => "Present"} = condition("PlaneCAMissing")

      # A pass that cannot read the file leaves the CA there, and the namespace has one.
      File.rm!(path)
      assert {:ok, _result} = reconcile(conn, plane_ca_path: path)
      assert %{"status" => "False", "reason" => "Present"} = condition("PlaneCAMissing")
    end

    test "is not missing where the installation gives pods none" do
      conn = FakeCluster.start([policy(), profile()])

      assert {:ok, _result} = reconcile(conn, plane_ca_path: nil)
      assert %{"status" => "False", "reason" => "NotGiven"} = condition("PlaneCAMissing")
    end
  end

  # A namespace made by an operator that wrote no Pod Security labels, or labelled by hand,
  # is labelled at the next pass, keeping every other label it has.
  test "a worker namespace made without the Pod Security labels has them after a pass" do
    existing = %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => "troupe-w-dev", "labels" => Names.managed_labels("dev")}
    }

    conn = FakeCluster.start([policy(), profile(), existing])

    assert {:ok, _result} =
             reconcile_with(conn, pod_security_labels: true, worker_user_namespaces: true)

    labels = get({"v1", "Namespace", nil, "troupe-w-dev"})["metadata"]["labels"]
    assert labels["pod-security.kubernetes.io/enforce"] == "privileged"
    assert labels["pod-security.kubernetes.io/audit"] == "privileged"
    assert labels["pod-security.kubernetes.io/warn"] == "privileged"
    assert labels["troupe.dev/workers"] == "true"
  end

  describe "an egress entry that is not a pattern" do
    # A bare `*` in the policy used to admit a bare `*` in a profile, and the operator wrote
    # it as a `matchPattern` that is every name there is.
    test "in a profile and in the policy, is refused naming it, and nothing is written" do
      allowed = policy()["spec"]["allowedEgress"] ++ ["*"]
      starred = profile(egress: %{"fqdns" => ["*"], "gitHosts" => []})
      conn = FakeCluster.start([policy(allowedEgress: allowed), starred])

      assert {:error, {:policy_violation, violations}} = reconcile(conn, cilium: true)
      assert {:egress_not_a_pattern, "*"} in violations
      assert {:allowed_egress_not_a_pattern, "*"} in violations
      refute get(@cilium_policy)

      assert %{"status" => "True", "message" => message} = condition("PolicyViolation")
      assert message =~ "egress entry *"
      assert message =~ "allowedEgress entry *"
    end
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

  describe "EndpointUnreachable (Decisions 749 and 758)" do
    # In gitops mode a profile is applied by something else, so nothing refuses it where
    # it is written: the operator says on the profile what its workers will not reach, as
    # it says a Secret is missing, and the console shows it.

    test "with Cilium, names each endpoint at a loopback or link-local address, and admits none" do
      # Issue #355: the condition said `Cilium`, and both addresses went into a `toCIDR`
      # rule because the policy's `allowedEgress` names them.
      conn = FakeCluster.start([local_policy(), local_profile()])

      assert {:ok, _result} = reconcile(conn, cilium: true)

      assert %{"status" => "True", "reason" => "LoopbackOrLinkLocal", "message" => message} =
               condition("EndpointUnreachable")

      assert message =~
               "llm.endpoint http://127.0.0.1:4000/v1 is at 127.0.0.1, a loopback address"

      assert message =~
               "MCP server meta at http://169.254.169.254/latest is at 169.254.169.254, a link-local address"

      assert message =~ "metadata"

      rules = @cilium_policy |> get() |> get_in(["spec", "egress"])
      refute Enum.any?(rules, &Map.has_key?(&1, "toCIDR"))

      # Beside `Ready`, as `SecretMissing` is: everything the profile implies was made.
      assert condition("Ready")["status"] == "True"

      # And without Cilium, word for word.
      assert {:ok, _result} = reconcile(conn, cilium: false)

      assert %{"status" => "True", "reason" => "LoopbackOrLinkLocal", "message" => ^message} =
               condition("EndpointUnreachable")

      assert condition("Ready")["status"] == "True"
    end

    test "without Cilium, a gateway on another port and a server at a private address are reached" do
      # Issue #268: both were reported, and refused where they were set up, because the
      # NetworkPolicy admitted neither. It admits them now, by the same judgement the
      # condition makes, so the two say the same thing.
      conn = FakeCluster.start([office_policy(), office_profile()])

      assert {:ok, _result} = reconcile(conn, cilium: false)
      assert %{"status" => "False", "reason" => "Reachable"} = condition("EndpointUnreachable")

      rules =
        {"networking.k8s.io/v1", "NetworkPolicy", "troupe-w-dev", "troupe-w-dev"}
        |> get()
        |> get_in(["spec", "egress"])

      assert Enum.any?(rules, &(&1["ports"] == [%{"protocol" => "TCP", "port" => 8443}]))

      assert %{
               "to" => [%{"ipBlock" => %{"cidr" => "10.20.0.5/32"}}],
               "ports" => [%{"protocol" => "TCP", "port" => 443}]
             } in rules
    end

    test "with Cilium, a gateway on another port and a server at a private address are reached" do
      conn = FakeCluster.start([office_policy(), office_profile()])

      assert {:ok, _result} = reconcile(conn, cilium: true)
      assert %{"status" => "False", "reason" => "Cilium"} = condition("EndpointUnreachable")

      rules = @cilium_policy |> get() |> get_in(["spec", "egress"])
      assert %{"toCIDR" => ["10.20.0.5/32"]} in rules
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

    # A pod made before its namespace had the plane's CA dials in plaintext, and a plane
    # that takes TLS only closes it: it cannot enrol, so the plane can never drain it, and
    # until this the upgrade waited on it for good, with the sessions on it cut off.
    test "replaces a pod that dials in plaintext where the plane takes TLS only, undrained" do
      conn =
        FakeCluster.start([
          policy(),
          profile(),
          stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 2),
          pod("troupe-w-dev-0", "troupe-w-dev-b", tls: true),
          pod("troupe-w-dev-1", "troupe-w-dev-a", tls: false)
        ])

      assert {:ok, _result} =
               reconcile_with(conn, plane_ca_path: "/nonexistent/ca.crt", plane_require_tls: true)

      assert FakeCluster.deleted() == [{"v1", "Pod", "troupe-w-dev", "troupe-w-dev-1"}]

      assert condition("UpgradePending")["message"] ==
               "1 pod(s) run an older revision: troupe-w-dev-1 is being replaced"
    end

    test "waits for the drain of a plaintext pod while the plane takes plaintext, or a TLS one" do
      for {settings, tls?} <- [
            {[plane_ca_path: "/nonexistent/ca.crt", plane_require_tls: false], false},
            {[plane_ca_path: "/nonexistent/ca.crt", plane_require_tls: true], true},
            # No CA for the current revision either: a replacement would dial as it does.
            {[plane_ca_path: nil, plane_require_tls: true], false}
          ] do
        conn =
          FakeCluster.start([
            policy(),
            profile(),
            stateful_set(update: "troupe-w-dev-b", current: "troupe-w-dev-a", replicas: 1),
            pod("troupe-w-dev-0", "troupe-w-dev-a", tls: tls?)
          ])

        assert {:ok, _result} = reconcile_with(conn, settings)
        assert FakeCluster.deleted() == [], inspect(settings)

        assert condition("UpgradePending")["message"] ==
                 "1 pod(s) run an older revision: troupe-w-dev-0 waits to be drained"

        stop_supervised!(FakeCluster)
      end
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

  # #655 slice 4: a profile that extends another is run as the plane resolved it into its
  # status, never from what differs from its parent, and waits until the plane has.
  describe "a profile that extends another" do
    @set {"apps/v1", "StatefulSet", "troupe-w-dev", "troupe-w-dev"}

    test "waits, creating nothing, until the plane has written the profile in effect" do
      conn = FakeCluster.start([policy(), child(nil)])

      assert {:ok, :awaiting_plane} = reconcile(conn, cilium: false)
      refute get(@set)
      refute get({"v1", "Namespace", nil, "troupe-w-dev"})

      assert %{"status" => "False", "reason" => "AwaitingPlane", "message" => message} =
               condition("Resolved")

      assert message =~ "dev extends standard"
      assert %{"status" => "False", "reason" => "AwaitingPlane"} = condition("Ready")
    end

    test "runs the profile in effect from its status, and records which" do
      conn = FakeCluster.start([policy(), child(effective())])

      assert {:ok, _result} = reconcile(conn, cilium: false)

      [container | _] = get(@set)["spec"]["template"]["spec"]["containers"]
      assert container["image"] == "ghcr.io/objective-mj/troupe-worker:0.2.0"
      assert %{"status" => "True", "message" => message} = condition("Resolved")
      assert message =~ "standard → dev"
      assert status()["effectiveRevision"] == "rev-1"
      # The block is the plane's, and the pass left it as it was.
      assert status()["effective"]["revision"] == "rev-1"
      assert SkipObserved.observed?(get({"troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev"}))
    end

    test "is refused as any profile is when what is in effect is outside the policy" do
      conn = FakeCluster.start([policy(maxSessionsPerPod: 2), child(effective())])

      assert {:error, {:policy_violation, _}} = reconcile(conn, cilium: false)
      refute get(@set)
    end

    test "a new resolution is acted on at once, though the generation has not moved" do
      resource =
        child(effective())
        |> put_in(["status", "observedGeneration"], 1)
        |> put_in(["status", "effectiveRevision"], "rev-0")

      refute SkipObserved.observed?(resource)
      assert SkipObserved.observed?(put_in(resource, ["status", "effectiveRevision"], "rev-1"))

      # A profile that extends none is judged by its generation alone, as before.
      assert SkipObserved.observed?(put_in(profile(), ["status"], %{"observedGeneration" => 1}))
    end
  end

  # What a repository holds for a child: the parent named and the plane's three fields, with
  # the profile in effect the plane wrote into the status, or none yet.
  defp child(effective) do
    resource = %{
      profile()
      | "spec" => %{"extends" => "standard", "replicas" => 2, "teams" => []}
    }

    if effective, do: Map.put(resource, "status", %{"effective" => effective}), else: resource
  end

  defp effective do
    %{
      "spec" => Map.drop(profile()["spec"], ["replicas", "teams", "mcpServers"]),
      "chain" => ["standard", "dev"],
      "revision" => "rev-1"
    }
  end

  # One pass, with the installation's settings as Helm would have rendered them, over the
  # profile as the cluster holds it now: with the status the last pass wrote.
  defp reconcile(conn, cilium: cilium?), do: reconcile_with(conn, cilium_available: cilium?)
  defp reconcile(conn, plane_ca_path: path), do: reconcile_with(conn, plane_ca_path: path)

  defp reconcile_with(conn, settings) do
    Application.put_env(:troupe_operator, :settings, settings)

    Reconcilers.reconcile(
      conn,
      get({"troupe.dev/v1alpha1", "WorkerProfile", "troupe-system", "dev"})
    )
  end

  defp ca_pem do
    %{cert: der} =
      :public_key.pkix_test_root_cert(~c"troupe-plane-control-ca", [
        {:key, {:namedCurve, :secp256r1}}
      ])

    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
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
  # policy allows and a worker without Cilium reaches by a rule of their own.
  defp office_profile do
    profile(
      llm: %{
        "endpoint" => "https://llm.internal.test:8443/v1",
        "secretRef" => %{"name" => "llm-credentials", "key" => "api-key"}
      },
      mcpServers: [%{"name" => "tickets", "url" => "https://10.20.0.5/tickets"}]
    )
  end

  defp office_policy,
    do: policy(allowedEgress: ["*.anthropic.com", "llm.internal.test", "github.com", "10.20.0.5"])

  # A gateway on the pod's own loopback and a server at the cloud's metadata address, which
  # the policy allows and no rule admits.
  defp local_profile do
    profile(
      llm: %{
        "endpoint" => "http://127.0.0.1:4000/v1",
        "secretRef" => %{"name" => "llm-credentials", "key" => "api-key"}
      },
      mcpServers: [%{"name" => "meta", "url" => "http://169.254.169.254/latest"}]
    )
  end

  defp local_policy,
    do: policy(allowedEgress: ["*.anthropic.com", "github.com", "127.0.0.1", "169.254.169.254"])

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
    |> then(
      &if(Keyword.has_key?(opts, :tls),
        do: Map.put(&1, "spec", worker_spec(opts[:tls])),
        else: &1
      )
    )
  end

  # The worker container as a revision renders it: told where the plane's CA is exactly
  # when it dials with TLS.
  defp worker_spec(tls?) do
    env =
      if tls?,
        do: [%{"name" => "TROUPE_PLANE_CA_PATH", "value" => "/etc/troupe/plane-ca/ca.crt"}],
        else: []

    %{
      "containers" => [
        %{"name" => "worker", "env" => [%{"name" => "TROUPE_PROFILE", "value" => "dev"} | env]}
      ]
    }
  end

  defp debug_pod(name) do
    metadata = %{"name" => name, "namespace" => "troupe-w-dev", "labels" => %{"run" => name}}
    %{"apiVersion" => "v1", "kind" => "Pod", "metadata" => metadata}
  end

  defp kinds(resources), do: MapSet.new(resources, &{&1["apiVersion"], &1["kind"]})
end
