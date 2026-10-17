defmodule Troupe.Plane.ChannelServersTest do
  @moduledoc """
  A profile created on a channel, or moved onto one, has that channel's MCP servers on its
  resource from that write (#722), not from the channel's next publish.

  The reach and identity checks read the channel's current bundle directly, so a resource
  without its servers disagreed with what `admin.profile.get` reported until somebody
  published again. The cluster is `FakeWorkerProfiles`, which hands each resource the
  plane applies back to the test as it was sent.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Bundles, FakeWorkerProfiles, Fleet, Identity}

  @moduletag timeout: 60_000

  @image "ghcr.io/troupe/worker:1"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    %{actor: Admin.actor_for(root)}
  end

  defp publish(channel, servers) do
    {:ok, _} =
      Bundles.publish(
        channel,
        %{
          "schema" => 1,
          "mcp_servers" =>
            for(
              name <- servers,
              do: %{"name" => name, "url" => "https://#{name}.example.test/mcp"}
            )
        },
        announce: false
      )
  end

  defp on_channel(name, channel, spec \\ %{}) do
    %{"name" => name, "image" => @image, "spec" => Map.put(spec, "configBundleChannel", channel)}
  end

  defp names(resource), do: Enum.map(resource["spec"]["mcpServers"] || [], & &1["name"])

  test "a profile created after its channel was published has the channel's servers at once",
       context do
    publish("stable", ["jira"])
    FakeWorkerProfiles.start(%{"late" => %{}})

    assert {:ok, put} = Admin.profile_put(context.actor, on_channel("late", "stable"))
    assert put.provisioning.state == :applied

    assert_receive {FakeWorkerProfiles, :applied, "late", resource, _query}
    assert names(resource) == ["jira"]
    assert names(%{"spec" => Fleet.get_profile("late").spec}) == ["jira"]
  end

  test "a profile moved onto a channel has that channel's servers, not the old one's", context do
    publish("stable", ["jira"])
    publish("beta", ["docs"])
    FakeWorkerProfiles.start(%{"moving" => %{}})

    {:ok, _} = Admin.profile_put(context.actor, on_channel("moving", "beta"))
    assert_receive {FakeWorkerProfiles, :applied, "moving", first, _query}
    assert names(first) == ["docs"]

    # The editor loads the servers the resource carries and sends them back with the move.
    moved = on_channel("moving", "stable", %{"mcpServers" => first["spec"]["mcpServers"]})
    {:ok, _} = Admin.profile_put(context.actor, moved)

    assert_receive {FakeWorkerProfiles, :applied, "moving", resource, _query}
    assert names(resource) == ["jira"]
  end

  test "a profile moved onto a channel with nothing published loses the old channel's servers",
       context do
    publish("stable", ["jira"])
    FakeWorkerProfiles.start(%{"moving" => %{}})

    {:ok, _} = Admin.profile_put(context.actor, on_channel("moving", "stable"))
    assert_receive {FakeWorkerProfiles, :applied, "moving", first, _query}

    moved = on_channel("moving", "quiet", %{"mcpServers" => first["spec"]["mcpServers"]})
    {:ok, _} = Admin.profile_put(context.actor, moved)

    assert_receive {FakeWorkerProfiles, :applied, "moving", resource, _query}
    assert names(resource) == []
  end

  test "a write that stays on its channel keeps the servers as they are", context do
    publish("stable", ["jira"])
    FakeWorkerProfiles.start(%{"staying" => %{}})

    {:ok, _} = Admin.profile_put(context.actor, on_channel("staying", "stable"))
    assert_receive {FakeWorkerProfiles, :applied, "staying", first, _query}

    again = on_channel("staying", "stable", %{"mcpServers" => first["spec"]["mcpServers"]})
    assert {:ok, %{changes: changes}} = Admin.profile_put(context.actor, again)
    refute Map.has_key?(changes, "spec.mcpServers")

    assert_receive {FakeWorkerProfiles, :applied, "staying", resource, _query}
    assert names(resource) == ["jira"]
  end

  test "a profile created on a channel with nothing published keeps the servers it was written with",
       context do
    FakeWorkerProfiles.start(%{"early" => %{}})
    written = [%{"name" => "wiki", "url" => "https://wiki.example.test/mcp"}]

    {:ok, _} =
      Admin.profile_put(
        context.actor,
        on_channel("early", "unpublished", %{"mcpServers" => written})
      )

    assert_receive {FakeWorkerProfiles, :applied, "early", resource, _query}
    assert names(resource) == ["wiki"]
  end

  test "a profile that extends another, created on a channel of its own, has its channel's servers and its parent's",
       context do
    publish("data", ["warehouse"])
    FakeWorkerProfiles.start(%{"standard" => %{}, "data-team" => %{}})
    wiki = [%{"name" => "wiki", "url" => "https://wiki.example.test/mcp"}]

    {:ok, _} =
      Admin.profile_put(
        context.actor,
        on_channel("standard", "unpublished", %{"mcpServers" => wiki})
      )

    child = %{
      "name" => "data-team",
      "extends" => "standard",
      "spec" => %{"configBundleChannel" => "data"}
    }

    {:ok, _} = Admin.profile_put(context.actor, child)

    assert_receive {FakeWorkerProfiles, :applied, "data-team", resource, _query}
    assert names(resource) == ["wiki", "warehouse"]
  end
end
