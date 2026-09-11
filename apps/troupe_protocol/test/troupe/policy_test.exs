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
  end

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
