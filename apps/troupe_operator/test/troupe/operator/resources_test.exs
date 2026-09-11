defmodule Troupe.Operator.ResourcesTest do
  @moduledoc """
  What one `WorkerProfile` becomes.

  This is the function the operator's correctness mostly rests on, and it is pure, so
  the interesting cases can be checked here rather than by waiting on a cluster. The
  cluster test that follows proves the objects are accepted; these prove they say what
  they should.
  """

  use ExUnit.Case, async: true

  import Troupe.Operator.Fixtures

  alias Troupe.Operator.{Names, Resources, Settings}
  alias Troupe.Policy
  alias Troupe.WorkerProfile, as: Profile

  setup do
    profile = Profile.from_resource(profile())
    policy = Policy.from_resource(policy())
    settings = %Settings{tls_secret_name: "workers-tls"}

    %{
      resources: Resources.for_profile(profile, policy, settings),
      profile: profile,
      policy: policy,
      settings: settings
    }
  end

  test "every object listed in the architecture exists", %{resources: resources} do
    assert find(resources, "Namespace", "troupe-w-dev")
    assert find(resources, "ServiceAccount", "troupe-worker")
    assert find(resources, "StatefulSet", "troupe-w-dev")
    assert find(resources, "Service", "troupe-w-dev")
    assert find(resources, "NetworkPolicy", "troupe-w-dev")
    assert find(resources, "PodDisruptionBudget", "troupe-w-dev")

    # One Service and one Ingress per pod, addressed by ordinal.
    assert find(resources, "Service", "dev-0")
    assert find(resources, "Service", "dev-1")
    assert find(resources, "Ingress", "dev-0")
    assert find(resources, "Ingress", "dev-1")

    # One claim per granted team volume, plus the org volume.
    assert find(resources, "PersistentVolumeClaim", "team-dev")
    assert find(resources, "PersistentVolumeClaim", "team-ux")
    assert find(resources, "PersistentVolumeClaim", "org")
  end

  test "everything namespaced lands in the profile's namespace and carries its labels",
       %{resources: resources} do
    for resource <- resources, resource["kind"] != "Namespace" do
      assert get_in(resource, ["metadata", "namespace"]) == "troupe-w-dev",
             "#{resource["kind"]}/#{get_in(resource, ["metadata", "name"])} is in the wrong namespace"

      assert get_in(resource, ["metadata", "labels", "troupe.dev/profile"]) == "dev"
    end
  end

  test "what the operator wrote is marked, and what Kubernetes writes for it is not",
       %{resources: resources} do
    # A StatefulSet copies its selector onto the PVCs it creates from its volume claim
    # templates, so a live session's working copy would otherwise look exactly like
    # something to prune. It did, once.
    for resource <- resources do
      assert get_in(resource, ["metadata", "labels", Names.managed_label()]) == "operator"
    end

    template = hd(get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "volumeClaimTemplates"]))
    refute get_in(template, ["metadata", "labels"])

    # And the selector stays what it was, because a StatefulSet's is immutable.
    selector = get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "selector", "matchLabels"])
    refute Map.has_key?(selector, Names.managed_label())
    assert selector == Names.labels("dev")
  end

  test "nothing carries an owner reference, because one would not survive", %{resources: resources} do
    # Owner references may not cross namespaces, and these objects live in
    # `troupe-w-dev` while the profile lives in `troupe-system`. Kubernetes treats such
    # an owner as missing and garbage-collects the dependent — which it did, once,
    # taking a whole StatefulSet with it seconds after the operator created it.
    for resource <- resources do
      refute get_in(resource, ["metadata", "ownerReferences"]),
             "#{resource["kind"]}/#{get_in(resource, ["metadata", "name"])} has an owner reference"
    end
  end

  test "every object is identifiable for pruning", %{resources: resources} do
    identities = Resources.identities(resources)

    assert MapSet.member?(identities, {"apps/v1", "StatefulSet", "troupe-w-dev"})
    assert MapSet.member?(identities, {"networking.k8s.io/v1", "Ingress", "dev-1"})
    assert MapSet.size(identities) == length(resources)
  end

  test "scaling down removes an ingress from the desired set, so pruning will delete it",
       %{policy: policy, settings: settings} do
    two = profile() |> Profile.from_resource() |> Resources.for_profile(policy, settings)
    one = [replicas: 1] |> profile() |> Profile.from_resource() |> Resources.for_profile(policy, settings)

    gone = MapSet.difference(Resources.identities(two), Resources.identities(one))

    assert MapSet.member?(gone, {"networking.k8s.io/v1", "Ingress", "dev-1"})
    assert MapSet.member?(gone, {"v1", "Service", "dev-1"})
  end

  describe "addressing" do
    test "each pod is reachable at <ordinal>.<profile>.workers.<domain>", %{resources: resources} do
      hosts =
        resources
        |> all("Ingress")
        |> Enum.map(&get_in(&1, ["spec", "rules", Access.at(0), "host"]))

      assert hosts == ["0.dev.workers.example.test", "1.dev.workers.example.test"]
    end

    test "a per-pod Service selects exactly one pod", %{resources: resources} do
      selector = get_in(find(resources, "Service", "dev-1"), ["spec", "selector"])
      assert selector["statefulset.kubernetes.io/pod-name"] == "troupe-w-dev-1"
    end

    test "the headless Service is the StatefulSet's, and has no cluster IP", %{resources: resources} do
      assert get_in(find(resources, "Service", "troupe-w-dev"), ["spec", "clusterIP"]) == "None"
      assert get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "serviceName"]) == "troupe-w-dev"
    end

    test "the ingress carries a long read timeout, because the harness connection is one",
         %{resources: resources} do
      annotations = get_in(find(resources, "Ingress", "dev-0"), ["metadata", "annotations"])
      assert annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] == "3600"
    end

    test "TLS is attached per host when the installation has a certificate", %{resources: resources} do
      assert [%{"hosts" => ["0.dev.workers.example.test"], "secretName" => "workers-tls"}] =
               get_in(find(resources, "Ingress", "dev-0"), ["spec", "tls"])
    end
  end

  describe "identity" do
    test "the ServiceAccount token is not automounted", %{resources: resources} do
      assert find(resources, "ServiceAccount", "troupe-worker")["automountServiceAccountToken"] == false

      pod = pod_spec(resources)
      assert pod["automountServiceAccountToken"] == false
      assert pod["serviceAccountName"] == "troupe-worker"
    end

    test "the pod gets audience-scoped tokens and nothing else", %{resources: resources} do
      token = Enum.find(pod_spec(resources)["volumes"], &(&1["name"] == "enrolment-token"))
      sources = Enum.map(get_in(token, ["projected", "sources"]), & &1["serviceAccountToken"])

      by_audience = Map.new(sources, &{&1["audience"], &1})

      # Two, and each good in exactly one place: the token the plane accepts cannot open
      # a session key, and the one the key manager accepts cannot enrol.
      assert Map.keys(by_audience) |> Enum.sort() ==
               Enum.sort([Names.enrolment_audience(), Names.kms_audience()])

      assert by_audience["troupe-plane"]["path"] == "token"
      assert by_audience["troupe-kms"]["path"] == "kms-token"

      # A token scoped to one audience cannot be replayed against the Kubernetes API,
      # which is the point of not automounting the real one.
      for source <- sources, do: assert(source["expirationSeconds"] <= 3600)
    end
  end

  describe "volumes" do
    test "a team granted rw is mounted writable; one granted ro is not", %{resources: resources} do
      mounts = container(resources)["volumeMounts"]

      assert %{"mountPath" => "/mnt/teams/dev", "readOnly" => false} =
               Enum.find(mounts, &(&1["name"] == "team-dev"))

      assert %{"mountPath" => "/mnt/teams/ux", "readOnly" => true} =
               Enum.find(mounts, &(&1["name"] == "team-ux"))
    end

    test "the read-only grant is enforced by the claim, not only by the mount",
         %{resources: resources} do
      assert get_in(find(resources, "PersistentVolumeClaim", "team-ux"), ["spec", "accessModes"]) ==
               ["ReadOnlyMany"]

      assert get_in(find(resources, "PersistentVolumeClaim", "team-dev"), ["spec", "accessModes"]) ==
               ["ReadWriteMany"]
    end

    test "the org volume is read-only however it was asked for", %{resources: resources} do
      assert %{"readOnly" => true} =
               Enum.find(container(resources)["volumeMounts"], &(&1["name"] == "org"))

      assert get_in(find(resources, "PersistentVolumeClaim", "org"), ["spec", "accessModes"]) ==
               ["ReadOnlyMany"]
    end

    test "a profile without orgMount gets no org volume at all", %{policy: policy, settings: settings} do
      resources =
        [orgMount: false]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, settings)

      refute find(resources, "PersistentVolumeClaim", "org")
      refute Enum.find(container(resources)["volumeMounts"], &(&1["name"] == "org"))
    end

    test "each pod gets its own data volume from the StatefulSet's template",
         %{resources: resources} do
      assert [%{"metadata" => %{"name" => "data"}, "spec" => spec}] =
               get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "volumeClaimTemplates"])

      assert spec["accessModes"] == ["ReadWriteOnce"]
      assert %{"mountPath" => "/var/lib/troupe"} = Enum.find(container(resources)["volumeMounts"], &(&1["name"] == "data"))
    end
  end

  describe "the workload" do
    test "pods are replaced on delete, never rolled", %{resources: resources} do
      # A pod holds live sessions: a rolling update on an image change would kill work
      # in progress.
      assert get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "updateStrategy"]) ==
               %{"type" => "OnDelete"}
    end

    test "the pod is told where the plane, the KMS and object storage are",
         %{resources: resources} do
      env = Map.new(container(resources)["env"], &{&1["name"], &1["value"]})

      assert env["TROUPE_PROFILE"] == "dev"
      assert env["TROUPE_NAMESPACE"] == "troupe-w-dev"
      assert env["TROUPE_PLANE_CONTROL"] =~ "troupe-plane-control"
      assert env["TROUPE_BAO_ADDR"] =~ "openbao"
      assert env["TROUPE_OBJECT_BUCKET"] == "troupe-sessions"
      assert env["TROUPE_SESSIONS_PER_POD"] == "4"
    end

    test "the LLM credential arrives from a secret, never as a value", %{resources: resources} do
      key = Enum.find(container(resources)["env"], &(&1["name"] == "TROUPE_API_KEY"))

      assert get_in(key, ["valueFrom", "secretKeyRef"]) == %{
               "name" => "llm-credentials",
               "key" => "api-key"
             }

      refute Map.has_key?(key, "value")
    end

    test "the container drops every capability", %{resources: resources} do
      security = container(resources)["securityContext"]
      assert security["allowPrivilegeEscalation"] == false
      assert security["capabilities"]["drop"] == ["ALL"]
    end

    test "a disruption budget keeps more than one pod from going at once",
         %{resources: resources} do
      assert get_in(find(resources, "PodDisruptionBudget", "troupe-w-dev"), ["spec", "maxUnavailable"]) == 1
    end
  end

  describe "network" do
    test "the policy denies by default in both directions", %{resources: resources} do
      spec = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec"])
      assert Enum.sort(spec["policyTypes"]) == ["Egress", "Ingress"]
    end

    test "ingress comes only from the ingress controller, on the harness port",
         %{resources: resources} do
      assert [rule] = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "ingress"])
      assert [%{"namespaceSelector" => %{"matchLabels" => labels}}] = rule["from"]
      assert labels == %{"troupe.dev/ingress" => "true"}
      assert rule["ports"] == [%{"protocol" => "TCP", "port" => 4000}]
    end

    test "egress reaches DNS and the plane's control port", %{resources: resources} do
      rules = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "egress"])
      ports = rules |> Enum.flat_map(&(&1["ports"] || [])) |> Enum.map(& &1["port"])

      assert 53 in ports
      assert 4001 in ports
    end

    test "without Cilium there is no FQDN policy, and with it there is",
         %{profile: profile, policy: policy} do
      without = Resources.for_profile(profile, policy, %Settings{cilium_available: false})
      assert all(without, "CiliumNetworkPolicy") == []

      with_cilium = Resources.for_profile(profile, policy, %Settings{cilium_available: true})
      assert [cilium] = all(with_cilium, "CiliumNetworkPolicy")

      names =
        cilium
        |> get_in(["spec", "egress"])
        |> Enum.flat_map(&(&1["toFQDNs"] || []))
        |> Enum.map(& &1["matchName"])

      # Exactly what the profile declared, including the endpoints it would otherwise
      # have reached through a wide CIDR rule.
      assert "llm.internal.test" in names
      assert "mcp.internal.test" in names
      assert "api.anthropic.com" in names
      assert "github.com" in names
    end
  end

  test "scaling the profile changes how many pods are addressed", %{policy: policy, settings: settings} do
    resources =
      [replicas: 1]
      |> profile()
      |> Profile.from_resource()
      |> Resources.for_profile(policy, settings)

    assert length(all(resources, "Ingress")) == 1
    assert find(resources, "Ingress", "dev-0")
    refute find(resources, "Ingress", "dev-1")
    assert get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "replicas"]) == 1
  end

  defp pod_spec(resources) do
    get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "template", "spec"])
  end

  defp container(resources), do: hd(pod_spec(resources)["containers"])
end
