defmodule Troupe.Plane.GitopsTriggersTest do
  @moduledoc """
  Triggers in GitOps mode (Decision 737): a repository holds them as `Trigger` resources,
  something else applies them, and the plane's trigger rows follow the cluster the way its
  profiles do (736).

  What each test checks is what the plane then fires — its rows, their revisions and the
  audit trail — and that what stays the plane's (the key, the runs, running one by hand)
  works as it did.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakeCluster, FakePod, Gitops, Identity, Triggers}
  alias Troupe.Plane.Admin.{API, MCP}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Gitops.Profiles
  alias Troupe.Plane.Gitops.Triggers, as: GitopsTriggers

  @moduletag timeout: 60_000

  @flux "kustomize-controller"
  @source "https://git.example.com/fleet.git, triggers/"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
    Application.put_env(:troupe_plane, :gitops_source, @source)

    on_exit(fn ->
      for key <- ~w(platform_admin_group provisioning_mode gitops_source)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    FakeCluster.start()

    # The profile the triggers start on, from the repository as well.
    flux(profile("dev"))
    {:ok, _} = Gitops.sync(Profiles)

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    {:ok, principal, _secret} = principal!(team, %{name: "nightly", profiles: ["dev"]})

    %{
      root: Admin.actor_for(person("root@example.test", ["platform"])),
      team: team,
      principal: principal
    }
  end

  defp profile(name) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" => %{
        "image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1.2.3"},
        "sessionsPerPod" => 4,
        "llm" => %{"model" => "gpt-4o"}
      }
    }
  end

  # A trigger as a repository holds it: what `admin.profiles.export` writes, and what the
  # worked example in the docs is.
  defp manifest(name, spec \\ %{}) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "Trigger",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" =>
        Map.merge(
          %{
            "principal" => "svc:engineering/nightly",
            "profile" => "dev",
            "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5"},
            "promptTemplate" => "Summarise what changed yesterday."
          },
          spec
        )
    }
  end

  defp flux(manifest) do
    {:ok, applied} = FakeCluster.apply_as(@flux, manifest)
    applied
  end

  defp pass do
    {:ok, outcomes} = Gitops.sync(GitopsTriggers)
    Map.new(outcomes, &{&1.name, &1})
  end

  # What the plane recorded of the triggers it read, newest first; the setup's profile is
  # the plane's record too, and not what these tests are about.
  defp trail, do: Audit.list(actor: "system:gitops", kind: "trigger")

  describe "the plane's triggers follow the cluster" do
    test "a resource the repository adds becomes a trigger, with a revision and a trail",
         context do
      flux(
        manifest("engineering.nightly-digest", %{
          "agent" => "reviewer",
          "terms" => %{"maxTurns" => 30, "approvals" => "deny", "budgetMicros" => 2_000_000},
          "visibility" => "private",
          "notify" => ["lead@example.test"],
          "concurrency" => 2
        })
      )

      assert %{"engineering.nightly-digest" => %{state: :created, problem: nil}} = pass()

      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.principal_id == context.principal.id
      assert trigger.profile == "dev"
      assert trigger.agent == "reviewer"
      assert trigger.enabled
      assert trigger.source == %{"kind" => "schedule", "cron" => "0 3 * * 1-5"}
      assert trigger.prompt_template == "Summarise what changed yesterday."

      assert trigger.terms == %{
               "max_turns" => 30,
               "approvals" => "deny",
               "budget_micros" => 2_000_000
             }

      assert trigger.visibility == "private"
      assert trigger.review == "required"
      assert trigger.notify == ["lead@example.test"]
      assert trigger.concurrency == 2
      assert trigger.resource_generation == 1
      assert trigger.created_by == "system:gitops"

      # A revision, as an administrator's put makes, and the trail names it.
      assert [revision] = Triggers.revisions(trigger)
      assert revision.revision == 1
      assert revision.created_by == "system:gitops"

      assert [event] = trail()
      assert event.action == "trigger.put"
      assert event.subject_id == "engineering/nightly-digest"
      assert event.detail["__revision_hash__"] == revision.hash
      assert event.detail["profile"]["to"] == "dev"

      # The scheduler fires what is in the rows, and this is one of them now.
      assert Enum.map(Triggers.scheduled(), & &1.name) == ["nightly-digest"]
    end

    test "a change is a new revision, and the run from before still names the one it ran",
         context do
      flux(manifest("engineering.nightly-digest"))
      pass()
      before = Triggers.get(context.team, "nightly-digest")
      [first] = Triggers.revisions(before)

      flux(manifest("engineering.nightly-digest", %{"promptTemplate" => "Summarise last week."}))
      assert %{"engineering.nightly-digest" => %{state: :changed}} = pass()

      trigger = Triggers.get(context.team, "nightly-digest")
      # The same row, so the same id, URL and key.
      assert trigger.id == before.id
      assert trigger.prompt_template == "Summarise last week."
      assert trigger.resource_generation == 2

      assert [second, ^first] = Triggers.revisions(trigger)
      assert second.revision == 2
      assert second.prompt_template == "Summarise last week."

      assert [change, _made] = trail()
      assert change.action == "trigger.put"

      assert change.detail["prompt_template"] == %{
               "from" => "Summarise what changed yesterday.",
               "to" => "Summarise last week."
             }

      assert change.detail["__revision__"] == 2
    end

    test "switching one off is a change to the row and no new revision", context do
      flux(manifest("engineering.nightly-digest"))
      pass()

      flux(manifest("engineering.nightly-digest", %{"enabled" => false}))
      assert %{"engineering.nightly-digest" => %{state: :changed}} = pass()

      trigger = Triggers.get(context.team, "nightly-digest")
      refute trigger.enabled
      assert length(Triggers.revisions(trigger)) == 1
      assert Triggers.scheduled() == []
    end

    test "a field the manifest drops goes back to its default, not to what the row said",
         context do
      flux(manifest("engineering.nightly-digest", %{"concurrency" => 3, "agent" => "reviewer"}))
      pass()

      flux(manifest("engineering.nightly-digest"))
      assert %{"engineering.nightly-digest" => %{state: :changed}} = pass()

      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.concurrency == 1
      assert trigger.agent == nil
    end

    test "a pass over nothing new changes nothing and records nothing" do
      flux(manifest("engineering.nightly-digest"))
      pass()

      assert %{"engineering.nightly-digest" => %{state: :unchanged}} = pass()
      assert length(trail()) == 1
    end

    test "a resource the repository removes takes its trigger with it, and it stops firing",
         context do
      flux(manifest("engineering.nightly-digest"))
      pass()

      FakeCluster.delete("Trigger", "engineering.nightly-digest")
      assert %{"engineering.nightly-digest" => %{state: :removed}} = pass()

      assert Triggers.get(context.team, "nightly-digest") == nil
      assert Triggers.scheduled() == []

      assert [removed | _] = trail()
      assert removed.action == "trigger.delete"
      assert removed.subject_id == "engineering/nightly-digest"
    end

    test "a cluster that cannot be listed changes nothing, rather than reading as empty",
         context do
      flux(manifest("engineering.nightly-digest"))
      pass()

      Application.put_env(:troupe_plane, :k8s_conn, nil)
      assert {:error, :no_cluster} = Gitops.sync(GitopsTriggers)
      assert Triggers.get(context.team, "nightly-digest")
    end

    test "a trigger and the profile it names, added in one commit, are both read in one pass",
         context do
      flux(profile("heavy"))
      flux(manifest("engineering.weekly", %{"profile" => "heavy"}))

      assert %{"Trigger" => {:ok, [%{state: :created, problem: nil}]}} = Gitops.sync_all()
      assert Triggers.get(context.team, "weekly").profile == "heavy"
    end
  end

  describe "a resource the plane cannot use" do
    test "names a team, a principal or a profile the plane does not have", context do
      flux(manifest("research.nightly"))

      flux(manifest("engineering.stranger", %{"principal" => "svc:engineering/nobody"}))

      ops = team_with_grant("ops", "dev", name: "ops")
      {:ok, _, _} = principal!(ops, %{name: "pager", profiles: ["dev"]})
      flux(manifest("engineering.borrowed", %{"principal" => "svc:ops/pager"}))

      flux(manifest("engineering.nowhere", %{"profile" => "gpu"}))
      flux(manifest("nightly"))

      outcomes = pass()

      for name <-
            ~w(research.nightly engineering.stranger engineering.borrowed engineering.nowhere nightly) do
        assert %{state: :refused, problem: "refused"} = outcomes[name], name
      end

      assert [reason] = outcomes["research.nightly"].reasons
      assert reason =~ "names the team research, which this plane does not have"

      assert Enum.any?(
               outcomes["engineering.stranger"].reasons,
               &(&1 =~ "svc:engineering/nobody is not a service principal this plane has")
             )

      assert Enum.any?(
               outcomes["engineering.borrowed"].reasons,
               &(&1 =~ "is not a service principal of the team engineering")
             )

      assert outcomes["engineering.nowhere"].reasons == [
               "spec.profile gpu is not a profile this plane has"
             ]

      assert [reason] = outcomes["nightly"].reasons
      assert reason =~ "metadata.name is <team>.<trigger>"

      assert Triggers.list(context.team) == []
      assert %{problem: "refused", generation: 1} = Gitops.report("Trigger", "research.nightly")
    end

    test "fails put's own checks, and every reason is a sentence in the manifest's words",
         context do
      flux(
        manifest("engineering.bad", %{
          "source" => %{"kind" => "schedule", "cron" => "0 3 * *"},
          "visibility" => "everyone",
          "concurrency" => 0,
          "terms" => %{"max_turns" => 3},
          "notifyUrl" => "/trigger/elsewhere",
          "prompt" => "a key the CRD does not have"
        })
      )

      assert %{"engineering.bad" => %{state: :refused, reasons: reasons}} = pass()
      assert Triggers.get(context.team, "bad") == nil

      for expected <- [
            "spec.source cron is not readable",
            "spec.visibility is invalid",
            "spec.concurrency must be greater than 0",
            "spec.terms takes budgetMicros, maxTurns, wallClockSeconds, approvals, not max_turns",
            "spec.notifyUrl is an absolute http or https URL",
            "spec.prompt is not a field of a Trigger"
          ] do
        assert Enum.any?(reasons, &(&1 =~ expected)),
               "no reason says #{expected}: #{inspect(reasons)}"
      end
    end

    test "a change that fails leaves the trigger as the last version that passed, still firing",
         context do
      flux(manifest("engineering.nightly-digest"))
      pass()

      flux(
        manifest("engineering.nightly-digest", %{
          "promptTemplate" => "Something new.",
          "profile" => "gpu"
        })
      )

      assert %{"engineering.nightly-digest" => %{state: :refused, generation: 2}} = pass()

      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.prompt_template == "Summarise what changed yesterday."
      assert trigger.resource_generation == 1
      assert Enum.map(Triggers.scheduled(), & &1.name) == ["nightly-digest"]

      # Reported where its team looks, beside the trigger it concerns.
      {:ok, [listed]} = Admin.triggers_list(context.root, "engineering")
      assert listed["gitops"]["problem"] == "refused"
      assert listed["gitops"]["problem_generation"] == 2
      assert listed["gitops"]["reasons"] == ["spec.profile gpu is not a profile this plane has"]

      # Put right in the repository, and the report goes with the pass that reads it.
      flux(manifest("engineering.nightly-digest", %{"promptTemplate" => "Something new."}))
      assert %{"engineering.nightly-digest" => %{state: :changed, problem: nil}} = pass()
      assert Triggers.get(context.team, "nightly-digest").prompt_template == "Something new."
      assert Gitops.report("Trigger", "engineering.nightly-digest") == nil
    end

    test "is listed by name for its team, and one with no team for a platform admin", context do
      flux(manifest("engineering.nowhere", %{"profile" => "gpu"}))
      flux(manifest("research.nightly"))
      pass()

      {:ok, listed} = Admin.triggers_list(context.root, "engineering")

      assert %{"name" => "nowhere", "team" => "engineering", "gitops" => nowhere} =
               Enum.find(listed, &(&1["name"] == "nowhere"))

      assert nowhere["resource"] == "engineering.nowhere"
      assert nowhere["source"] == @source
      assert nowhere["reasons"] == ["spec.profile gpu is not a profile this plane has"]

      assert %{"team" => nil, "gitops" => %{"problem" => "refused"}} =
               Enum.find(listed, &(&1["name"] == "research.nightly"))

      # A team admin sees their own team's, and nothing that is nobody's.
      lead = person("lead@example.test", ["engineering"])
      {:ok, _} = Admin.team_admin_add(context.root, "engineering", lead.subject)
      {:ok, listed} = Admin.triggers_list(Admin.actor_for(lead), "engineering")
      assert Enum.map(listed, & &1["name"]) == ["nowhere"]
    end
  end

  describe "writes are refused, and what is done with a trigger is not" do
    setup context do
      flux(manifest("engineering.nightly-digest"))
      pass()
      %{trigger: Triggers.get(context.team, "nightly-digest")}
    end

    test "admin.trigger.put, switching it off included, and the attempt is in the trail",
         context do
      for attrs <- [
            %{"prompt_template" => "Something else."},
            %{"enabled" => false},
            %{"name" => "brand-new", "principal" => "svc:engineering/nightly", "profile" => "dev"}
          ] do
        params = Map.merge(%{"team" => "engineering", "name" => "nightly-digest"}, attrs)

        assert {:error, error} =
                 API.call("admin.trigger.put", %{"trigger" => params}, context.root)

        assert error.message == "managed_by_gitops"
        assert error.code == -32_015
        assert error.data.kind == "Trigger"
        assert error.data.source == @source
      end

      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.enabled
      assert trigger.prompt_template == "Summarise what changed yesterday."
      assert Triggers.get(context.team, "brand-new") == nil

      assert [event | _] = Audit.list(actor: "root@example.test")
      assert event.action == "trigger.put"
      assert event.detail == %{"outcome" => "refused", "reason" => "managed_by_gitops"}
    end

    test "admin.trigger.delete, for a trigger the repository holds", context do
      assert {:error, %{message: "managed_by_gitops"}} =
               API.call(
                 "admin.trigger.delete",
                 %{"team" => "engineering", "name" => "nightly-digest"},
                 context.root
               )

      assert Triggers.get(context.team, "nightly-digest")
    end

    test "over MCP, as a refusal the model can read", context do
      for {tool, arguments} <- [
            {"admin_trigger_put",
             %{
               "trigger" => %{
                 "team" => "engineering",
                 "name" => "nightly-digest",
                 "enabled" => false
               }
             }},
            {"admin_trigger_delete",
             %{"team" => "engineering", "name" => "nightly-digest", "confirm" => "nightly-digest"}}
          ] do
        request = %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"name" => tool, "arguments" => arguments}
        }

        assert {:reply, %{"result" => result}} = MCP.handle(request, context.root)
        assert result["isError"], "#{tool} was not refused"
        assert hd(result["content"])["text"] =~ "managed_by_gitops"
      end
    end

    test "rotating its key works, and the key survives the repository changing the trigger",
         context do
      assert {:ok, minted} =
               API.call(
                 "admin.trigger.key.rotate",
                 %{"team" => "engineering", "name" => "nightly-digest"},
                 context.root
               )

      assert minted.url == "/trigger/#{context.trigger.id}"
      assert Triggers.by_key(context.trigger.id, minted.key)

      flux(manifest("engineering.nightly-digest", %{"promptTemplate" => "Summarise last week."}))
      assert %{"engineering.nightly-digest" => %{state: :changed}} = pass()

      assert %{prompt_template: "Summarise last week."} =
               Triggers.by_key(context.trigger.id, minted.key)
    end

    test "running it by hand works, on the revision the repository's version hashes to",
         context do
      start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
      start_supervised!(Connections)
      start_supervised!(Troupe.Plane.Singleton)
      start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0")

      assert {:ok, fired} =
               API.call(
                 "admin.trigger.run",
                 %{"team" => "engineering", "name" => "nightly-digest"},
                 context.root
               )

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["owner_subject"] == "svc:engineering/nightly"
      assert pushed["prompt"] == "Summarise what changed yesterday."

      [revision] = Triggers.revisions(context.trigger)
      assert fired["run"]["revision_hash"] == revision.hash
      assert fired["run"]["source"] == "manual"
    end

    test "a trigger the cluster has no resource for is kept and may be deleted, and only it",
         context do
      {:ok, leftover} =
        Triggers.put(
          context.team,
          %{
            "name" => "leftover",
            "principal" => "svc:engineering/nightly",
            "profile" => "dev",
            "source" => %{"kind" => "webhook"}
          },
          "root@example.test"
        )

      assert %{
               "engineering.leftover" => %{state: :missing, problem: "missing", reasons: [reason]}
             } =
               pass()

      assert reason =~ "so it goes on firing"
      assert Triggers.get(context.team, "leftover").id == leftover.id

      assert {:ok, %{deleted: true}} =
               Admin.trigger_delete(context.root, "engineering", "leftover")

      assert Triggers.get(context.team, "leftover") == nil
      assert Gitops.report("Trigger", "engineering.leftover") == nil
    end
  end

  describe "bootstrapping a repository from a running plane" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)
      :ok
    end

    test "every trigger, with nothing the plane keeps of its own", context do
      {:ok, _} =
        Admin.trigger_put(context.root, %{
          "team" => "engineering",
          "name" => "nightly-digest",
          "principal" => "svc:engineering/nightly",
          "profile" => "dev",
          "agent" => "reviewer",
          "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5", "tz" => "UTC"},
          "prompt_template" => "Summarise what changed yesterday.\nKeep it short.",
          "terms" => %{"max_turns" => 30, "approvals" => "deny"},
          "notify_url" => "https://hooks.example.test/troupe"
        })

      {:ok, minted} = Admin.trigger_key_rotate(context.root, "engineering", "nightly-digest")

      assert {:ok, export} = API.call("admin.profiles.export", %{}, context.root)

      assert [
               %{
                 name: "engineering.nightly-digest",
                 team: "engineering",
                 path: "triggers/engineering/nightly-digest.yaml",
                 notes: [note | _],
                 yaml: yaml
               }
             ] = export.triggers

      assert note =~ "has a key of its own, which stays with the plane"

      assert YamlElixir.read_from_string!(yaml) == %{
               "apiVersion" => "troupe.dev/v1alpha1",
               "kind" => "Trigger",
               "metadata" => %{
                 "name" => "engineering.nightly-digest",
                 "namespace" => FakeCluster.namespace()
               },
               "spec" => %{
                 "principal" => "svc:engineering/nightly",
                 "profile" => "dev",
                 "agent" => "reviewer",
                 "enabled" => true,
                 "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5", "tz" => "UTC"},
                 "promptTemplate" => "Summarise what changed yesterday.\nKeep it short.",
                 "terms" => %{"maxTurns" => 30, "approvals" => "deny"},
                 "visibility" => "team",
                 "review" => "required",
                 "notifyUrl" => "https://hooks.example.test/troupe",
                 "concurrency" => 1
               }
             }

      refute yaml =~ minted.key
    end

    test "an exported trigger is read back as the trigger it came from, key and all", context do
      {:ok, _} =
        Admin.trigger_put(context.root, %{
          "team" => "engineering",
          "name" => "nightly-digest",
          "principal" => "svc:engineering/nightly",
          "profile" => "dev",
          "source" => %{"kind" => "webhook", "provider" => "generic"},
          "prompt_template" => "Triage {{event.issue.key}}.",
          "terms" => %{"budget_micros" => 1_000_000, "wall_clock_seconds" => 600},
          "notify" => ["lead@example.test"],
          "review" => "none",
          "enabled" => false
        })

      {:ok, minted} = Admin.trigger_key_rotate(context.root, "engineering", "nightly-digest")
      before = Triggers.get(context.team, "nightly-digest")
      [revision] = Triggers.revisions(before)

      {:ok, export} = Admin.profiles_export(context.root)

      # Committed, applied by Flux, and the plane switched.
      for %{yaml: yaml} <- export.triggers, do: flux(YamlElixir.read_from_string!(yaml))
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)

      assert %{"engineering.nightly-digest" => %{state: :unchanged, problem: nil}} = pass()

      after_ = Triggers.get(context.team, "nightly-digest")
      assert after_.id == before.id
      assert after_.resource_generation == 1

      for field <- ~w(principal_id profile agent enabled source prompt_template terms visibility
                      review notify notify_url concurrency)a do
        assert Map.fetch!(after_, field) == Map.fetch!(before, field), "#{field} moved"
      end

      assert Triggers.revisions(after_) == [revision]
      assert Triggers.by_key(before.id, minted.key)
      assert trail() == []
    end
  end

  describe "the CRD" do
    test "has the fields the plane reads, and the terms session.create takes" do
      crd =
        "../../../../../charts/troupe/crds/trigger.yaml"
        |> Path.expand(__DIR__)
        |> YamlElixir.read_from_file!()

      assert crd["spec"]["names"]["kind"] == GitopsTriggers.kind()
      assert crd["spec"]["group"] <> "/v1alpha1" == GitopsTriggers.api_version()

      assert [%{"name" => "v1alpha1", "schema" => %{"openAPIV3Schema" => schema}}] =
               crd["spec"]["versions"]

      spec = schema["properties"]["spec"]
      assert Enum.sort(Map.keys(spec["properties"])) == Enum.sort(GitopsTriggers.spec_keys())

      # Spelt as fields are here, and the same four `session.create` checks.
      assert Enum.sort(Map.keys(spec["properties"]["terms"]["properties"])) ==
               ~w(approvals budgetMicros maxTurns wallClockSeconds)

      assert Enum.sort(Triggers.term_keys()) ==
               ~w(approvals budget_micros max_turns wall_clock_seconds)

      # Nothing a person writes is dropped before the plane can say it is wrong.
      assert spec["x-kubernetes-preserve-unknown-fields"]
    end
  end

  describe "direct mode" do
    test "is what it was: nothing is read, nothing is refused, and nothing says gitops",
         context do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      assert {:ok, %{trigger: %{"name" => "manual-one"}}} =
               Admin.trigger_put(context.root, %{
                 "team" => "engineering",
                 "name" => "manual-one",
                 "principal" => "svc:engineering/nightly",
                 "profile" => "dev",
                 "source" => %{"kind" => "manual"}
               })

      assert {:ok, [listed]} = Admin.triggers_list(context.root, "engineering")
      refute Map.has_key?(listed, "gitops")

      assert {:ok, %{deleted: true}} =
               Admin.trigger_delete(context.root, "engineering", "manual-one")
    end
  end
end
