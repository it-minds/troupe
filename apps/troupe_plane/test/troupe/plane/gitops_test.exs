defmodule Troupe.Plane.GitopsTest do
  @moduledoc """
  GitOps mode, made real (Decision 736): a repository holds the profiles, something else
  applies them, and the plane reads them from the cluster and never writes git.

  The cluster here is `FakeCluster`, which models server-side apply's field ownership,
  because the subject is two writers sharing one resource: `kustomize-controller`, as
  Flux applies a repository's manifest, and the plane writing the three fields no
  repository could know. What each test checks is what the plane then runs on — its rows
  — and what it leaves in the cluster.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakeCluster, Fleet, Gitops, Identity, Provision}
  alias Troupe.Plane.Admin.{API, MCP}
  alias Troupe.Plane.Gitops.Profiles
  alias Troupe.WorkerProfile

  @moduletag timeout: 60_000

  @flux "kustomize-controller"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)

    Application.put_env(
      :troupe_plane,
      :gitops_source,
      "https://git.example.com/fleet.git, profiles/"
    )

    on_exit(fn ->
      for key <- ~w(platform_admin_group provisioning_mode gitops_source policy worker_image)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    FakeCluster.start()

    %{actor: Admin.actor_for(person("root@example.test", ["platform"]))}
  end

  # A profile as a repository holds it: what `admin.profiles.export` writes, and what an
  # adopter writes by hand from the worked example.
  defp manifest(name, opts \\ []) do
    annotations =
      %{
        "troupe.dev/max-sessions" => opts[:max_sessions],
        "troupe.dev/warm-workers" => opts[:warm_workers]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(Keyword.get(opts, :annotations, %{}))

    spec =
      %{
        "image" => %{
          "repository" => "ghcr.io/troupe/worker",
          "tag" => Keyword.get(opts, :tag, "1.2.3")
        },
        "sessionsPerPod" => Keyword.get(opts, :sessions_per_pod, 4),
        "llm" => %{
          "endpoint" => "https://gateway.example.test/v1",
          "model" => Keyword.get(opts, :model, "gpt-4o")
        },
        "configBundleChannel" => "stable"
      }
      |> Map.merge(Keyword.get(opts, :spec, %{}))

    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{
        "name" => name,
        "namespace" => FakeCluster.namespace(),
        "annotations" => annotations
      },
      "spec" => spec
    }
  end

  defp flux(manifest) do
    {:ok, applied} = FakeCluster.apply_as(@flux, manifest)
    applied
  end

  defp pass do
    {:ok, outcomes} = Gitops.sync(Profiles)
    Map.new(outcomes, &{&1.name, &1})
  end

  defp owned_by(kind, name, manager) do
    kind
    |> FakeCluster.get(name)
    |> get_in(["metadata", "managedFields"])
    |> Enum.find(&(&1["manager"] == manager))
    |> case do
      nil -> %{}
      entry -> entry["fieldsV1"]
    end
  end

  defp policy(repositories) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "TroupePolicy",
      "metadata" => %{"name" => "default"},
      "spec" => %{
        "allowedImageRepositories" => repositories,
        "maxReplicas" => 4,
        "maxSessionsPerPod" => 8,
        "allowedEgress" => ["gateway.example.test"],
        "namespacePrefix" => "troupe-w-"
      }
    }
  end

  describe "the plane's rows follow the cluster" do
    test "a resource the repository adds becomes a row the plane places and scales by" do
      flux(manifest("dev", max_sessions: "8", warm_workers: "1"))

      assert %{"dev" => %{state: :created, problem: nil}} = pass()

      profile = Fleet.get_profile("dev")
      assert profile.image == "ghcr.io/troupe/worker:1.2.3"
      assert profile.size_class == "standard"
      assert profile.sessions_per_pod == 4
      assert profile.max_sessions == 8
      assert profile.warm_workers == 1
      assert profile.provisioner == "kubernetes"
      assert profile.config_bundle_channel == "stable"
      assert profile.spec["llm"]["model"] == "gpt-4o"
      assert profile.resource_generation == 1

      # Recorded the way an administrator's edit is, by the plane rather than a person:
      # the commit was somebody's, and this is the plane saying it saw it.
      assert [event] = Audit.list(actor: "system:gitops")
      assert event.action == "profile.put"
      assert event.detail["image"]["to"] == "ghcr.io/troupe/worker:1.2.3"
    end

    test "a change is read into the row, and the scaler's count is left alone" do
      flux(manifest("dev"))
      pass()
      {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 3})

      flux(manifest("dev", model: "gpt-4.1", sessions_per_pod: 2))
      assert %{"dev" => %{state: :changed}} = pass()

      profile = Fleet.get_profile("dev")
      assert profile.spec["llm"]["model"] == "gpt-4.1"
      # The class is read off the number, as for a profile from before there were classes.
      assert profile.size_class == "heavy"
      assert profile.sessions_per_pod == 2
      assert profile.replicas == 3

      assert [change, _made] = Audit.list(actor: "system:gitops")
      assert change.detail["spec.llm.model"] == %{"from" => "gpt-4o", "to" => "gpt-4.1"}
    end

    test "a pass over nothing new changes nothing and records nothing" do
      flux(manifest("dev"))
      pass()

      assert %{"dev" => %{state: :unchanged}} = pass()
      assert length(Audit.list(actor: "system:gitops")) == 1
    end

    test "a resource the repository removes takes its row with it" do
      flux(manifest("dev"))
      pass()

      FakeCluster.delete("WorkerProfile", "dev")
      assert %{"dev" => %{state: :removed}} = pass()

      assert Fleet.get_profile("dev") == nil
      assert [removed | _] = Audit.list(actor: "system:gitops")
      assert removed.action == "profile.delete"
    end

    test "a cluster that cannot be listed changes nothing, rather than reading as empty" do
      flux(manifest("dev"))
      pass()

      Application.put_env(:troupe_plane, :k8s_conn, nil)
      assert {:error, :no_cluster} = Gitops.sync(Profiles)
      assert Fleet.get_profile("dev")
    end
  end

  describe "a resource that fails the plane's checks" do
    test "is reported and not used, with every reason as a sentence", context do
      flux(
        manifest("bad",
          sessions_per_pod: 3,
          annotations: %{
            "troupe.dev/max-sessions" => "lots",
            "troupe.dev/provisioner" => "mainframe"
          }
        )
      )

      assert %{"bad" => %{state: :refused, problem: "refused", reasons: reasons}} = pass()
      assert Fleet.get_profile("bad") == nil

      assert Enum.any?(reasons, &(&1 =~ "troupe.dev/max-sessions must be a whole number above 0"))
      assert Enum.any?(reasons, &(&1 =~ "troupe.dev/provisioner must be one of"))
      assert Enum.any?(reasons, &(&1 =~ "spec.sessionsPerPod is 3"))

      assert %{problem: "refused", generation: 1} = Gitops.report("WorkerProfile", "bad")

      # And where a person or a model will look: `admin.profiles.list`, with nothing to
      # run behind it.
      assert {:ok, listed} = Admin.profiles_list(context.actor)
      bad = Enum.find(listed, &(&1.name == "bad"))
      assert bad.gitops.problem == "refused"
      assert bad.gitops.reasons == reasons
      assert bad.capacity_sessions == 0
    end

    test "a change that fails leaves the row as the last version that passed" do
      flux(manifest("dev", max_sessions: "8"))
      pass()

      flux(manifest("dev", max_sessions: "-1", model: "gpt-4.1"))
      assert %{"dev" => %{state: :refused, generation: 2}} = pass()

      profile = Fleet.get_profile("dev")
      assert profile.max_sessions == 8
      assert profile.spec["llm"]["model"] == "gpt-4o"
      assert profile.resource_generation == 1

      # Put right in the repository, and the report goes with the pass that reads it.
      flux(manifest("dev", max_sessions: "6", model: "gpt-4.1"))
      assert %{"dev" => %{state: :changed, problem: nil}} = pass()
      assert Fleet.get_profile("dev").max_sessions == 6
      assert Gitops.report("WorkerProfile", "dev") == nil
    end

    test "one that sets a field the plane writes is refused, and names who sets it" do
      flux(manifest("dev", spec: %{"replicas" => 2}))

      assert %{"dev" => %{state: :refused, reasons: [reason]}} = pass()
      assert reason =~ "spec.replicas is the plane's to write"
      assert reason =~ @flux
      assert Fleet.get_profile("dev") == nil
    end

    test "is judged by the cluster's TroupePolicy and nothing else" do
      # A policy in the plane's own configuration that would allow it, which in direct mode
      # is how a plane with no cluster is told one. In GitOps mode the repository holds the
      # policy too, and the resource is the one answer.
      Application.put_env(:troupe_plane, :policy, policy(["ghcr.io"]))
      {:ok, _} = FakeCluster.apply_as(@flux, policy(["registry.example.test/troupe"]))
      flux(manifest("dev"))

      assert %{"dev" => %{state: :refused, reasons: reasons}} = pass()
      assert Enum.any?(reasons, &(&1 =~ "cluster policy: image ghcr.io/troupe/worker:1.2.3"))
    end
  end

  describe "the plane's own three fields" do
    test "are written onto a resource the repository holds, and nothing else is", context do
      flux(manifest("dev"))
      pass()

      team_with_grant("engineering", "dev",
        name: "engineering",
        volume_storage_class: "shared-files"
      )

      assert {:ok, %{state: :projected}} = Provision.sync_teams("dev", context.actor)

      resource = FakeCluster.get("WorkerProfile", "dev")

      assert [%{"name" => "engineering", "claimName" => "troupe-team-engineering"}] =
               resource["spec"]["teams"]

      assert resource["spec"]["llm"]["model"] == "gpt-4o"

      # Owned apart: the repository's applier holds what the manifest names, the plane the
      # three it writes and nothing more.
      plane = owned_by("WorkerProfile", "dev", "troupe-plane")
      assert Map.keys(plane["f:spec"]) |> Enum.sort() == ~w(f:mcpServers f:replicas f:teams)
      refute Map.has_key?(owned_by("WorkerProfile", "dev", @flux)["f:spec"], "f:teams")
    end

    test "the scaler's count survives the repository applying its manifest again" do
      flux(manifest("dev"))
      pass()

      {:ok, profile} = Fleet.put_profile(%{name: "dev", replicas: 3})
      assert {:ok, %{state: :projected}} = Provision.apply(profile, %{subject: "system:scaler"})
      assert FakeCluster.get("WorkerProfile", "dev")["spec"]["replicas"] == 3

      # Flux's next interval, and a commit that changed something else.
      flux(manifest("dev", model: "gpt-4.1"))
      assert FakeCluster.get("WorkerProfile", "dev")["spec"]["replicas"] == 3

      assert %{"dev" => %{state: :changed}} = pass()
      assert Fleet.get_profile("dev").replicas == 3
    end

    test "are written only where they differ, not on every pass" do
      flux(manifest("dev"))
      pass()
      writes = FakeCluster.writes()

      pass()
      pass()
      assert FakeCluster.writes() == writes
    end

    test "a profile the repository has not got cannot be written, and is not made" do
      {:ok, profile} = Fleet.put_profile(%{name: "ghost", image: "ghcr.io/troupe/worker:1"})

      assert {:error, :no_resource} = Provision.apply(profile, %{subject: "system:scaler"})
      assert FakeCluster.get("WorkerProfile", "ghost") == nil
    end
  end

  describe "the record of finished drains (Decision 726)" do
    test "survives the repository's applier, which does not own it" do
      flux(manifest("dev"))
      pass()
      profile = Fleet.get_profile("dev")

      assert :ok = Provision.record_drained(profile, %{"troupe-w-dev-1" => "rev-1"})

      # Flux applies again — unchanged, and then with a change — and owns only what the
      # manifest names, which the annotation is not.
      flux(manifest("dev"))
      flux(manifest("dev", model: "gpt-4.1"))

      resource = FakeCluster.get("WorkerProfile", "dev")
      assert WorkerProfile.drained(resource) == %{"troupe-w-dev-1" => "rev-1"}
      assert {:ok, %{drained: %{"troupe-w-dev-1" => "rev-1"}}} = Provision.upgrade(profile)

      assert owned_by("WorkerProfile", "dev", "troupe-plane-upgrade")["f:metadata"][
               "f:annotations"
             ] ==
               %{"f:troupe.dev/drained" => %{}}

      # And the plane's own writes of its three fields do not take it either.
      {:ok, profile} = Fleet.put_profile(%{name: "dev", replicas: 2})
      assert {:ok, _} = Provision.apply(profile, %{subject: "system:scaler"})

      assert WorkerProfile.drained(FakeCluster.get("WorkerProfile", "dev")) == %{
               "troupe-w-dev-1" => "rev-1"
             }

      # An empty record takes it away, as it does in direct mode.
      assert :ok = Provision.record_drained(profile, %{})
      assert WorkerProfile.drained(FakeCluster.get("WorkerProfile", "dev")) == %{}
    end
  end

  describe "writes are refused" do
    setup do
      flux(manifest("dev"))
      pass()
      :ok
    end

    test "admin.profile.put, by name, and the attempt is in the trail", context do
      assert {:error, error} =
               API.call(
                 "admin.profile.put",
                 %{"name" => "dev", "image" => "ghcr.io/troupe/worker:9"},
                 context.actor
               )

      assert error.message == "managed_by_gitops"
      assert error.code == -32_015
      assert error.data.source == "https://git.example.com/fleet.git, profiles/"
      assert Fleet.get_profile("dev").image == "ghcr.io/troupe/worker:1.2.3"

      assert [event | _] = Audit.list(actor: "root@example.test")
      assert event.action == "profile.put"
      assert event.detail == %{"outcome" => "refused", "reason" => "managed_by_gitops"}
    end

    test "admin.profile.delete, for a profile the repository holds", context do
      assert {:error, %{message: "managed_by_gitops"}} =
               API.call("admin.profile.delete", %{"name" => "dev"}, context.actor)

      assert Fleet.get_profile("dev")
      assert FakeCluster.get("WorkerProfile", "dev")
    end

    test "over MCP, as a refusal the model can read", context do
      for {tool, arguments} <- [
            {"admin_profile_put", %{"name" => "dev", "image" => "ghcr.io/troupe/worker:9"}},
            {"admin_profile_delete", %{"name" => "dev", "confirm" => "dev"}}
          ] do
        request = %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"name" => tool, "arguments" => arguments}
        }

        assert {:reply, %{"result" => result}} = MCP.handle(request, context.actor)
        assert result["isError"], "#{tool} was not refused"
        assert hd(result["content"])["text"] =~ "managed_by_gitops"
      end
    end

    test "a row the cluster has no resource for may go, and only the row does", context do
      {:ok, _} = Fleet.put_profile(%{name: "leftover", image: "ghcr.io/troupe/worker:1"})
      assert %{"leftover" => %{state: :missing, problem: "missing"}} = pass()

      # Reported, not deleted: the plane had it before it read the cluster.
      assert Fleet.get_profile("leftover")

      assert {:ok, %{provisioning: %{state: :row_deleted}}} =
               Admin.profile_delete(context.actor, "leftover")

      assert Fleet.get_profile("leftover") == nil
      assert Gitops.report("WorkerProfile", "leftover") == nil
      refute Enum.any?(FakeCluster.writes(), &match?({:delete, _, _}, &1))
    end
  end

  describe "bootstrapping a repository from a running plane" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)
      :ok
    end

    test "every profile and the policy, with nothing the plane or the cluster writes", context do
      Application.put_env(:troupe_plane, :worker_image, "ghcr.io/troupe/worker:0.7.0")

      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => "release",
          "max_sessions" => 8,
          "warm_workers" => 1,
          "spec" => %{"llm" => %{"model" => "gpt-4o"}}
        })

      team_with_grant("engineering", "dev",
        name: "engineering",
        volume_storage_class: "shared-files"
      )

      {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 3})

      # The chart installs the policy with Helm's labels on it, and the cluster adds the rest.
      FakeCluster.put(
        policy(["ghcr.io/troupe"])
        |> put_in(["metadata", "labels"], %{
          "app.kubernetes.io/name" => "troupe",
          "helm.sh/chart" => "troupe-0.7.0",
          "app.kubernetes.io/managed-by" => "Helm"
        })
        |> put_in(["metadata", "annotations"], %{"helm.sh/resource-policy" => "keep"})
        |> put_in(["metadata", "resourceVersion"], "4711")
        |> Map.put("status", %{"observedGeneration" => 1})
      )

      assert {:ok, export} = API.call("admin.profiles.export", %{}, context.actor)

      assert [%{name: "dev", path: "profiles/dev.yaml", notes: [note | _], yaml: yaml}] =
               export.profiles

      assert note =~ "pinned here to ghcr.io/troupe/worker:0.7.0"

      manifest = YamlElixir.read_from_string!(yaml)

      assert manifest["spec"]["image"] == %{
               "repository" => "ghcr.io/troupe/worker",
               "tag" => "0.7.0"
             }

      assert manifest["spec"]["sessionsPerPod"] == 4
      assert manifest["spec"]["llm"] == %{"model" => "gpt-4o"}

      assert manifest["metadata"]["annotations"] == %{
               "troupe.dev/max-sessions" => "8",
               "troupe.dev/warm-workers" => "1"
             }

      for field <- ~w(replicas teams mcpServers),
          do: refute(Map.has_key?(manifest["spec"], field))

      refute Map.has_key?(manifest, "status")
      refute Map.has_key?(manifest["metadata"], "labels")

      assert export.left_out == [
               "spec.replicas",
               "spec.teams",
               "spec.mcpServers",
               "metadata.annotations[troupe.dev/drained]",
               "status"
             ]

      policy = YamlElixir.read_from_string!(export.policy.yaml)
      assert export.policy.path == "policy/default.yaml"
      assert policy["kind"] == "TroupePolicy"
      assert policy["spec"]["allowedImageRepositories"] == ["ghcr.io/troupe"]

      assert policy["metadata"] == %{
               "name" => "default",
               "labels" => %{"app.kubernetes.io/name" => "troupe"}
             }

      refute Map.has_key?(policy, "status")
    end

    test "a resource's runtime fields and the plane's record never reach a manifest" do
      stripped =
        Gitops.strip(%{
          "apiVersion" => "troupe.dev/v1alpha1",
          "kind" => "WorkerProfile",
          "metadata" => %{
            "name" => "dev",
            "namespace" => "troupe-system",
            "uid" => "abc",
            "resourceVersion" => "12",
            "generation" => 7,
            "creationTimestamp" => "2026-09-29T00:00:00Z",
            "managedFields" => [%{"manager" => @flux}],
            "labels" => %{
              "troupe.dev/managed-by" => "plane",
              "kustomize.toolkit.fluxcd.io/name" => "fleet"
            },
            "annotations" => %{
              "troupe.dev/drained" => ~s({"troupe-w-dev-1":"rev-1"}),
              "troupe.dev/max-sessions" => "8",
              "kubectl.kubernetes.io/last-applied-configuration" => "{}"
            }
          },
          "spec" => %{"image" => %{"repository" => "ghcr.io/troupe/worker"}},
          "status" => %{"podsBehind" => []}
        })

      assert stripped == %{
               "apiVersion" => "troupe.dev/v1alpha1",
               "kind" => "WorkerProfile",
               "metadata" => %{
                 "name" => "dev",
                 "namespace" => "troupe-system",
                 "annotations" => %{"troupe.dev/max-sessions" => "8"}
               },
               "spec" => %{"image" => %{"repository" => "ghcr.io/troupe/worker"}}
             }
    end

    test "an exported manifest is read back as the profile it came from", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => "ghcr.io/troupe/worker:1.2.3",
          "size_class" => "heavy",
          "max_sessions" => 4,
          "spec" => %{
            "llm" => %{"model" => "gpt-4o"},
            "egress" => %{"fqdns" => ["gateway.example.test"]}
          }
        })

      before = Fleet.get_profile("dev")
      {:ok, export} = Admin.profiles_export(context.actor)

      # Committed, applied by Flux, and the plane switched.
      for %{yaml: yaml} <- export.profiles, do: flux(YamlElixir.read_from_string!(yaml))
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)

      assert %{"dev" => %{state: :unchanged, problem: nil}} = pass()

      after_ = Fleet.get_profile("dev")

      for field <-
            ~w(image size_class sessions_per_pod max_sessions warm_workers provisioner config_bundle_channel)a do
        assert Map.fetch!(after_, field) == Map.fetch!(before, field), "#{field} moved"
      end

      assert after_.spec["llm"] == before.spec["llm"]
      assert after_.spec["egress"] == before.spec["egress"]
      assert Audit.list(actor: "system:gitops") == []
    end
  end

  describe "switching modes on a running plane" do
    test "direct to gitops: resources are adopted as they are, and rows without one are kept",
         context do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      {:ok, %{provisioning: %{state: :applied}}} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => "ghcr.io/troupe/worker:1.2.3"
        })

      {:ok, _} = Fleet.put_profile(%{name: "drafted", image: "ghcr.io/troupe/worker:1.2.3"})
      FakeCluster.delete("WorkerProfile", "drafted")

      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      outcomes = pass()

      # Only the plane has ever written `dev`, so nothing applies it from a repository
      # yet: used as it is, reported, and not written to — a write of three fields would
      # give up the image, and the API server would refuse what was left.
      assert %{state: :unchanged, problem: "plane_only"} = outcomes["dev"]
      assert Fleet.get_profile("dev").resource_generation == 1
      writes = FakeCluster.writes()

      assert {:error, :not_held_by_repository} =
               Provision.apply(Fleet.get_profile("dev"), context.actor)

      assert FakeCluster.writes() == writes

      assert %{state: :missing, problem: "missing"} = outcomes["drafted"]
      assert Fleet.get_profile("drafted")

      # The repository takes it over, from the export, and the plane gives up everything
      # of it but its three fields at its next write.
      {:ok, export} = Admin.profiles_export(context.actor)

      for %{name: "dev", yaml: yaml} <- export.profiles,
          do: flux(YamlElixir.read_from_string!(yaml))

      assert %{"dev" => %{problem: nil}} = pass()
      {:ok, profile} = Fleet.put_profile(%{name: "dev", replicas: 2})
      assert {:ok, %{state: :projected}} = Provision.apply(profile, context.actor)

      resource = FakeCluster.get("WorkerProfile", "dev")
      assert resource["spec"]["image"]["repository"] == "ghcr.io/troupe/worker"

      assert Map.keys(owned_by("WorkerProfile", "dev", "troupe-plane")["f:spec"]) |> Enum.sort() ==
               ~w(f:mcpServers f:replicas f:teams)

      # And a field direct mode wrote and the repository stops naming now leaves the
      # cluster: the plane gave it up, so nobody holds it. With the plane still its
      # co-owner, a repository could never take anything away.
      assert FakeCluster.get("WorkerProfile", "dev")["spec"]["resources"]
      flux(manifest("dev"))
      refute Map.has_key?(FakeCluster.get("WorkerProfile", "dev")["spec"], "resources")
    end

    test "gitops to direct: the plane writes the whole resource again, from what it read",
         context do
      flux(manifest("dev"))
      pass()

      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      assert {:ok, %{provisioning: %{state: :applied}}} =
               Admin.profile_put(context.actor, %{
                 "name" => "dev",
                 "image" => "ghcr.io/troupe/worker:2.0.0"
               })

      resource = FakeCluster.get("WorkerProfile", "dev")
      assert resource["spec"]["image"]["tag"] == "2.0.0"

      assert get_in(owned_by("WorkerProfile", "dev", "troupe-plane"), [
               "f:spec",
               "f:image",
               "f:tag"
             ]) == %{}
    end

    test "the mode is the deployment's, and the console cannot switch it", context do
      assert {:error, error} = Admin.setting_put(context.actor, "provisioning_mode", "direct")
      assert error.message == "invalid_params"
      assert error.data.reason =~ "belongs to the deployment"
      assert Provision.mode() == :gitops

      # Nor does a value stored while it could: the deployment's is the only one read.
      Repo.insert!(%Troupe.Plane.Settings.Stored{
        key: "provisioning_mode",
        value: "direct",
        updated_by: "root"
      })

      Troupe.Plane.Settings.invalidate()
      assert Provision.mode() == :gitops
    end
  end
end
