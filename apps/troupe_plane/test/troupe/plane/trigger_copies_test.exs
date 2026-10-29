defmodule Troupe.Plane.TriggerCopiesTest do
  @moduledoc """
  A direct plane and the `Trigger` resources an applier put in its namespace: it lists
  them with the plane's checks and never acts on one by itself, and an administrator
  copies one into a row and copies it again when the repository changes it.

  What each test checks is the answer of `admin.triggers.repository`, the row the copy
  leaves, what it keeps (its id, key, runs and revisions) and the audit trail. A gitops
  plane is checked to be what it was. The cluster is `FakeCluster`, in memory.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakeCluster, Fleet, Gitops, Identity, Repo, Triggers}
  alias Troupe.Plane.Admin.{API, MCP}
  alias Troupe.Plane.Gitops.Triggers, as: GitopsTriggers
  alias Troupe.Plane.Triggers.Run

  @moduletag timeout: 60_000

  @flux "kustomize-controller"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :provisioning_mode, :direct)

    on_exit(fn ->
      for key <- ~w(platform_admin_group provisioning_mode)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    FakeCluster.start()

    for name <- ~w(dev gpu heavy) do
      {:ok, _} = Fleet.put_profile(%{name: name, replicas: 1, sessions_per_pod: 4})
    end

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    {:ok, _} = Identity.grant(team, "heavy", %{})
    {:ok, principal, _secret} = principal!(team, %{name: "nightly", profiles: ["dev"]})

    %{
      root: Admin.actor_for(person("root@example.test", ["platform"])),
      team: team,
      principal: principal
    }
  end

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
            "source" => %{"kind" => "webhook", "provider" => "generic"},
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

  defp repository(actor, team \\ "engineering") do
    {:ok, answer} = Admin.triggers_repository(actor, team)
    answer
  end

  defp listed(answer, resource), do: Enum.find(answer.resources, &(&1["resource"] == resource))

  describe "listing" do
    test "shows each resource with its generation, whether it passes and why not", context do
      flux(manifest("engineering.nightly-digest"))
      flux(manifest("engineering.stranger", %{"principal" => "svc:engineering/nobody"}))
      flux(manifest("engineering.gpu", %{"profile" => "gpu"}))
      flux(manifest("engineering.heavy", %{"profile" => "heavy"}))
      flux(manifest("admin.nightly"))

      answer = repository(context.root)
      assert answer.listed

      assert %{"passes" => true, "reasons" => [], "generation" => 1, "copy" => nil} =
               listed(answer, "engineering.nightly-digest")

      assert listed(answer, "engineering.nightly-digest")["source"] == %{
               "kind" => "webhook",
               "provider" => "generic"
             }

      assert %{"passes" => false, "reasons" => [stranger]} =
               listed(answer, "engineering.stranger")

      assert stranger =~ "svc:engineering/nobody is not a service principal this plane has"

      assert listed(answer, "engineering.gpu")["reasons"] == [
               "the team engineering is not granted the profile gpu: grant it first (admin.team.grant)"
             ]

      assert listed(answer, "engineering.heavy")["reasons"] == [
               "svc:engineering/nightly is not granted the profile heavy: its profiles are dev"
             ]

      # A team this plane has not got, shown to a platform admin with no team.
      assert %{"team" => nil, "name" => "admin.nightly", "reasons" => [missing]} =
               listed(answer, "admin.nightly")

      assert missing =~ "names the team admin, which this plane does not have"

      # Listing acts on nothing.
      assert Triggers.list(context.team) == []

      # A team admin sees their team's and nothing that is nobody's.
      lead = person("lead@example.test", ["engineering"])
      {:ok, _} = Admin.team_admin_add(context.root, "engineering", lead.subject)
      names = Enum.map(repository(Admin.actor_for(lead)).resources, & &1["resource"])

      assert Enum.sort(names) ==
               ~w(engineering.gpu engineering.heavy engineering.nightly-digest engineering.stranger)
    end

    test "a cluster that does not answer is said, and the team's triggers are untouched",
         context do
      Application.put_env(:troupe_plane, :k8s_conn, nil)
      answer = repository(context.root)
      refute answer.listed
      assert answer.reason =~ "the cluster did not list its Trigger resources"
      assert answer.resources == []
    end
  end

  describe "copy" do
    test "makes the row with the resource and its generation, and mints a key shown once",
         context do
      flux(manifest("engineering.nightly-digest"))

      assert {:ok, copied} =
               API.call(
                 "admin.trigger.copy",
                 %{"resource" => "engineering.nightly-digest"},
                 context.root
               )

      assert copied.made
      assert copied.generation == 1
      assert is_binary(copied.key)

      trigger = Triggers.get(context.team, "nightly-digest")
      assert copied.url == "/trigger/#{trigger.id}"
      assert Triggers.by_key(trigger.id, copied.key)
      assert trigger.copied_from == "engineering.nightly-digest"
      assert trigger.copied_generation == 1
      assert trigger.resource_generation == nil
      assert trigger.principal_id == context.principal.id
      assert trigger.prompt_template == "Summarise what changed yesterday."
      assert copied.trigger["copied_generation"] == 1

      # Shown once: the listing and the trigger say only that it has a key.
      {:ok, [row]} = Admin.triggers_list(context.root, "engineering")
      assert row["has_key"]
      refute inspect(row) =~ copied.key

      assert %{"copy" => %{"state" => "copied", "copied_generation" => 1, "diff" => %{}}} =
               listed(repository(context.root), "engineering.nightly-digest")

      assert [event] = Audit.list(kind: "trigger")
      assert event.action == "trigger.copy"
      assert event.actor == "root@example.test"
      assert event.subject_id == "engineering/nightly-digest"
      assert event.detail["__resource__"] == "engineering.nightly-digest"
      assert event.detail["__generation__"] == 1
      assert event.detail["__key_minted__"]
      assert event.detail["__revision_hash__"] == copied.revision["hash"]
      assert event.detail["profile"]["to"] == "dev"
      refute inspect(event.detail) =~ copied.key
    end

    test "is refused with the check's reason, and makes nothing", context do
      flux(manifest("engineering.heavy", %{"profile" => "heavy"}))

      assert {:error, error} = Admin.trigger_copy(context.root, "engineering.heavy")
      assert error.message == "invalid_params"

      assert error.data.reasons == [
               "svc:engineering/nightly is not granted the profile heavy: its profiles are dev"
             ]

      assert {:error, %{message: "not_found"}} =
               Admin.trigger_copy(context.root, "engineering.absent")

      assert {:error, %{data: %{reason: reason}}} = Admin.trigger_copy(context.root, "nodot")
      assert reason =~ "<team>.<trigger>"

      assert Triggers.list(context.team) == []
      assert Audit.list(kind: "trigger") == []
    end

    test "a team admin copies their team's and not another's", context do
      ops = team_with_grant("ops", "dev", name: "ops")
      {:ok, _, _} = principal!(ops, %{name: "pager", profiles: ["dev"]})
      flux(manifest("ops.page", %{"principal" => "svc:ops/pager"}))

      lead = person("lead@example.test", ["engineering"])
      {:ok, _} = Admin.team_admin_add(context.root, "engineering", lead.subject)

      assert {:error, %{message: "not_found"}} =
               Admin.trigger_copy(Admin.actor_for(lead), "ops.page")

      assert Triggers.get(ops, "page") == nil
    end
  end

  describe "re-copy" do
    setup context do
      flux(manifest("engineering.nightly-digest"))
      {:ok, copied} = Admin.trigger_copy(context.root, "engineering.nightly-digest")
      %{copied: copied, trigger: Triggers.get(context.team, "nightly-digest")}
    end

    test "a newer generation reads changed with the diff, and re-copy keeps URL, key, runs",
         context do
      [first] = Triggers.revisions(context.trigger)
      run = run!(context.trigger, first)

      flux(
        manifest("engineering.nightly-digest", %{
          "promptTemplate" => "Summarise last week.",
          "concurrency" => 2
        })
      )

      # Nothing follows by itself.
      assert Triggers.get(context.team, "nightly-digest").prompt_template ==
               "Summarise what changed yesterday."

      assert %{"generation" => 2, "copy" => copy} =
               listed(repository(context.root), "engineering.nightly-digest")

      assert copy["state"] == "changed"
      assert copy["copied_generation"] == 1

      assert copy["diff"] == %{
               "prompt_template" => %{
                 "from" => "Summarise what changed yesterday.",
                 "to" => "Summarise last week."
               },
               "concurrency" => %{"from" => 1, "to" => 2}
             }

      assert {:ok, again} = Admin.trigger_copy(context.root, "engineering.nightly-digest")
      refute again.made
      refute Map.has_key?(again, :key)
      assert again.generation == 2

      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.id == context.trigger.id
      assert trigger.prompt_template == "Summarise last week."
      assert trigger.concurrency == 2
      assert trigger.copied_generation == 2
      assert Triggers.by_key(trigger.id, context.copied.key)
      assert Repo.get(Run, run.id)
      assert [second, ^first] = Triggers.revisions(trigger)
      assert second.revision == 2

      assert %{"copy" => %{"state" => "copied", "diff" => %{}}} =
               listed(repository(context.root), "engineering.nightly-digest")

      assert [recopy, _copy] = Audit.list(kind: "trigger")
      assert recopy.action == "trigger.copy"
      assert recopy.detail["__generation__"] == 2
      assert recopy.detail["__revision__"] == 2
      assert recopy.detail["prompt_template"]["to"] == "Summarise last week."
      refute recopy.detail["__key_minted__"]
    end

    test "a console put to a copied row marks it differs from the repository", context do
      {:ok, _} =
        Admin.trigger_put(context.root, %{
          "team" => "engineering",
          "name" => "nightly-digest",
          "prompt_template" => "Edited in the console."
        })

      assert %{"copy" => copy} = listed(repository(context.root), "engineering.nightly-digest")
      assert copy["state"] == "differs"

      assert copy["diff"] == %{
               "prompt_template" => %{
                 "from" => "Edited in the console.",
                 "to" => "Summarise what changed yesterday."
               }
             }

      # The row keeps what it was copied from: the edit is the row's, not the repository's.
      assert Triggers.get(context.team, "nightly-digest").copied_generation == 1
    end

    test "a removed resource marks its row gone, and the row keeps running", context do
      FakeCluster.delete("Trigger", "engineering.nightly-digest")

      answer = repository(context.root)
      assert answer.resources == []

      assert [
               %{
                 "state" => "gone",
                 "name" => "nightly-digest",
                 "resource" => "engineering.nightly-digest",
                 "copied_generation" => 1
               }
             ] = answer.gone

      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.enabled
      assert Triggers.by_key(trigger.id, context.copied.key)

      assert {:error, %{message: "not_found"}} =
               Admin.trigger_copy(context.root, "engineering.nightly-digest")

      assert {:ok, %{deleted: true}} =
               Admin.trigger_delete(context.root, "engineering", "nightly-digest")

      assert repository(context.root).gone == []
    end

    test "a row typed in the console is not_copied, and a copy takes it over in place",
         context do
      {:ok, _} =
        Admin.trigger_put(context.root, %{
          "team" => "engineering",
          "name" => "typed",
          "principal" => "svc:engineering/nightly",
          "profile" => "dev",
          "source" => %{"kind" => "manual"}
        })

      before = Triggers.get(context.team, "typed")
      flux(manifest("engineering.typed", %{"source" => %{"kind" => "manual"}}))

      assert %{"copy" => %{"state" => "not_copied", "diff" => diff}} =
               listed(repository(context.root), "engineering.typed")

      assert diff["prompt_template"]["to"] == "Summarise what changed yesterday."

      assert {:ok, %{made: false}} = Admin.trigger_copy(context.root, "engineering.typed")
      after_ = Triggers.get(context.team, "typed")
      assert after_.id == before.id
      assert after_.copied_from == "engineering.typed"
    end
  end

  describe "a gitops plane" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      :ok
    end

    test "refuses both, audits the copy, and its pass is what it was", context do
      flux(manifest("engineering.nightly-digest"))

      assert {:error, %{message: "invalid_request"}} =
               Admin.triggers_repository(context.root, "engineering")

      assert {:error, %{message: "managed_by_gitops"}} =
               Admin.trigger_copy(context.root, "engineering.nightly-digest")

      assert [event] = Audit.list(actor: "root@example.test", kind: "trigger")
      assert event.action == "trigger.copy"
      assert event.detail == %{"outcome" => "refused", "reason" => "managed_by_gitops"}

      assert {:ok, [%{state: :created}]} = Gitops.sync(GitopsTriggers)
      trigger = Triggers.get(context.team, "nightly-digest")
      assert trigger.resource_generation == 1
      assert trigger.copied_from == nil
      assert trigger.copied_generation == nil
    end

    test "a copied row is the resource's at the switch, and the pass changes nothing",
         context do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)
      flux(manifest("engineering.nightly-digest"))
      {:ok, _} = Admin.trigger_copy(context.root, "engineering.nightly-digest")
      before = Triggers.get(context.team, "nightly-digest")

      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      assert {:ok, [%{state: :unchanged}]} = Gitops.sync(GitopsTriggers)
      assert Triggers.get(context.team, "nightly-digest").id == before.id
      assert Triggers.revisions(before) |> length() == 1
    end
  end

  describe "the surfaces" do
    test "both methods are tools, and the copy is not idempotent", context do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
      assert {:reply, %{"result" => %{"tools" => tools}}} = MCP.handle(request, context.root)
      by_name = Map.new(tools, &{&1["name"], &1})

      assert by_name["admin_triggers_repository"]["annotations"]["readOnlyHint"]
      refute by_name["admin_trigger_copy"]["annotations"]["idempotentHint"]
      assert by_name["admin_trigger_copy"]["inputSchema"]["required"] == ["resource"]
    end

    test "the chart's direct Role reads Trigger resources and writes none" do
      rbac =
        File.read!(Path.expand("../../../../../charts/troupe/templates/plane-rbac.yaml", __DIR__))

      [_gitops, direct] = String.split(rbac, "{{- else }}", parts: 2)
      [direct | _] = String.split(direct, "{{- end }}", parts: 2)

      assert direct =~ ~s(resources: ["triggers"]\n    verbs: ["get", "list"])
    end
  end

  defp run!(trigger, revision) do
    %Run{}
    |> Run.changeset(%{
      trigger_id: trigger.id,
      revision_id: revision.id,
      idempotency_key: "test-#{System.unique_integer([:positive])}",
      fired_at: DateTime.utc_now(),
      fired_by: "root@example.test",
      source: "manual",
      state: "skipped",
      reason: "a run from before the re-copy"
    })
    |> Repo.insert!()
  end
end
