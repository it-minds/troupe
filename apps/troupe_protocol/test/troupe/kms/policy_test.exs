defmodule Troupe.KMS.PolicyTest do
  @moduledoc """
  What the plane's OpenBao role must be granted, written down once (#765).

  The plane checks `Policy.plane_grants/1` against its own token and prints the lines for
  a grant it lacks; `docs/admin/openbao.md` is written from the same list. These prove
  the page is current, that every rule can be asked about at a concrete path, and that the
  policy texts the tests elsewhere install against a real OpenBao did not change when they
  came to be rendered from rules.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Troupe.Openbao.Policy, as: Task
  alias Troupe.KMS.Policy

  @root Path.expand("../../../../..", __DIR__)

  test "docs/admin/openbao.md is what mix troupe.openbao.policy writes" do
    assert File.read!(Path.join(@root, Task.output())) == Task.render(),
           "docs/admin/openbao.md is stale: run `mix troupe.openbao.policy` and commit it"
  end

  test "every grant the plane checks is on the page, with its policy and every path" do
    page = Task.render()

    for grant <- Policy.plane_grants() do
      assert page =~ "`#{grant.policy}`"

      for {path, _capabilities} <- grant.rules do
        assert page =~ ~s(path "#{path}"), "#{grant.id}: #{path} is not on the page"
      end
    end
  end

  test "each grant's policy is the one the code renders for that use" do
    by_id = Map.new(Policy.plane_grants(), &{&1.id, Policy.grant_policy(&1)})

    assert by_id["session-tokens"] == Policy.signing()
    assert by_id["plane-signing"] == Policy.plane_signing()
    assert by_id["erasure"] == Policy.plane()
    assert by_id["github-app"] == Policy.github_app()
  end

  test "a rule's pattern becomes a path OpenBao can be asked about" do
    assert Policy.probe_path("secret/metadata/troupe/teams/+/sessions/*") ==
             "secret/metadata/troupe/teams/troupe-check/sessions/troupe-check"

    assert Policy.probe_path("transit/sign/troupe-plane-signing") ==
             "transit/sign/troupe-plane-signing"

    assert Policy.probe_path("transit/sign/troupe-w-dev.*") ==
             "transit/sign/troupe-w-dev.troupe-check"
  end

  test "the deployment's names reach every rule" do
    grants =
      Policy.plane_grants(
        kv_mount: "kv",
        transit_mount: "keys",
        session_key: "tokens",
        signing_key: "word",
        github_key: "app",
        github_webhook_key: "hook"
      )

    paths = for grant <- grants, {path, _} <- grant.rules, do: path
    assert Enum.all?(paths, &(String.starts_with?(&1, "kv/") or String.starts_with?(&1, "keys/")))
    assert "keys/sign/tokens" in paths
    assert "keys/sign/word" in paths
    assert "keys/sign/app" in paths
    assert "keys/hmac/hook/sha2-256" in paths
  end

  describe "the lines that grant one" do
    setup do
      %{grant: Enum.find(Policy.plane_grants(), &(&1.id == "plane-signing"))}
    end

    test "write the policy and add it to the role, keeping what the token carries", %{
      grant: grant
    } do
      lines =
        Policy.grant_lines(grant, role: "troupe-plane", policies: ["default", "troupe-plane"])

      assert lines =~ "bao policy write troupe-plane-signing - <<'POLICY'\n"
      assert lines =~ ~s(path "transit/keys/troupe-plane-signing/rotate")
      assert lines =~ "\nPOLICY\n"

      assert lines =~
               "bao write auth/kubernetes/role/troupe-plane token_policies=troupe-plane,troupe-plane-signing\n"
    end

    test "name a new static token where the plane has one", %{grant: grant} do
      lines = Policy.grant_lines(grant, role: nil, policies: ["default", "troupe-plane"])
      assert lines =~ "bao token create -policy=troupe-plane -policy=troupe-plane-signing"
    end
  end

  test "the plane's role line carries every required grant's policy and no other" do
    line = Policy.plane_role_line(namespace: "troupe", auth_path: "k8s")

    assert line =~ "bao write auth/k8s/role/troupe-plane "
    assert line =~ "bound_service_account_namespaces=troupe "
    assert line =~ "audience=troupe-kms "
    assert line =~ "token_policies=troupe-plane-session-tokens,troupe-plane-signing,troupe-plane "
    refute line =~ "troupe-plane-github"
  end

  # The texts other suites install into a real OpenBao, as they were written by hand
  # before they were rendered from rules: a byte changed would be a policy changed.
  test "the plane's erasure policy is the text it always was" do
    assert Policy.plane("secret") == """
           path "secret/metadata/troupe/teams/+/sessions/*" {
             capabilities = ["delete", "list", "read"]
           }

           path "secret/metadata/troupe/people/+/sessions/*" {
             capabilities = ["delete", "list", "read"]
           }

           path "secret/metadata/troupe/people/+/mcp/*" {
             capabilities = ["list", "read"]
           }
           """

    assert Policy.signing() == """
           path "transit/sign/troupe-session-tokens" {
             capabilities = ["create", "update"]
           }

           path "transit/keys/troupe-session-tokens" {
             capabilities = ["read"]
           }
           """
  end
end
