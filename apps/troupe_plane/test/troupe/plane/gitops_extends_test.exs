defmodule Troupe.Plane.GitopsExtendsTest do
  @moduledoc """
  A repository's manifest that extends another profile (#655 slice 4): Flux applies it as
  written, with `spec.extends` and only what differs; the plane resolves the chain against
  its rows, keeps the profile in effect on the child's row, and writes it flat into the
  resource's status (`status.effective`) for the operator and admission to read. The plane
  writes nothing of the manifest's spec but its own three fields, so Flux and the plane
  never write the same one.

  On the chunk's tip every manifest naming a parent was refused (slice 1's GitOps rule),
  and the resource had no status block, budget or rules to carry.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, FakeCluster, Fleet, Gitops, Identity}
  alias Troupe.Plane.Gitops.Profiles
  alias Troupe.WorkerProfile

  @moduletag timeout: 60_000

  @flux "kustomize-controller"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)

    on_exit(fn ->
      for key <- ~w(platform_admin_group provisioning_mode policy)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    FakeCluster.start()

    %{actor: Admin.actor_for(person("root@example.test", ["platform"]))}
  end

  defp standard(spec \\ %{}) do
    resource(
      "standard",
      %{
        "image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1.2.3"},
        "sessionsPerPod" => 4,
        "llm" => %{"endpoint" => "https://gateway.example.test/v1", "model" => "gpt-4o"},
        "egress" => %{"fqdns" => ["gateway.example.test"]},
        "configBundleChannel" => "stable",
        "budgetMicros" => 50_000_000,
        "permissions" => %{"deny" => ["shell(curl)"], "allow" => ["shell(mix test)"]}
      }
      |> Map.merge(spec)
    )
  end

  # Named to be listed before its parent, so a pass that read them as listed would resolve
  # it against the parent's last version.
  defp data_team(spec \\ %{}) do
    resource(
      "a-data-team",
      %{
        "extends" => "standard",
        "llm" => %{"model" => "gpt-4.1"},
        "egress" => %{"fqdns" => ["warehouse.example.test"]},
        "budgetMicros" => 20_000_000,
        "permissions" => %{"ask" => ["mcp(issues.delete)"], "allow" => ["shell(curl)"]}
      }
      |> Map.merge(spec)
    )
  end

  defp resource(name, spec) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
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

  defp owned(resource, manager) do
    Enum.find_value(resource["metadata"]["managedFields"], %{}, fn entry ->
      if entry["manager"] == manager and is_nil(entry["subresource"]), do: entry["fieldsV1"]
    end)
  end

  defp effective(name),
    do: get_in(FakeCluster.get("WorkerProfile", name), ["status", "effective"])

  describe "a manifest that extends another" do
    test "is resolved into the row and written flat into its status, and its spec is the repository's" do
      flux(standard())
      flux(data_team())

      assert %{"standard" => %{state: :created, problem: nil}, "a-data-team" => child} = pass()
      assert %{state: :created, problem: nil} = child

      row = Fleet.get_profile("a-data-team")
      assert row.extends == "standard"
      assert row.own["spec"]["llm"] == %{"model" => "gpt-4.1"}
      # The profile in effect, by #655's rules: the image and endpoint the parent's, the
      # model replaced, the hosts and the rules added, the budget the lower.
      assert row.image == "ghcr.io/troupe/worker:1.2.3"

      assert row.spec["llm"] == %{
               "endpoint" => "https://gateway.example.test/v1",
               "model" => "gpt-4.1"
             }

      assert row.spec["egress"]["fqdns"] == ["gateway.example.test", "warehouse.example.test"]
      assert row.budget_micros == 20_000_000

      assert row.spec["permissions"] == %{
               "deny" => ["shell(curl)"],
               "ask" => ["mcp(issues.delete)"],
               "allow" => ["shell(mix test)", "shell(curl)"]
             }

      status = effective("a-data-team")
      assert status["chain"] == ["standard", "a-data-team"]

      assert status["spec"]["image"] == %{
               "repository" => "ghcr.io/troupe/worker",
               "tag" => "1.2.3"
             }

      assert status["spec"]["llm"]["model"] == "gpt-4.1"

      assert status["spec"]["egress"]["fqdns"] == [
               "gateway.example.test",
               "warehouse.example.test"
             ]

      refute Map.has_key?(status["spec"], "extends")
      refute Map.has_key?(status["spec"], "replicas")
      assert status["from"]["spec.llm.model"] == "a-data-team"
      assert status["from"]["spec.llm.endpoint"] == "standard"
      assert status["from"]["spec.egress.fqdns"]["warehouse.example.test"] == "a-data-team"
      assert status["revision"] == WorkerProfile.revision_of(status["spec"])

      # What the operator runs: the flat profile, with the plane's three from the spec.
      resource = FakeCluster.get("WorkerProfile", "a-data-team")
      assert {:ok, running} = WorkerProfile.in_effect(resource)
      parsed = WorkerProfile.from_resource(running)
      assert parsed.image == "ghcr.io/troupe/worker:1.2.3"
      assert parsed.llm_model == "gpt-4.1"
      assert parsed.replicas == Fleet.get_profile("a-data-team").replicas

      # The spec is the repository's and the plane's three; the status block is the plane's.
      for entry <- resource["metadata"]["managedFields"],
          entry["manager"] == "troupe-plane",
          is_nil(entry["subresource"]),
          key <- Map.keys(entry["fieldsV1"]["f:spec"] || %{}),
          do: assert(key in ~w(f:mcpServers f:replicas f:teams))

      assert get_in(owned(resource, @flux), ["f:spec", "f:extends"])

      assert Enum.any?(
               resource["metadata"]["managedFields"],
               &(&1["manager"] == "troupe-plane" and &1["subresource"] == "status")
             )
    end

    test "a parent's change in the repository reaches the child's status in the same pass" do
      flux(standard())
      flux(data_team())
      pass()
      before = effective("a-data-team")

      flux(standard(%{"egress" => %{"fqdns" => ["gateway.example.test", "docs.example.test"]}}))
      assert %{"standard" => %{state: :changed}, "a-data-team" => %{state: :changed}} = pass()

      after_change = effective("a-data-team")

      assert after_change["spec"]["egress"]["fqdns"] ==
               ["gateway.example.test", "docs.example.test", "warehouse.example.test"]

      refute after_change["revision"] == before["revision"]

      # And nothing is written again when nothing changed.
      writes = FakeCluster.writes()
      assert %{"a-data-team" => %{state: :unchanged}} = pass()
      assert FakeCluster.writes() == writes
    end

    test "a default the API server filled in is not the child's, and leaves the parent's" do
      flux(standard(%{"configBundleChannel" => "beta", "orgMount" => true}))
      flux(data_team())

      FakeCluster.default(
        "WorkerProfile",
        "a-data-team",
        ["spec", "configBundleChannel"],
        "stable"
      )

      FakeCluster.default("WorkerProfile", "a-data-team", ["spec", "orgMount"], false)
      FakeCluster.default("WorkerProfile", "a-data-team", ["spec", "sessionsPerPod"], 4)

      pass()

      row = Fleet.get_profile("a-data-team")
      refute Map.has_key?(row.own["spec"], "configBundleChannel")
      assert row.spec["configBundleChannel"] == "beta"
      assert row.spec["orgMount"] == true
    end

    test "is refused while its parent is not a profile here, and resolved once it is" do
      flux(data_team())

      assert %{"a-data-team" => %{state: :refused, reasons: [reason]}} = pass()
      assert reason =~ "a-data-team extends standard, which is not a profile on this plane"
      assert Fleet.get_profile("a-data-team") == nil
      assert effective("a-data-team") == nil

      flux(standard())
      assert %{"a-data-team" => %{state: :created}} = pass()
      assert effective("a-data-team")["chain"] == ["standard", "a-data-team"]
    end

    test "a budget above its parent's, or a rule the pods could not read, is refused" do
      flux(standard())
      flux(data_team(%{"budgetMicros" => 80_000_000}))

      assert %{"a-data-team" => %{state: :refused, reasons: reasons}} = pass()
      assert Enum.any?(reasons, &(&1 =~ "can only lower its budget"))

      flux(data_team(%{"permissions" => %{"deny" => ["Bash(curl)"]}}))
      assert %{"a-data-team" => %{state: :refused, reasons: reasons}} = pass()
      assert Enum.any?(reasons, &(&1 =~ "permissions.deny"))
    end

    test "one that stops extending is read whole again, and the plane takes its block out of the status" do
      flux(standard())
      flux(data_team())
      pass()
      assert effective("a-data-team")

      flux(
        data_team(%{
          "extends" => nil,
          "image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "2.0.0"},
          "llm" => %{"endpoint" => "https://gateway.example.test/v1", "model" => "gpt-4.1"},
          "budgetMicros" => nil
        })
        |> update_in(["spec"], &Map.delete(&1, "extends"))
      )

      pass()

      assert Fleet.get_profile("a-data-team").extends == nil
      assert effective("a-data-team") == nil
    end

    test "a parent named in the annotation is refused, saying where a parent is named" do
      flux(put_in(standard(), ["metadata", "annotations"], %{"troupe.dev/extends" => "base"}))

      assert %{"standard" => %{state: :refused, reasons: [reason]}} = pass()
      assert reason =~ "name the profile this one extends in spec.extends"
    end

    test "is exported as the repository would hold it: the parent named, and what the child wrote" do
      flux(standard())
      flux(data_team())
      pass()

      exported = Enum.find(Profiles.export(), &(&1.name == "a-data-team"))
      manifest = YamlElixir.read_from_string!(exported.yaml)

      assert manifest["spec"]["extends"] == "standard"
      assert manifest["spec"]["llm"] == %{"model" => "gpt-4.1"}
      assert manifest["spec"]["budgetMicros"] == 20_000_000
      refute Map.has_key?(manifest["spec"], "image")
      refute Map.has_key?(manifest["spec"], "replicas")
    end
  end
end
