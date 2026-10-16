defmodule Troupe.Plane.ExtendsTest do
  @moduledoc """
  A profile that extends another (#655 slice 1): the plane resolves the two into one flat
  profile, writes that to the cluster, and writes it again when the parent changes.

  `standard` is the profile everybody may use and `data-team` the one that extends it, as
  the issue tells it. The cluster is `FakeWorkerProfiles`, which hands each resource the
  plane applies back to the test as it was sent.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Bundles, FakeWorkerProfiles, Fleet, Identity}
  alias Troupe.Plane.Fleet.Extends
  alias Troupe.Plane.Gitops.Profiles, as: GitopsProfiles

  @moduletag timeout: 60_000

  @image "ghcr.io/troupe/worker:1"

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

    %{actor: Admin.actor_for(root)}
  end

  defp standard do
    %{
      "name" => "standard",
      "image" => @image,
      "max_sessions" => 20,
      "warm_workers" => 1,
      "spec" => %{
        "llm" => %{
          "endpoint" => "https://llm.example.test/v1",
          "model" => "big",
          "secretRef" => %{"name" => "standard-llm", "key" => "api-key"}
        },
        "egress" => %{"fqdns" => ["docs.example.test"], "gitHosts" => ["git.example.test"]},
        "mcpServers" => [%{"name" => "wiki", "url" => "https://wiki.example.test/mcp"}],
        "mcpIdentities" => [
          %{
            "server" => "wiki",
            "clientId" => "standard-client",
            "transitKey" => "troupe-w-standard.wiki",
            "certificateThumbprint" => String.duplicate("A", 43)
          }
        ],
        "personalTools" => "forbid",
        "github" => %{"permissions" => %{"contents" => "read"}}
      }
    }
  end

  defp data_team do
    %{
      "name" => "data-team",
      "extends" => "standard",
      "max_sessions" => 50,
      "spec" => %{
        "llm" => %{"model" => "small"},
        "egress" => %{"fqdns" => ["warehouse.example.test", "docs.example.test"]},
        "mcpServers" => [%{"name" => "warehouse", "url" => "https://warehouse.example.test/mcp"}],
        "personalTools" => "allow",
        "repositoryOverridesBundle" => true
      }
    }
  end

  describe "the effective profile" do
    test "is the merge #655's table gives, and is what the cluster gets", context do
      FakeWorkerProfiles.start(%{"standard" => %{}, "data-team" => %{}})
      _ = team_with_grant("analysts", "standard", name: "analysts", volume_storage_class: "shared")

      assert {:ok, _} = Admin.profile_put(context.actor, standard())
      assert_receive {FakeWorkerProfiles, :applied, "standard", _standard, _query}

      assert {:ok, put} = Admin.profile_put(context.actor, data_team())
      assert put.profile.extends == "standard"
      assert_receive {FakeWorkerProfiles, :applied, "data-team", resource, _query}

      spec = resource["spec"]

      # Added: the parent's, then the child's the parent lacks.
      assert spec["egress"]["fqdns"] == ["docs.example.test", "warehouse.example.test"]
      assert spec["egress"]["gitHosts"] == ["git.example.test"]
      assert Enum.map(spec["mcpServers"], & &1["name"]) == ["wiki", "warehouse"]

      # Replaced where the child sets it, the parent's where it does not.
      assert spec["image"] == %{"repository" => "ghcr.io/troupe/worker", "tag" => "1"}
      assert spec["llm"]["endpoint"] == "https://llm.example.test/v1"
      assert spec["llm"]["model"] == "small"
      assert spec["github"] == %{"permissions" => %{"contents" => "read"}}

      # Restrict only: the parent's forbid holds whatever the child says; the child may
      # still restrict what the parent left open, and `true` is not a restriction.
      assert spec["personalTools"] == "forbid"
      assert spec["repositoryOverridesBundle"] == true

      # Never inherited: the parent's key and its identities are its own, and so are its
      # grants, which `teams` projects.
      refute Map.has_key?(spec["llm"], "secretRef")
      refute Map.has_key?(spec, "mcpIdentities")
      assert spec["teams"] == []

      # Narrow only, and the child's own warmth.
      row = Fleet.get_profile("data-team")
      assert row.max_sessions == 20
      assert row.warm_workers == 0
      assert row.own["max_sessions"] == 50
    end

    test "a child's server with a parent's name replaces it only when it says override", context do
      assert {:ok, _} = Admin.profile_put(context.actor, standard())

      clash = [%{"name" => "wiki", "url" => "https://other-wiki.example.test/mcp"}]

      {:ok, _} =
        Admin.profile_put(context.actor, put_in(data_team(), ["spec", "mcpServers"], clash))

      assert {:ok, %{effective: effective}} = Admin.profile_get(context.actor, "data-team", true)
      assert [%{"url" => "https://wiki.example.test/mcp"} | _] = effective.profile["spec"]["mcpServers"]
      assert Enum.any?(effective.problems, &(&1 =~ "say override: true on data-team's to replace it"))

      overriding = [Map.put(hd(clash), "override", true)]

      {:ok, _} =
        Admin.profile_put(context.actor, put_in(data_team(), ["spec", "mcpServers"], overriding))

      servers = Fleet.get_profile("data-team").spec["mcpServers"]
      # The resource has no field for the flag, and does not get it.
      assert [%{"name" => "wiki", "url" => "https://other-wiki.example.test/mcp"} = wiki] = servers
      refute Map.has_key?(wiki, "override")
    end

    test "each field says which profile it came from", context do
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())

      assert {:ok, got} = Admin.profile_get(context.actor, "data-team", true)

      # As written, for an editor to send back: only what data-team sets.
      assert got.written["extends"] == "standard"
      refute Map.has_key?(got.spec["egress"], "gitHosts")
      assert got.spec["llm"] == %{"model" => "small"}

      from = Map.new(got.effective.fields, &{{&1.path, &1.value}, &1.from})

      assert got.effective.chain == ["standard", "data-team"]
      assert from[{"image", @image}] == "standard"
      assert from[{"max_sessions", 20}] == "standard"
      assert from[{"spec.llm.model", "small"}] == "data-team"
      assert from[{"spec.llm.endpoint", "https://llm.example.test/v1"}] == "standard"
      assert from[{"spec.egress.fqdns", "docs.example.test"}] == "standard"
      assert from[{"spec.egress.fqdns", "warehouse.example.test"}] == "data-team"
      assert from[{"spec.mcpServers", "wiki"}] == "standard"
      assert from[{"spec.mcpServers", "warehouse"}] == "data-team"
      assert from[{"spec.personalTools", "forbid"}] == "standard"

      # And the parent's key, which is not the child's, is said rather than left silent.
      assert Enum.any?(got.effective.problems, &(&1 =~ "set llm.secretRef to a Secret of data-team's"))

      # The parent knows who extends it.
      assert {:ok, %{extended_by: ["data-team"]}} = Admin.profile_get(context.actor, "standard")
    end

    test "a server the child has from its parent that it has no identity for is reported", context do
      parent = put_in(standard(), ["spec", "configBundleChannel"], "standard-channel")
      {:ok, _} = Admin.profile_put(context.actor, parent)

      # Its own channel, so the jira server is the parent's only.
      child = put_in(data_team(), ["spec", "configBundleChannel"], "stable")
      assert {:ok, %{identity_problems: []}} = Admin.profile_put(context.actor, child)

      {:ok, _} =
        Bundles.publish(
          "standard-channel",
          %{
            "schema" => 1,
            "mcp_servers" => [
              %{
                "name" => "jira",
                "url" => "https://jira.example.test/mcp",
                "credential_mode" => "client_credentials"
              }
            ]
          },
          announce: false
        )

      assert "jira" in Enum.map(Fleet.get_profile("data-team").spec["mcpServers"], & &1["name"])
      assert {:ok, %{identity_problems: problems}} = Admin.profile_get(context.actor, "data-team")
      assert Enum.any?(problems, &(&1 =~ "jira")), inspect(problems)
    end
  end

  describe "extends" do
    test "a missing parent, a cycle and a chain too long are refused with a sentence", context do
      assert {:error, missing} =
               Admin.profile_put(context.actor, %{"name" => "orphan", "extends" => "nowhere"})

      assert missing.data.reason =~ "nowhere, which is not a profile on this plane"

      assert {:error, itself} =
               Admin.profile_put(context.actor, %{"name" => "standard", "image" => @image, "extends" => "standard"})

      assert itself.data.reason =~ "cannot extend itself"

      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())

      assert {:error, cycle} =
               Admin.profile_put(context.actor, Map.put(standard(), "extends", "data-team"))

      assert cycle.data.reason =~ "a profile cannot be its own ancestor"

      {:ok, _} = Admin.profile_put(context.actor, %{"name" => "three", "extends" => "data-team"})
      {:ok, _} = Admin.profile_put(context.actor, %{"name" => "four", "extends" => "three"})

      assert Extends.max_depth() == 4

      assert {:error, deep} =
               Admin.profile_put(context.actor, %{"name" => "five", "extends" => "four"})

      assert deep.data.reason =~ "a chain is at most 4"
      refute Fleet.get_profile("five")
    end

    test "a profile others extend is not deleted while they do", context do
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())

      assert {:error, error} = Admin.profile_delete(context.actor, "standard")
      assert error.message == "conflict"
      assert error.data.extended_by == ["data-team"]
      assert Fleet.get_profile("standard")

      # Extending nothing, it keeps what it had in effect, and the parent may go.
      {:ok, _} = Admin.profile_put(context.actor, Map.put(data_team(), "extends", nil))
      detached = Fleet.get_profile("data-team")
      assert detached.image == @image
      assert detached.spec["llm"]["endpoint"] == "https://llm.example.test/v1"
      assert {detached.extends, detached.own} == {nil, nil}
      assert {:ok, _} = Admin.profile_delete(context.actor, "standard")
    end
  end

  describe "a change to the parent" do
    test "is previewed in each child, then reaches it, audited once", context do
      FakeWorkerProfiles.start(%{"standard" => %{}, "data-team" => %{}})
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())
      flush()

      changed =
        standard()
        |> put_in(["spec", "egress", "fqdns"], ["docs.example.test", "news.example.test"])
        |> Map.put("max_sessions", 10)

      assert {:ok, preview} = Admin.preview(context.actor, changed)
      assert [%{name: "data-team", changes: changes, policy: %{allowed?: true}}] = preview.extended_by
      assert changes["max_sessions"] == %{"from" => 20, "to" => 10}

      assert changes["spec.egress.fqdns"]["to"] ==
               ["docs.example.test", "news.example.test", "warehouse.example.test"]

      # Nothing was written by looking.
      refute_received {FakeWorkerProfiles, :applied, _name, _resource, _query}
      assert Fleet.get_profile("data-team").max_sessions == 20

      assert {:ok, put} = Admin.profile_put(context.actor, changed)
      assert put.extended_by["data-team"].changes["max_sessions"] == %{"from" => 20, "to" => 10}

      assert_receive {FakeWorkerProfiles, :applied, "standard", _standard, _query}
      assert_receive {FakeWorkerProfiles, :applied, "data-team", resource, _query}

      assert resource["spec"]["egress"]["fqdns"] ==
               ["docs.example.test", "news.example.test", "warehouse.example.test"]

      assert Fleet.get_profile("data-team").max_sessions == 10
      # What data-team wrote is as it was: only what it has in effect moved.
      assert Fleet.get_profile("data-team").own["max_sessions"] == 50

      puts = Enum.filter(Audit.list(limit: 100), &(&1.action == "profile.put"))
      assert Enum.count(puts, &(&1.subject_id == "data-team")) == 1
      naming = Enum.filter(puts, &(&1.subject_id == "standard" and is_map(&1.detail["extended_by"])))
      assert [%{detail: %{"extended_by" => %{"data-team" => %{"max_sessions" => _}}}}] = naming
    end

    test "that would leave a child the plane refuses is refused, naming the child", context do
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())

      # data-team sets a model and has its endpoint from standard.
      without_endpoint = update_in(standard(), ["spec", "llm"], &Map.take(&1, []))

      assert {:error, error} = Admin.profile_put(context.actor, without_endpoint)
      assert error.data.extended_by == "data-team"
      assert error.data.reason =~ "data-team extends standard"
      assert error.data.reason =~ "llm.endpoint"
      assert Fleet.get_profile("standard").spec["llm"]["endpoint"]
    end

    test "the cluster policy judges the child as it would be in effect", context do
      Application.put_env(:troupe_plane, :policy, policy(["*.example.test"]))
      {:ok, _} = Admin.profile_put(context.actor, standard())

      outside = put_in(data_team(), ["spec", "egress", "fqdns"], ["files.example.com"])
      assert {:error, error} = Admin.profile_put(context.actor, outside)
      assert Enum.any?(error.data.policy_violations, &(&1 =~ "files.example.com"))
    end

    test "a bundle published to the parent's channel reaches the child that follows it", context do
      FakeWorkerProfiles.start(%{"standard" => %{}, "data-team" => %{}})
      {:ok, _} = Admin.profile_put(context.actor, Map.update!(standard(), "spec", &Map.delete(&1, "mcpServers")))
      {:ok, _} = Admin.profile_put(context.actor, Map.update!(data_team(), "spec", &Map.delete(&1, "mcpServers")))
      flush()

      {:ok, _} =
        Bundles.publish(
          "stable",
          %{"schema" => 1, "mcp_servers" => [%{"name" => "tickets", "url" => "https://tickets.example.test/mcp"}]},
          announce: false
        )

      assert_receive {FakeWorkerProfiles, :applied, "data-team", resource, _query}
      assert Enum.map(resource["spec"]["mcpServers"], & &1["name"]) == ["tickets"]
      # Its own write is untouched: the servers are the parent's.
      refute Map.has_key?(Fleet.get_profile("data-team").own["spec"], "mcpServers")
    end
  end

  describe "gitops mode" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      :ok
    end

    test "a put that extends is refused with what to do instead", context do
      assert {:error, error} = Admin.profile_put(context.actor, data_team())
      assert error.message == "managed_by_gitops"
      assert error.data.reason =~ "a repository's manifest holds the whole profile"
    end

    test "a manifest that names a parent is refused, not read as flat" do
      resource = %{
        "metadata" => %{
          "name" => "data-team",
          "generation" => 1,
          "annotations" => %{"troupe.dev/extends" => "standard"}
        },
        "spec" => %{"image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1"}}
      }

      assert {:error, [reason]} = GitopsProfiles.read(resource, nil)
      assert reason =~ "extends standard: in gitops mode a manifest holds the whole profile"
    end
  end

  defp flush do
    receive do
      {FakeWorkerProfiles, _, _, _, _} -> flush()
      {FakeWorkerProfiles, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp policy(egress) do
    %{
      "spec" => %{
        "allowedImageRepositories" => ["ghcr.io/troupe"],
        "allowedEgress" => egress,
        "maxReplicas" => 4,
        "maxSessionsPerPod" => 8,
        "namespacePrefix" => "troupe-w-"
      }
    }
  end
end
