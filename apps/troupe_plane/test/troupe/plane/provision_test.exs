defmodule Troupe.Plane.ProvisionTest do
  @moduledoc """
  Turning a profile into a custom resource.

  Direct mode applies the whole manifest from the row. GitOps mode never writes git: a
  repository holds the manifest, which is direct mode's without the three fields the plane
  writes (`Troupe.Plane.GitopsTest` has the rest of that mode, against a cluster).
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
      # Both teams have a volume: `teams` is the projection of the volumes that grants
      # carry, and a team given no storage class was never given a volume to project.
      engineering =
        team_with_grant("engineering", "dev",
          name: "engineering",
          volume_mode: "rw",
          volume_storage_class: "shared-files"
        )

      _design =
        team_with_grant("design", "dev", name: "design", volume_storage_class: "shared-files")

      manifest = Provision.manifest(context.profile)
      teams = manifest["spec"]["teams"]

      assert Enum.map(teams, & &1["name"]) == ["design", "engineering"]
      assert Enum.find(teams, &(&1["name"] == "engineering"))["mode"] == "rw"
      # `claimName`, which is what the CRD declares and what the operator's parser reads.
      # This asserted `volume` for a long time â€” pinning the plane's output to a key nothing
      # on the other side could see, which is how the mismatch survived having a test.
      assert Enum.find(teams, &(&1["name"] == "engineering"))["claimName"] ==
               "troupe-team-engineering"

      # A revoked grant leaves the projection, because the projection is the grants.
      :ok = Identity.revoke(engineering, "dev")
      assert Provision.manifest(context.profile)["spec"]["teams"] |> Enum.map(& &1["name"]) == ["design"]
    end
  end

  describe "policy, checked for feedback" do
    test "a profile outside policy is refused before anything is written", context do
      Application.put_env(:troupe_plane, :policy, policy())

      assert {:error, error} =
               Admin.profile_put(context.actor, %{
                 name: "bad",
                 image: "docker.io/someone/whatever:1"
               })

      assert error.message == "invalid_params"
      assert error.data.policy_violations != []
      assert Fleet.get_profile("bad") == nil
    end

    test "every violation is reported, not the first", context do
      Application.put_env(:troupe_plane, :policy, policy(max_sessions_per_pod: 1))

      assert {:error, error} =
               Admin.profile_put(context.actor, %{
                 name: "bad",
                 image: "docker.io/someone/whatever:1",
                 size_class: "heavy"
               })

      # A form that fixed one problem at a time would take four round trips to get right.
      assert length(error.data.policy_violations) >= 2
    end

    test "a violation is a sentence, and survives being sent", context do
      Application.put_env(:troupe_plane, :policy, policy(max_sessions_per_pod: 1))

      assert {:error, error} =
               Admin.profile_put(context.actor, %{
                 name: "bad",
                 image: "ghcr.io/objective-mj/troupe-worker:dev",
                 size_class: "heavy"
               })

      # A violation is a tuple, and `Jason` refuses tuples: putting them in an error's
      # data turned a legitimate refusal into a 500 with an HTML body, so a caller who
      # asked for one thing too many was told nothing whatever about which.
      assert Enum.all?(error.data.policy_violations, &is_binary/1), inspect(error.data)
      assert Enum.any?(error.data.policy_violations, &(&1 =~ "sessionsPerPod 2"))
      assert {:ok, _json} = Jason.encode(error.data)
    end

    test "a profile inside policy is saved", context do
      Application.put_env(:troupe_plane, :policy, policy())

      assert {:ok, result} =
               Admin.profile_put(context.actor, %{
                 name: "good",
                 image: "ghcr.io/troupe/worker:2",
                 size_class: "heavy"
               })

      assert result.profile.name == "good"
      assert Fleet.get_profile("good")
    end

    test "the panel's check is the check admission makes", context do
      Application.put_env(:troupe_plane, :policy, policy())

      # Same document, same parser, same function. An approximation that disagreed would
      # be worse than no check, because a person would trust it.
      assert {:ok, preview} =
               Admin.preview(context.actor, %{name: "dev", image: "docker.io/someone/whatever:1"})

      refute preview.policy.allowed?

      verdict = Provision.verdict(%{name: "dev", image: "docker.io/someone/whatever:1"})
      assert verdict.violations == preview.policy.violations
    end

    test "with no policy configured, nothing is refused", context do
      # A plane that has not been told the cluster policy must not invent one: admission
      # is authoritative and would refuse what this cannot see.
      assert {:ok, _} = Admin.profile_put(context.actor, %{name: "anything", image: "docker.io/x:1"})
    end
  end

  describe "GitOps mode (Decision 736)" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      :ok
    end

    test "a repository's manifest is direct mode's without what the plane writes" do
      {:ok, profile} =
        Fleet.put_profile(%{name: "dev", replicas: 3, max_sessions: 8, warm_workers: 1})

      Application.put_env(:troupe_plane, :provisioning_mode, :direct)
      direct = Provision.manifest(profile)
      repository = Provision.repository_manifest(profile)

      assert Map.drop(repository["spec"], ["configBundleChannel"]) ==
               Map.drop(direct["spec"], ~w(replicas teams mcpServers))

      # The plane's own answers, which the resource has no field for, and nothing of the
      # plane's own bookkeeping: no label saying the plane wrote it, because it will not.
      assert repository["metadata"]["annotations"] == %{
               "troupe.dev/max-sessions" => "8",
               "troupe.dev/warm-workers" => "1"
             }

      refute Map.has_key?(repository["metadata"], "labels")
    end

    test "the plane never removes a profile a repository holds", context do
      assert {:error, :managed_by_gitops} = Provision.remove(context.profile, context.actor)
    end

    test "with no cluster, nothing is written and it says so", context do
      # No commit, no file, no git: the only place a GitOps plane writes is the resource.
      assert {:error, :no_cluster} = Provision.apply(context.profile, context.actor)
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

  # `max_sessions_per_pod` is an option because a size class is now what decides that
  # number, and the interesting case is a cluster admin whose policy is tighter than the
  # class — which is the whole of "a TroupePolicy maximum still refuses a size class that
  # exceeds it".
  defp policy(opts \\ []) do
    %{
      "spec" => %{
        # A prefix, not a glob: the checker matches the repository itself or anything
        # under it, which is what the chart's default values also express.
        "allowedImageRepositories" => ["ghcr.io/troupe"],
        "maxReplicas" => 4,
        "maxSessionsPerPod" => Keyword.get(opts, :max_sessions_per_pod, 8),
        "namespacePrefix" => "troupe-w-"
      }
    }
  end
end
