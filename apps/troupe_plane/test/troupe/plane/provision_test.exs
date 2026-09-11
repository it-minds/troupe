defmodule Troupe.Plane.ProvisionTest do
  @moduledoc """
  Turning a profile into a custom resource, both ways.

  The two modes have to produce the same manifest — a profile that meant something
  different depending on how it reached the cluster would be a trap — so the tests check
  that first and the differences second. What differs is where it goes and when it counts
  as applied: direct mode applies, and GitOps mode commits and stays `Pending` until the
  operator's `observedGeneration` catches up, because a commit is not a deployment.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Fleet, Identity, Provision}

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :provisioning_mode)
      Application.delete_env(:troupe_plane, :gitops)
      Application.delete_env(:troupe_plane, :policy)
    end)

    {:ok, profile} =
      Fleet.put_profile(%{
        name: "dev",
        replicas: 2,
        sessions_per_pod: 4,
        image: "ghcr.io/troupe/worker:1.2.3",
        spec: %{"workersDomain" => "workers.example.test"}
      })

    %{actor: Admin.actor_for(root), profile: profile}
  end

  describe "the manifest" do
    test "is a WorkerProfile the operator would recognise", context do
      manifest = Provision.manifest(context.profile)

      assert manifest["apiVersion"] == "troupe.dev/v1alpha1"
      assert manifest["kind"] == "WorkerProfile"
      assert manifest["metadata"]["name"] == "dev"
      # Split the way the custom resource wants it, because that is what a policy matches
      # against — and the plane records the string a person typed.
      assert manifest["spec"]["image"] == %{"repository" => "ghcr.io/troupe/worker", "tag" => "1.2.3"}
      assert manifest["spec"]["replicas"] == 2
      assert manifest["spec"]["sessionsPerPod"] == 4
      assert manifest["spec"]["workersDomain"] == "workers.example.test"
    end

    test "an image is split into a repository and a tag or digest", context do
      for {given, expected} <- [
            {"ghcr.io/troupe/worker:1.2.3", %{"repository" => "ghcr.io/troupe/worker", "tag" => "1.2.3"}},
            {"ghcr.io/troupe/worker", %{"repository" => "ghcr.io/troupe/worker"}},
            {"ghcr.io/troupe/worker@sha256:abc", %{"repository" => "ghcr.io/troupe/worker", "digest" => "sha256:abc"}},
            # A registry with a port is not a repository with a very odd tag.
            {"registry:5000/troupe/worker:2", %{"repository" => "registry:5000/troupe/worker", "tag" => "2"}}
          ] do
        {:ok, profile} = Fleet.put_profile(%{name: "dev", image: given})
        assert Provision.manifest(profile)["spec"]["image"] == expected
      end

      _ = context
    end

    test "says the plane wrote it", context do
      manifest = Provision.manifest(context.profile)

      # So a reader can tell a profile the plane wrote from one somebody applied by hand,
      # which is the difference between a bug and a deliberate override.
      assert manifest["metadata"]["labels"]["troupe.dev/managed-by"] == "plane"
    end

    test "projects the plane's grants into `teams`", context do
      engineering = team_with_grant("engineering", "dev", name: "engineering", volume_mode: "rw")
      _design = team_with_grant("design", "dev", name: "design")

      manifest = Provision.manifest(context.profile)
      teams = manifest["spec"]["teams"]

      assert Enum.map(teams, & &1["name"]) == ["design", "engineering"]
      assert Enum.find(teams, &(&1["name"] == "engineering"))["mode"] == "rw"
      assert Enum.find(teams, &(&1["name"] == "engineering"))["volume"] == "troupe-team-engineering"

      # A revoked grant leaves the projection, because the projection is the grants.
      :ok = Identity.revoke(engineering, "dev")
      assert Provision.manifest(context.profile)["spec"]["teams"] |> Enum.map(& &1["name"]) == ["design"]
    end
  end

  describe "policy, checked for feedback" do
    test "a profile outside policy is refused before anything is written", context do
      Application.put_env(:troupe_plane, :policy, policy())

      assert {:error, error} =
               Admin.profile_put(context.actor, %{name: "bad", image: "docker.io/someone/whatever:1", replicas: 1})

      assert error.message == "invalid_params"
      assert error.data.policy_violations != []
      assert Fleet.get_profile("bad") == nil
    end

    test "every violation is reported, not the first", context do
      Application.put_env(:troupe_plane, :policy, policy())

      assert {:error, error} =
               Admin.profile_put(context.actor, %{
                 name: "bad",
                 image: "docker.io/someone/whatever:1",
                 replicas: 99
               })

      # A form that fixed one problem at a time would take four round trips to get right.
      assert length(error.data.policy_violations) >= 2
    end

    test "a profile inside policy is saved", context do
      Application.put_env(:troupe_plane, :policy, policy())

      assert {:ok, result} =
               Admin.profile_put(context.actor, %{
                 name: "good",
                 image: "ghcr.io/troupe/worker:2",
                 replicas: 2,
                 sessions_per_pod: 2
               })

      assert result.profile.name == "good"
      assert Fleet.get_profile("good")
    end

    test "the panel's check is the check admission makes", context do
      Application.put_env(:troupe_plane, :policy, policy())

      # Same document, same parser, same function. An approximation that disagreed would
      # be worse than no check, because a person would trust it.
      assert {:ok, preview} =
               Admin.preview(context.actor, %{name: "dev", image: "docker.io/someone/whatever:1", replicas: 1})

      refute preview.policy.allowed?

      verdict = Provision.verdict(%{name: "dev", image: "docker.io/someone/whatever:1", replicas: 1})
      assert verdict.violations == preview.policy.violations
    end

    test "with no policy configured, nothing is refused", context do
      # A plane that has not been told the cluster policy must not invent one: admission
      # is authoritative and would refuse what this cannot see.
      assert {:ok, _} = Admin.profile_put(context.actor, %{name: "anything", image: "docker.io/x:1"})
    end
  end

  describe "GitOps mode" do
    setup context do
      repo = Path.join(System.tmp_dir!(), "troupe-gitops-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      {_output, 0} = System.cmd("git", ["-C", repo, "init", "--quiet", "--initial-branch=main"])
      on_exit(fn -> File.rm_rf!(repo) end)

      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      Application.put_env(:troupe_plane, :gitops, path: repo)

      Map.put(context, :repo, repo)
    end

    test "a profile becomes a commit in the repository", context do
      assert {:ok, result} =
               Admin.profile_put(context.actor, %{name: "dev", image: "ghcr.io/troupe/worker:2", replicas: 3})

      assert result.provisioning.mode == :gitops
      assert result.provisioning.state == :pending
      assert result.provisioning.path == "profiles/dev.yaml"

      written = Path.join([context.repo, "profiles", "dev.yaml"]) |> File.read!()
      assert written =~ "kind: WorkerProfile"
      assert written =~ "repository: ghcr.io/troupe/worker"
      assert written =~ "replicas: 3"

      {log, 0} = System.cmd("git", ["-C", context.repo, "log", "--oneline"])
      assert log =~ "dev updated by root@example.test"

      {sha, 0} = System.cmd("git", ["-C", context.repo, "rev-parse", "HEAD"])
      assert String.trim(sha) == result.provisioning.commit
    end

    test "deleting a profile removes the file and commits that too", context do
      {:ok, _} = Admin.profile_put(context.actor, %{name: "dev", image: "ghcr.io/troupe/worker:2"})
      assert File.exists?(Path.join([context.repo, "profiles", "dev.yaml"]))

      assert {:ok, _} = Admin.profile_delete(context.actor, "dev")

      refute File.exists?(Path.join([context.repo, "profiles", "dev.yaml"]))
      {log, 0} = System.cmd("git", ["-C", context.repo, "log", "--oneline"])
      assert log =~ "dev removed by root@example.test"
    end

    test "the manifest committed is the manifest direct mode would apply", context do
      {:ok, _} = Admin.profile_put(context.actor, %{name: "dev", image: "ghcr.io/troupe/worker:2", replicas: 3})

      committed = Path.join([context.repo, "profiles", "dev.yaml"]) |> File.read!()
      direct = Provision.manifest(Fleet.get_profile("dev"))

      # Parsed back rather than compared as text: what matters is that the document is the
      # same, not that two serialisers agree about whitespace.
      assert YamlElixir.read_from_string!(committed) == direct
    end

    test "pending until the operator has seen it", context do
      {:ok, _} = Admin.profile_put(context.actor, %{name: "dev", image: "ghcr.io/troupe/worker:2"})

      # With no cluster to ask, a GitOps profile is pending: a commit is not a
      # deployment, and saying it was would make a failed apply invisible.
      assert Provision.pending?(Fleet.get_profile("dev"))
    end
  end

  describe "direct mode" do
    test "reports what it could not do rather than claiming success", context do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      # No cluster configured, which is what a plane under test has.
      assert {:ok, result} = Admin.profile_put(context.actor, %{name: "dev", image: "ghcr.io/troupe/worker:2"})

      assert result.provisioning.state == :not_applied
      assert result.provisioning.reason =~ "no_cluster"

      # The profile is still saved: the plane's record is the plane's, and a cluster it
      # cannot reach does not make the record wrong.
      assert Fleet.get_profile("dev").image == "ghcr.io/troupe/worker:2"
    end
  end

  defp policy do
    %{
      "spec" => %{
        # A prefix, not a glob: the checker matches the repository itself or anything
        # under it, which is what the chart's default values also express.
        "allowedImageRepositories" => ["ghcr.io/troupe"],
        "maxReplicas" => 4,
        "maxSessionsPerPod" => 8,
        "namespacePrefix" => "troupe-w-"
      }
    }
  end
end
