defmodule Troupe.Plane.EffectiveBundleTest do
  @moduledoc """
  A profile that extends another has one bundle in effect (#655 slice 2): its parent's,
  with its own channel's added, composed by the plane into one document with one hash, so
  the worker still loads one bundle.

  `standard` follows `standard-channel` and `data-team` extends it on `data`, as the issue
  tells it. The pods are `FakePod`s, which hand each push to the test as it crossed the
  wire; the cluster is `FakeWorkerProfiles`, which hands back each resource the plane wrote.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Bundles, FakePod, FakeWorkerProfiles, Fleet, Identity}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Protocol.Bundle, as: Document

  @moduletag timeout: 60_000

  @image "ghcr.io/troupe/worker:1"

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    %{actor: Admin.actor_for(root), port: Listener.port()}
  end

  defp standard do
    %{
      "name" => "standard",
      "image" => @image,
      "spec" => %{"configBundleChannel" => "standard-channel"}
    }
  end

  defp data_team do
    %{
      "name" => "data-team",
      "extends" => "standard",
      "spec" => %{"configBundleChannel" => "data"}
    }
  end

  defp standard_bundle do
    %{
      "schema" => 1,
      "agents" => [agent("lead-reviewer", "You review.")],
      "skills" => [skill("checklist")],
      "mcp_servers" => [%{"name" => "wiki", "url" => "https://wiki.example.test/mcp"}]
    }
  end

  defp data_bundle(extra \\ []) do
    %{
      "schema" => 1,
      "agents" => [agent("analyst", "You analyse.")],
      "skills" => [skill("sql")],
      "mcp_servers" =>
        [%{"name" => "warehouse", "url" => "https://warehouse.example.test/mcp"}] ++ extra
    }
  end

  defp agent(name, body),
    do: %{"name" => name, "definition" => "---\nmode: primary\n---\n#{body}"}

  defp skill(name),
    do: %{"name" => name, "files" => %{"SKILL.md" => "---\nname: #{name}\n---\nHow."}}

  defp names(content, kind), do: Enum.map(content[kind] || [], & &1["name"])

  describe "the bundle in effect" do
    test "is the parent's with the child's added, one document with one hash", context do
      FakeWorkerProfiles.start(%{"standard" => %{}, "data-team" => %{}})

      {:ok, _} = Bundles.publish("standard-channel", standard_bundle(), announce: false)
      {:ok, _} = Bundles.publish("data", data_bundle(), announce: false)

      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())

      row = Fleet.get_profile("data-team")
      effective = Bundles.current(row.config_bundle_channel)
      assert effective, "data-team has no bundle in effect"

      # One document: what its pods fetch and check, by the hash a push names.
      assert effective.hash == Document.hash(effective.content)
      assert {:ok, _parsed} = Document.validate(effective.content)

      assert names(effective.content, "agents") == ["lead-reviewer", "analyst"]
      assert names(effective.content, "skills") == ["checklist", "sql"]
      assert names(effective.content, "mcp_servers") == ["wiki", "warehouse"]

      # The parent's pods still follow the parent's channel, as they did.
      assert Fleet.get_profile("standard").config_bundle_channel == "standard-channel"

      # The resource and the bundle say the same servers, so the reach and identity
      # checks read the same thing the pods are handed.
      assert Enum.map(row.spec["mcpServers"], & &1["name"]) == ["wiki", "warehouse"]

      assert Enum.map(Bundles.mcp_servers(row.config_bundle_channel), & &1["name"]) ==
               ["wiki", "warehouse"]

      # Each entry says where it came from.
      assert {:ok, got} = Admin.profile_get(context.actor, "data-team", true)
      from = Map.new(got.effective.bundle.entries, &{{&1.kind, &1.name}, &1.from})

      assert from[{"agents", "lead-reviewer"}] == "standard"
      assert from[{"agents", "analyst"}] == "data-team"
      assert from[{"mcp_servers", "wiki"}] == "standard"
      assert from[{"mcp_servers", "warehouse"}] == "data-team"
      assert got.effective.bundle.hash == effective.hash
    end

    test "a child's entry with a parent's name replaces it only with override: true, and the flag lives in the document",
         context do
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())
      {:ok, _} = Bundles.publish("standard-channel", standard_bundle(), announce: false)

      clash = %{"name" => "wiki", "url" => "https://other-wiki.example.test/mcp"}
      {:ok, _} = Bundles.publish("data", data_bundle([clash]), announce: false)

      kept = effective_servers("data-team")
      assert kept["wiki"]["url"] == "https://wiki.example.test/mcp"

      assert {:ok, got} = Admin.profile_get(context.actor, "data-team", true)

      assert Enum.any?(
               got.effective.bundle.problems,
               &(&1 =~ "say override: true on it in data's bundle to replace it")
             )

      overriding = Map.put(clash, "override", true)
      {:ok, _} = Bundles.publish("data", data_bundle([overriding]), announce: false)

      assert effective_servers("data-team")["wiki"]["url"] ==
               "https://other-wiki.example.test/mcp"

      # The channel's next publish carries the flag with the entry, so the child's server
      # still stands: nothing outside the document had to remember it.
      next = put_in(data_bundle([overriding]), ["skills"], [skill("sql"), skill("dbt")])
      {:ok, _} = Bundles.publish("data", next, announce: false)

      assert effective_servers("data-team")["wiki"]["url"] ==
               "https://other-wiki.example.test/mcp"

      # The resource agrees, and carries no flag it has no field for.
      [wiki] =
        Enum.filter(Fleet.get_profile("data-team").spec["mcpServers"], &(&1["name"] == "wiki"))

      assert wiki["url"] == "https://other-wiki.example.test/mcp"
      refute Map.has_key?(wiki, "override")
    end

    test "an override that is not true or false is refused at publish" do
      bad =
        data_bundle([
          %{"name" => "wiki", "url" => "https://w.example.test/mcp", "override" => "yes"}
        ])

      assert {:error, {:invalid_bundle, errors}} = Bundles.publish("data", bad, announce: false)
      assert Enum.any?(errors, &(&1 =~ "override is true or false"))
    end

    test "a child on its parent's channel has the parent's bundle as it is", context do
      {:ok, _} = Admin.profile_put(context.actor, standard())

      {:ok, _} =
        Admin.profile_put(context.actor, %{"name" => "data-team", "extends" => "standard"})

      {:ok, published} = Bundles.publish("standard-channel", standard_bundle(), announce: false)

      assert Fleet.get_profile("data-team").config_bundle_channel == "standard-channel"
      assert Bundles.current("standard-channel").hash == published.hash
    end
  end

  describe "a publish anywhere in the chain" do
    test "reaches the child's pods with its new bundle in effect", context do
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())
      {:ok, _} = Bundles.publish("data", data_bundle(), announce: false)

      standard_pod = FakePod.enrol(context.port, "standard-token", "troupe-w-standard-0")
      data_pod = FakePod.enrol(context.port, "data-team-token", "troupe-w-data-team-0")
      assert standard_pod.worker_id && data_pod.worker_id

      # The parent's channel: its own pods get its bundle, and the child's get theirs, which
      # now has the parent's in it.
      {:ok, parent} = Bundles.publish("standard-channel", standard_bundle())

      pushes = collect_pushes(2)
      hashes = Enum.map(pushes, & &1["bundle_hash"])
      assert parent.hash in hashes

      child = Bundles.current(Fleet.get_profile("data-team").config_bundle_channel)
      assert child.hash in hashes
      assert names(child.content, "agents") == ["lead-reviewer", "analyst"]

      # The child's own channel: only its pods hear of it.
      {:ok, _} =
        Bundles.publish("data", put_in(data_bundle(), ["skills"], [skill("sql"), skill("dbt")]))

      assert [%{"bundle_hash" => hash}] = collect_pushes(1)
      newer = Bundles.current(Fleet.get_profile("data-team").config_bundle_channel)
      assert hash == newer.hash
      assert names(newer.content, "skills") == ["checklist", "sql", "dbt"]
      refute_receive {:pushed, "config.updated", _}, 300
    end

    test "a publish that changes nothing in effect pushes nothing to the child", context do
      {:ok, _} = Admin.profile_put(context.actor, standard())
      {:ok, _} = Admin.profile_put(context.actor, data_team())
      {:ok, _} = Bundles.publish("standard-channel", standard_bundle(), announce: false)
      {:ok, _} = Bundles.publish("data", data_bundle(), announce: false)
      channel = Fleet.get_profile("data-team").config_bundle_channel
      before = Bundles.current(channel)

      # Republishing the same document makes a new version of the channel and the same
      # bundle in effect: no new version of it, and nothing for the pods to do.
      {:ok, _} = Bundles.publish("data", data_bundle(), announce: false)
      assert Bundles.current(channel).version == before.version
    end
  end

  defp effective_servers(name) do
    Fleet.get_profile(name).config_bundle_channel
    |> Bundles.current()
    |> Map.fetch!(:content)
    |> Map.get("mcp_servers", [])
    |> Map.new(&{&1["name"], &1})
  end

  defp collect_pushes(count) do
    for _ <- 1..count do
      assert_receive {:pushed, "config.updated", params}, 5_000
      params
    end
  end
end
