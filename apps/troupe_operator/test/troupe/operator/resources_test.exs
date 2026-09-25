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
    # A region that is not the default, so an assertion about it is an assertion that the
    # value travelled rather than that two constants happen to match.
    settings = %Settings{tls_secret_name: "workers-tls", object_store_region: "fr-par"}

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

    template =
      hd(get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "volumeClaimTemplates"]))

    refute get_in(template, ["metadata", "labels"])

    # And the selector stays what it was, because a StatefulSet's is immutable.
    selector =
      get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "selector", "matchLabels"])

    refute Map.has_key?(selector, Names.managed_label())
    assert selector == Names.labels("dev")
  end

  test "nothing carries an owner reference, because one would not survive", %{
    resources: resources
  } do
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

    one =
      [replicas: 1]
      |> profile()
      |> Profile.from_resource()
      |> Resources.for_profile(policy, settings)

    gone = MapSet.difference(Resources.identities(two), Resources.identities(one))

    assert MapSet.member?(gone, {"networking.k8s.io/v1", "Ingress", "dev-1"})
    assert MapSet.member?(gone, {"v1", "Service", "dev-1"})
  end

  describe "addressing" do
    test "each pod is reachable at <ordinal>-<profile>.workers.<domain>", %{resources: resources} do
      hosts =
        resources
        |> all("Ingress")
        |> Enum.map(&get_in(&1, ["spec", "rules", Access.at(0), "host"]))

      assert hosts == ["0-dev.workers.example.test", "1-dev.workers.example.test"]
    end

    test "a pod's host is one label under the workers domain, so one wildcard covers all",
         %{resources: resources} do
      # The property, not the spelling: a DNS wildcard matches exactly one label, so
      # `*.workers.example.test` covers a pod only while the ordinal and the profile
      # share a label. A dot between them would need a record and a certificate per
      # profile, and creating a profile in the panel would stop being self-service.
      for ingress <- all(resources, "Ingress") do
        host = get_in(ingress, ["spec", "rules", Access.at(0), "host"])
        assert String.ends_with?(host, ".workers.example.test")

        label = String.replace_suffix(host, ".workers.example.test", "")
        refute String.contains?(label, "."), "#{host} is more than one label deep"
      end
    end

    test "a per-pod Service selects exactly one pod", %{resources: resources} do
      selector = get_in(find(resources, "Service", "dev-1"), ["spec", "selector"])
      assert selector["statefulset.kubernetes.io/pod-name"] == "troupe-w-dev-1"
    end

    test "the headless Service is the StatefulSet's, and has no cluster IP", %{
      resources: resources
    } do
      assert get_in(find(resources, "Service", "troupe-w-dev"), ["spec", "clusterIP"]) == "None"

      assert get_in(find(resources, "StatefulSet", "troupe-w-dev"), ["spec", "serviceName"]) ==
               "troupe-w-dev"
    end

    test "the ingress carries a long read timeout, because the harness connection is one",
         %{resources: resources} do
      annotations = get_in(find(resources, "Ingress", "dev-0"), ["metadata", "annotations"])
      assert annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] == "3600"
    end

    test "TLS is attached per host when the installation has a certificate", %{
      resources: resources
    } do
      assert [%{"hosts" => ["0-dev.workers.example.test"], "secretName" => "workers-tls"}] =
               get_in(find(resources, "Ingress", "dev-0"), ["spec", "tls"])
    end

    test "a cert-manager issuer gives each pod its own certificate and its own secret",
         %{profile: profile, policy: policy} do
      settings = %Settings{
        ingress_class_name: "nginx",
        cert_issuer: "letsencrypt",
        tls_secret_name: "workers-tls"
      }

      resources = Resources.for_profile(profile, policy, settings)

      for ordinal <- [0, 1] do
        ingress = find(resources, "Ingress", "dev-#{ordinal}")
        host = "#{ordinal}-dev.workers.example.test"

        # Its own secret, so two pods do not overwrite each other's certificate, and the
        # issuer annotation, which is what makes cert-manager fill it.
        assert [%{"hosts" => [^host], "secretName" => secret}] = get_in(ingress, ["spec", "tls"])
        assert secret == "dev-#{ordinal}-tls"

        annotations = get_in(ingress, ["metadata", "annotations"])
        assert annotations["cert-manager.io/cluster-issuer"] == "letsencrypt"
        # And the controller's own annotations are still there.
        assert annotations["nginx.ingress.kubernetes.io/proxy-read-timeout"] == "3600"
      end
    end

    test "the issuer wins over a shared secret, because both would be a certificate nobody owns",
         %{profile: profile, policy: policy} do
      settings = %Settings{cert_issuer: "letsencrypt", tls_secret_name: "workers-tls"}
      resources = Resources.for_profile(profile, policy, settings)

      assert [%{"secretName" => "dev-0-tls"}] =
               get_in(find(resources, "Ingress", "dev-0"), ["spec", "tls"])
    end
  end

  describe "identity" do
    test "the ServiceAccount token is not automounted", %{resources: resources} do
      assert find(resources, "ServiceAccount", "troupe-worker")["automountServiceAccountToken"] ==
               false

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

    test "the claim that is created is the claim that is mounted", %{policy: policy, settings: settings} do
      # The plane names a team's claim `troupe-team-<name>`; the operator's own default is
      # `team-<name>`. The mount preferred the plane's name and creation always used the
      # operator's, so the operator built a claim nothing referenced and asked the
      # scheduler for one that did not exist. A pod in that state is not degraded — it is
      # `Pending` forever, which is every session on the profile.
      #
      # Asserted as one equality rather than two literals, because two literals is what
      # the bug was.
      profile =
        Profile.from_resource(
          profile(
            teams: [
              %{
                "name" => "platform-admins",
                "claimName" => "troupe-team-platform-admins",
                "mode" => "ro",
                "storageClassName" => "standard",
                "size" => "10Gi"
              }
            ]
          )
        )

      resources = Resources.for_profile(profile, policy, settings)

      mounted =
        container(resources)["volumeMounts"]
        |> Enum.find(&(&1["mountPath"] == "/mnt/teams/platform-admins"))

      volume =
        get_in(find(resources, "StatefulSet", "troupe-w-dev"), [
          "spec",
          "template",
          "spec",
          "volumes"
        ])
        |> Enum.find(&(&1["name"] == mounted["name"]))

      claimed = get_in(volume, ["persistentVolumeClaim", "claimName"])

      assert claimed == "troupe-team-platform-admins"
      assert find(resources, "PersistentVolumeClaim", claimed)
    end

    test "a team that declares no claim name still gets the operator's own",
         %{resources: resources} do
      # The fixture's teams declare none, which is why this bug hid: both sides computed
      # `team-<name>` and agreed by coincidence rather than by construction.
      assert find(resources, "PersistentVolumeClaim", Names.team_claim("dev"))
    end

    test "the org volume is read-only however it was asked for", %{resources: resources} do
      assert %{"readOnly" => true} =
               Enum.find(container(resources)["volumeMounts"], &(&1["name"] == "org"))

      assert get_in(find(resources, "PersistentVolumeClaim", "org"), ["spec", "accessModes"]) ==
               ["ReadOnlyMany"]
    end

    test "a profile without orgMount gets no org volume at all", %{
      policy: policy,
      settings: settings
    } do
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
               get_in(find(resources, "StatefulSet", "troupe-w-dev"), [
                 "spec",
                 "volumeClaimTemplates"
               ])

      assert spec["accessModes"] == ["ReadWriteOnce"]

      assert %{"mountPath" => "/var/lib/troupe"} =
               Enum.find(container(resources)["volumeMounts"], &(&1["name"] == "data"))
    end

    test "and the worker is told to write there", %{resources: resources} do
      # The mount was asserted above and the volume was empty on every cluster this has
      # ever run on: nothing set `TROUPE_STATE_HOME`, so the worker wrote to
      # `$HOME/.local/state/troupe` — the container's own ephemeral layer — and the claim
      # this profile provisions held nothing. Sealed segments, materialised bundles and
      # restored workspaces were all re-fetched on every restart, and the volume's size
      # class decided nothing.
      #
      # Asserted as the *same path* rather than as a literal, because a mount and an
      # environment variable that merely both exist is exactly the state this was in.
      env = Map.new(container(resources)["env"], &{&1["name"], &1["value"]})
      mount = Enum.find(container(resources)["volumeMounts"], &(&1["name"] == "data"))

      assert env["TROUPE_STATE_HOME"] == mount["mountPath"]
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
      # SigV4 signs the region string, so a pod left on the default signs `us-east-1` at
      # a bucket that is not there. The plane was always told; the pods, which write most
      # of a session's log, were not.
      assert env["TROUPE_OBJECT_REGION"] == "fr-par"
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
      assert get_in(find(resources, "PodDisruptionBudget", "troupe-w-dev"), [
               "spec",
               "maxUnavailable"
             ]) == 1
    end
  end

  describe "network" do
    test "the policy denies by default in both directions", %{resources: resources} do
      spec = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec"])
      assert Enum.sort(spec["policyTypes"]) == ["Egress", "Ingress"]
    end

    test "ingress comes only from the ingress controller, on the harness port",
         %{resources: resources} do
      assert [rule] =
               get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "ingress"])

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

      # Exactly what the profile declared — each destination once, and nothing it did not
      # declare.
      assert Enum.sort(names) ==
               Enum.sort([
                 "llm.internal.test",
                 "mcp.internal.test",
                 "api.anthropic.com",
                 "github.com"
               ])

      assert Enum.sort(names) == Enum.sort(Profile.egress_destinations(profile))
    end

    test "with Cilium, nothing reaches outside the cluster but the FQDN rules",
         %{profile: profile, policy: policy} do
      resources = Resources.for_profile(profile, policy, %Settings{cilium_available: true})
      rules = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "egress"])

      # Cilium admits the union of every policy that selects a pod, so one address block
      # in the NetworkPolicy would be wider than the allowlist whatever the FQDN rules say.
      refute Enum.any?(rules, fn rule -> Enum.any?(rule["to"], &Map.has_key?(&1, "ipBlock")) end)
      refute Jason.encode!(resources) =~ "0.0.0.0/0"

      # And nothing in either policy is open-ended: a NetworkPolicy rule with no `to` admits
      # every destination on its ports, and a Cilium rule with no peer is the same.
      assert Enum.all?(rules, &match?([_ | _], &1["to"]))

      [cilium] = all(resources, "CiliumNetworkPolicy")

      for rule <- get_in(cilium, ["spec", "egress"]) do
        assert match?([_ | _], rule["toEndpoints"]) or match?([_ | _], rule["toFQDNs"]),
               "an egress rule with no peer: #{inspect(rule)}"
      end
    end

    test "without Cilium, public addresses are open on 443 and 80 and nothing else is",
         %{profile: profile, policy: policy} do
      # Plain NetworkPolicy has no way to name a host, so this is the documented gap
      # (docs/admin/configuration.md, Part E) rather than the allowlist. Pinned, so that
      # widening it is a decision somebody makes on purpose.
      resources = Resources.for_profile(profile, policy, %Settings{cilium_available: false})
      rules = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "egress"])

      assert [public] =
               Enum.filter(rules, fn rule ->
                 Enum.any?(rule["to"], &Map.has_key?(&1, "ipBlock"))
               end)

      assert [%{"ipBlock" => %{"cidr" => "0.0.0.0/0", "except" => except}}] = public["to"]

      assert Enum.sort(except) == [
               "10.0.0.0/8",
               "169.254.0.0/16",
               "172.16.0.0/12",
               "192.168.0.0/16"
             ]

      assert public["ports"] == [
               %{"protocol" => "TCP", "port" => 443},
               %{"protocol" => "TCP", "port" => 80}
             ]
    end

    test "DNS is the cluster's resolver in kube-system, and nothing that merely carries its label",
         %{resources: resources} do
      rules = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "egress"])
      dns = Enum.filter(rules, fn rule -> Enum.any?(rule["ports"], &(&1["port"] == 53)) end)

      assert dns == [
               %{
                 "to" => [
                   %{
                     "namespaceSelector" => %{
                       "matchLabels" => %{"kubernetes.io/metadata.name" => "kube-system"}
                     },
                     "podSelector" => %{"matchLabels" => %{"k8s-app" => "kube-dns"}}
                   }
                 ],
                 "ports" => [
                   %{"protocol" => "UDP", "port" => 53},
                   %{"protocol" => "TCP", "port" => 53}
                 ]
               }
             ]
    end

    test "Cilium proxies DNS, which is how the FQDN rules learn an address at all",
         %{profile: profile, policy: policy} do
      [cilium] =
        profile
        |> Resources.for_profile(policy, %Settings{cilium_available: true})
        |> all("CiliumNetworkPolicy")

      # In a namespaced CiliumNetworkPolicy an endpoint selector without the namespace
      # label means the policy's own namespace, where no resolver runs; and without a
      # `dns` rule no lookup passes through the proxy, so `toFQDNs` never learns an address.
      assert [
               %{
                 "toEndpoints" => [
                   %{
                     "matchLabels" => %{
                       "k8s:io.kubernetes.pod.namespace" => "kube-system",
                       "k8s:k8s-app" => "kube-dns"
                     }
                   }
                 ],
                 "toPorts" => [
                   %{
                     "ports" => [%{"port" => "53", "protocol" => "ANY"}],
                     "rules" => %{"dns" => [%{"matchPattern" => "*"}]}
                   }
                 ]
               },
               %{"toFQDNs" => [_ | _]}
             ] = get_in(cilium, ["spec", "egress"])
    end

    test "a profile that names no host gets DNS and no FQDN rule", %{policy: policy} do
      resources =
        [llm: nil, mcpServers: [], egress: %{}]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, %Settings{cilium_available: true})

      [cilium] = all(resources, "CiliumNetworkPolicy")
      assert [dns] = get_in(cilium, ["spec", "egress"])
      assert Map.has_key?(dns, "toEndpoints")
    end

    test "a model gateway or MCP server inside the cluster is its namespace and port",
         %{policy: policy} do
      # A `.svc` name resolves to a Service address, which an FQDN rule cannot follow to
      # the pod behind it, so these are reached the way OpenBao and object storage are.
      resources =
        [
          llm: %{"endpoint" => "http://gateway.llm.svc:4000/v1"},
          mcpServers: [%{"name" => "docs", "url" => "http://docs.mcp.svc.cluster.local/mcp"}]
        ]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, %Settings{cilium_available: true})

      rules = get_in(find(resources, "NetworkPolicy", "troupe-w-dev"), ["spec", "egress"])

      assert namespace_rule("llm", 4000) in rules
      assert namespace_rule("mcp", 80) in rules
      assert namespace_rule("troupe-system", 8200) in rules
      assert namespace_rule("troupe-system", 9000) in rules
    end

    test "egress by hostname is reported only where the CiliumNetworkPolicy was written and applied",
         %{profile: profile, policy: policy} do
      # The plane shows this per profile and has no other way to know it, so each case is
      # pinned: a `True` here is a guarantee the console will claim.
      without = Resources.for_profile(profile, policy, %Settings{cilium_available: false})

      assert {false, "NoCilium", message} = Resources.egress_by_hostname(without, [])
      assert message =~ "checked at admission"
      assert message =~ "any public host on 443 and 80"

      with_cilium = Resources.for_profile(profile, policy, %Settings{cilium_available: true})
      assert {true, "CiliumFQDN", _message} = Resources.egress_by_hostname(with_cilium, [])

      # `ciliumAvailable: true` on a cluster without Cilium: the NetworkPolicy applies and
      # the CiliumNetworkPolicy is refused, so there are no rules by hostname to speak of.
      failed = all(with_cilium, "CiliumNetworkPolicy")

      assert {false, "CiliumPolicyNotApplied", _message} =
               Resources.egress_by_hostname(with_cilium, failed)

      # Any other failure is `Ready`'s business and leaves the FQDN rules standing.
      other = all(with_cilium, "PodDisruptionBudget")
      assert {true, "CiliumFQDN", _message} = Resources.egress_by_hostname(with_cilium, other)
    end

    test "a wildcard in the profile's egress becomes a pattern, and an exact name stays a name",
         %{policy: policy} do
      resources =
        [egress: %{"fqdns" => ["*.anthropic.com"], "gitHosts" => ["github.com"]}]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, %Settings{cilium_available: true})

      [cilium] = all(resources, "CiliumNetworkPolicy")
      selectors = cilium |> get_in(["spec", "egress"]) |> Enum.flat_map(&(&1["toFQDNs"] || []))

      assert %{"matchPattern" => "*.anthropic.com"} in selectors
      assert %{"matchName" => "github.com"} in selectors

      # `matchName` takes a star literally, and no DNS answer ever carries one, so a
      # wildcard rendered that way is a rule that allows nothing.
      refute Enum.any?(selectors, &String.contains?(&1["matchName"] || "", "*"))
    end
  end

  describe "MCP servers" do
    setup %{policy: policy, settings: settings} do
      servers = [
        %{
          "name" => "tickets",
          "url" => "https://mcp.internal.test/tickets",
          "secretRef" => %{"name" => "troupe-mcp-tickets", "key" => "token"}
        },
        %{"name" => "docs", "url" => "https://mcp.internal.test/docs", "timeoutMs" => 5000}
      ]

      resources =
        [mcpServers: servers]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, settings)

      %{env: container(resources)["env"]}
    end

    test "the pod is told its servers from the spec, before any bundle arrives", %{env: env} do
      value = Enum.find(env, &(&1["name"] == "TROUPE_MCP_SERVERS"))["value"]

      # The same shape `Troupe.MCP.Server.from_config/1` reads from a bundle push. The
      # server without a Secret carries no `credential_ref`, and fields the spec left
      # out are absent rather than null.
      assert Jason.decode!(value) == [
               %{
                 "name" => "tickets",
                 "url" => "https://mcp.internal.test/tickets",
                 "credential_ref" => "TROUPE_MCP_TICKETS_TOKEN"
               },
               %{
                 "name" => "docs",
                 "url" => "https://mcp.internal.test/docs",
                 "timeout_ms" => 5000
               }
             ]
    end

    test "a credential arrives from its Secret, under the name the list promised, and optionally",
         %{env: env} do
      token = Enum.find(env, &(&1["name"] == "TROUPE_MCP_TICKETS_TOKEN"))

      assert get_in(token, ["valueFrom", "secretKeyRef"]) == %{
               "name" => "troupe-mcp-tickets",
               "key" => "token",
               "optional" => true
             }

      refute Map.has_key?(token, "value")

      # A server without a Secret gets no variable at all.
      refute Enum.find(env, &(&1["name"] == "TROUPE_MCP_DOCS_TOKEN"))
    end

    test "a declared credentialRef names the variable instead of the convention",
         %{policy: policy, settings: settings} do
      server = %{
        "name" => "jira",
        "url" => "https://mcp.internal.test/jira",
        "credentialRef" => "JIRA_MCP_TOKEN",
        "secretRef" => %{"name" => "troupe-mcp-jira"}
      }

      env =
        [mcpServers: [server]]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, settings)
        |> container()
        |> Map.fetch!("env")

      assert %{
               "valueFrom" => %{
                 "secretKeyRef" => %{"name" => "troupe-mcp-jira", "key" => "token"}
               }
             } =
               Enum.find(env, &(&1["name"] == "JIRA_MCP_TOKEN"))

      refute Enum.find(env, &(&1["name"] == "TROUPE_MCP_JIRA_TOKEN"))

      assert [%{"credential_ref" => "JIRA_MCP_TOKEN"}] =
               Jason.decode!(Enum.find(env, &(&1["name"] == "TROUPE_MCP_SERVERS"))["value"])
    end

    test "a profile without MCP servers says nothing about them", %{
      policy: policy,
      settings: settings
    } do
      env =
        [mcpServers: []]
        |> profile()
        |> Profile.from_resource()
        |> Resources.for_profile(policy, settings)
        |> container()
        |> Map.fetch!("env")

      refute Enum.find(env, &String.starts_with?(&1["name"], "TROUPE_MCP_"))
    end
  end

  test "scaling the profile changes how many pods are addressed", %{
    policy: policy,
    settings: settings
  } do
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

  defp namespace_rule(namespace, port) do
    %{
      "to" => [
        %{
          "namespaceSelector" => %{"matchLabels" => %{"kubernetes.io/metadata.name" => namespace}}
        }
      ],
      "ports" => [%{"protocol" => "TCP", "port" => port}]
    }
  end
end
