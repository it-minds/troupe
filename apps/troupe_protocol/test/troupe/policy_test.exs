defmodule Troupe.PolicyTest do
  @moduledoc """
  What a profile may ask for.

  `TroupePolicy` is the boundary between the plane — which is internet-facing and may
  write profiles — and the cluster. Every case here is something a compromised or
  careless plane could otherwise do.
  """

  use ExUnit.Case, async: true

  import Troupe.Operator.Fixtures

  alias Troupe.Policy
  alias Troupe.WorkerProfile, as: Profile

  defp check(profile_overrides \\ [], policy_overrides \\ []) do
    Policy.violations(
      Profile.from_resource(profile(profile_overrides)),
      Policy.from_resource(policy(policy_overrides))
    )
  end

  test "a profile inside the policy has nothing to say" do
    assert check() == []
  end

  describe "images" do
    test "an image from an allowed repository passes, tag or digest" do
      assert check(image: %{"repository" => "ghcr.io/objective-mj/troupe-worker", "tag" => "1.2.3"}) == []

      assert check(
               image: %{
                 "repository" => "ghcr.io/objective-mj/troupe-worker",
                 "digest" => "sha256:" <> String.duplicate("a", 64)
               }
             ) == []
    end

    test "an image from anywhere else is refused" do
      assert [{:image_not_allowed, "docker.io/someone/whatever:latest"}] =
               check(image: %{"repository" => "docker.io/someone/whatever", "tag" => "latest"})
    end

    test "a repository that merely starts with an allowed one is refused" do
      # `ghcr.io/objective-mj/troupe-worker-evil` is a different repository, and
      # prefix matching without the separator would have allowed it.
      assert [{:image_not_allowed, _}] =
               check(image: %{"repository" => "ghcr.io/objective-mj/troupe-worker-evil", "tag" => "1"})
    end

    test "a digest pins the image even when a tag is also given" do
      digest = "sha256:" <> String.duplicate("b", 64)

      parsed =
        Profile.from_resource(
          profile(image: %{"repository" => "ghcr.io/objective-mj/troupe-worker", "tag" => "1", "digest" => digest})
        )

      assert parsed.image == "ghcr.io/objective-mj/troupe-worker@#{digest}"
    end
  end

  describe "size" do
    test "more replicas than the policy allows" do
      assert [{:replicas_above_maximum, 9, 4}] = check(replicas: 9)
    end

    test "more sessions per pod than the policy allows" do
      assert [{:sessions_per_pod_above_maximum, 32, 8}] = check(sessionsPerPod: 32)
    end

    test "a bigger CPU or memory limit than the policy allows" do
      violations =
        check(
          resources: %{"limits" => %{"cpu" => "8", "memory" => "32Gi"}}
        )

      assert {:cpu_above_maximum, 8000, 2000} in violations
      assert {:memory_above_maximum, 34_359_738_368, 4_294_967_296} in violations
    end

    test "quantities are read the way Kubernetes writes them" do
      assert Policy.cpu_millis("500m") == 500
      assert Policy.cpu_millis("2") == 2000
      assert Policy.cpu_millis("1.5") == 1500
      assert Policy.memory_bytes("512Mi") == 536_870_912
      assert Policy.memory_bytes("2Gi") == 2_147_483_648
      assert Policy.memory_bytes("1000000") == 1_000_000
    end
  end

  describe "egress" do
    test "a declared FQDN outside the policy is refused" do
      assert [{:egress_not_allowed, "exfiltrate.example.com"}] =
               check(egress: %{"fqdns" => ["exfiltrate.example.com"], "gitHosts" => []})
    end

    test "the LLM endpoint counts as egress" do
      assert [{:egress_not_allowed, "llm.somewhere-else.test"}] =
               check(llm: %{"endpoint" => "https://llm.somewhere-else.test/v1"})
    end

    test "an MCP server counts as egress" do
      assert [{:egress_not_allowed, "mcp.somewhere-else.test"}] =
               check(mcpServers: [%{"name" => "x", "url" => "https://mcp.somewhere-else.test/x"}])
    end

    test "a wildcard matches one label, not a subdomain and not the bare domain" do
      assert Policy.matches?("api.anthropic.com", "*.anthropic.com")
      refute Policy.matches?("a.b.anthropic.com", "*.anthropic.com")
      refute Policy.matches?("anthropic.com", "*.anthropic.com")
      refute Policy.matches?("evil-anthropic.com", "*.anthropic.com")
    end

    test "a pattern is an exact name or a wildcard of one leading label, and nothing else" do
      for entry <- accepted_patterns(), do: assert(Policy.pattern?(entry), entry)
      for entry <- refused_patterns(), do: refute(Policy.pattern?(entry), entry)
    end

    # A bare `*` in both used to pass, compared as the string it is, and the operator then
    # wrote it as a Cilium `matchPattern`, which is every name there is. And
    # `**.anthropic.com` passed `*.anthropic.com`, its first label being one label, while
    # Cilium reads `**.` as any number of them.
    test "a profile entry that is not a pattern is refused, naming it, whatever the policy holds" do
      for entry <- refused_patterns() do
        egress = [egress: %{"fqdns" => [entry], "gitHosts" => []}]

        assert check(egress) == [{:egress_not_a_pattern, entry}], entry
        assert Policy.describe({:egress_not_a_pattern, entry}) =~ entry

        allowing_it = allowed_egress([entry])
        assert {:egress_not_a_pattern, entry} in check(egress, allowedEgress: allowing_it), entry
      end

      assert [{:egress_not_a_pattern, "**.anthropic.com"}] =
               check(egress: %{"fqdns" => ["**.anthropic.com"], "gitHosts" => []})
    end

    test "a policy entry that is not a pattern admits nothing, and refuses every profile" do
      for entry <- refused_patterns() do
        violations = check([], allowedEgress: allowed_egress([entry]))

        assert violations == [{:allowed_egress_not_a_pattern, entry}], entry
        assert Policy.describe(hd(violations)) =~ entry
        refute Policy.matches?("api.example.com", entry), entry
      end
    end

    # Compared as the whole string, `api.example.com:8443` passed no policy that named the
    # host, and with Cilium it became a name that carried the port and admitted nothing.
    test "an entry's host and port are compared apart, and a pattern with no port takes any" do
      assert Policy.matches?("api.example.com:8443", "api.example.com")
      assert Policy.matches?("api.example.com:8443", "*.example.com")
      assert Policy.matches?("api.example.com:8443", "api.example.com:8443")
      refute Policy.matches?("api.example.com:8443", "api.example.com:9443")
      refute Policy.matches?("api.example.com", "api.example.com:8443")
      refute Policy.matches?("a.b.example.com:8443", "*.example.com")
      assert Policy.matches?("[2001:db8::1]:8443", "2001:db8::1")
      assert Policy.matches?("10.20.0.5:8443", "10.20.0.5")

      ported = [egress: %{"fqdns" => ["api.example.com:8443"], "gitHosts" => []}]
      assert check(ported, allowedEgress: allowed_egress(["api.example.com"])) == []

      assert [{:egress_not_allowed, "api.example.com:8443"}] =
               check(ported, allowedEgress: allowed_egress(["api.example.com:9443"]))
    end

    test "an entry's host and port, as the operator and the admission rule read them" do
      assert Policy.host_and_port("api.example.com:8443") == {"api.example.com", 8443}
      assert Policy.host_and_port("[2001:db8::1]:8443") == {"2001:db8::1", 8443}
      assert Policy.host_and_port("api.example.com") == {"api.example.com", nil}
      assert Policy.host_and_port("2001:db8::1") == {"2001:db8::1", nil}
      assert Policy.host_and_port("*.example.com:443") == {"*.example.com", 443}
    end

    test "a profile's wildcard passes only a policy that holds the same wildcard" do
      wildcard = [egress: %{"fqdns" => ["*.example.com"], "gitHosts" => []}]

      assert check(wildcard, allowedEgress: allowed_egress(["*.example.com"])) == []

      assert [{:egress_not_allowed, "*.example.com"}] =
               check(wildcard, allowedEgress: allowed_egress(["*.com"]))
    end
  end

  # The fixture policy's own entries, which the fixture profile needs, and `more`.
  defp allowed_egress(more), do: policy()["spec"]["allowedEgress"] ++ more

  describe "storage" do
    test "a storage class outside the policy is refused" do
      assert [{:storage_class_not_allowed, "expensive-ssd"}] =
               check(teams: [%{"name" => "dev", "mode" => "rw", "storageClassName" => "expensive-ssd"}])
    end

    test "orgMount without an org volume in the policy is refused" do
      assert [{:org_volume_not_offered, nil}] = check([orgMount: true], orgVolume: nil)
    end
  end

  test "every violation is reported, not just the first" do
    violations =
      check(
        image: %{"repository" => "docker.io/someone/whatever", "tag" => "latest"},
        replicas: 99,
        egress: %{"fqdns" => ["exfiltrate.example.com"], "gitHosts" => []}
      )

    assert length(violations) == 3
  end

  test "every violation reads as a sentence naming what is wrong" do
    for violation <- check(image: %{"repository" => "docker.io/x", "tag" => "1"}, replicas: 99) do
      message = Policy.describe(violation)
      assert is_binary(message)
      assert String.length(message) > 10
    end
  end
end
