defmodule Troupe.Plane.SensitiveProfileTest do
  @moduledoc """
  A worker profile's `spec.sensitive` (#1239): which calls make a session on its pods
  sensitive, which a sensitive one is refused, and what a person may do with one beyond its
  readers. Checked where it is written, and composed along `extends`: a child adds rules
  and may only tighten `sharing`.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Fleet, Identity}

  @image "ghcr.io/troupe/worker:1"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    %{actor: Admin.actor_for(root)}
  end

  defp put(actor, name, sensitive, extra \\ %{}) do
    Admin.profile_put(
      actor,
      Map.merge(%{"name" => name, "image" => @image, "spec" => %{"sensitive" => sensitive}}, extra)
    )
  end

  defp reason({:error, error}) do
    assert error.message == "invalid_params"
    error.data.reason
  end

  test "is kept as written when its rules read and it names what is refused", context do
    sensitive = %{
      "markedBy" => ["mcp(records.*)", "read_file(/mnt/records/**)", "shell(psql)"],
      "deny" => ["publish_artifact", "web_fetch", "remember", "mcp(slack.*)"],
      "sharing" => "ask"
    }

    assert {:ok, _} = put(context.actor, "records", sensitive)
    assert Fleet.get_profile("records").spec["sensitive"] == sensitive
  end

  test "markedBy without deny is refused with what to add", context do
    why = reason(put(context.actor, "records", %{"markedBy" => ["mcp(records.*)"]}))
    assert why =~ "sensitive.markedBy is set and sensitive.deny is not"
    assert why =~ "say which tools a sensitive session is refused in sensitive.deny"

    why = reason(put(context.actor, "records", %{"markedBy" => ["mcp(records.*)"], "deny" => []}))
    assert why =~ "sensitive.deny is not"
    assert Fleet.get_profile("records") == nil
  end

  test "a rule the pods could not read, a sharing they do not know and a key nobody reads are refused",
       context do
    assert reason(put(context.actor, "r", %{"markedBy" => ["mcp.records.x"], "deny" => ["web_fetch"]})) =~
             "sensitive.markedBy:"

    assert reason(put(context.actor, "r", %{"markedBy" => ["mcp(r.*)"], "deny" => ["web_fetch(x)"]})) =~
             "sensitive.deny:"

    assert reason(put(context.actor, "r", %{"deny" => ["web_fetch"], "sharing" => "Ask"})) =~
             "sensitive.sharing must be allow, ask or deny, not"

    assert reason(put(context.actor, "r", %{"deny" => ["web_fetch"], "clears" => true})) =~
             "sensitive takes markedBy, deny and sharing, not clears"

    assert reason(put(context.actor, "r", %{"deny" => "web_fetch"})) =~
             "sensitive.deny is a list of rules"

    too_many = for n <- 1..201, do: "mcp(s#{n}.*)"

    assert reason(put(context.actor, "r", %{"markedBy" => too_many, "deny" => ["web_fetch"]})) =~
             "sensitive.markedBy holds at most 200 rules, not 201"
  end

  describe "along extends" do
    setup context do
      parent = %{"markedBy" => ["mcp(records.*)"], "deny" => ["publish_artifact"], "sharing" => "ask"}
      assert {:ok, _} = put(context.actor, "records", parent)
      :ok
    end

    test "a child adds rules to both lists and keeps every one of its parent's", context do
      child = %{"markedBy" => ["shell(psql)"], "deny" => ["web_fetch"]}

      assert {:ok, _} =
               Admin.profile_put(context.actor, %{
                 "name" => "records-plus",
                 "extends" => "records",
                 "spec" => %{"sensitive" => child}
               })

      spec = Fleet.get_profile("records-plus").spec["sensitive"]
      assert spec["markedBy"] == ["mcp(records.*)", "shell(psql)"]
      assert spec["deny"] == ["publish_artifact", "web_fetch"]
      assert spec["sharing"] == "ask"
    end

    test "a child that only marks has its parent's deny, so it is not refused", context do
      assert {:ok, _} =
               Admin.profile_put(context.actor, %{
                 "name" => "records-plus",
                 "extends" => "records",
                 "spec" => %{"sensitive" => %{"markedBy" => ["shell(psql)"]}}
               })

      assert Fleet.get_profile("records-plus").spec["sensitive"]["deny"] == ["publish_artifact"]
    end

    test "a child may tighten sharing and cannot loosen it", context do
      assert {:ok, _} =
               Admin.profile_put(context.actor, %{
                 "name" => "strict",
                 "extends" => "records",
                 "spec" => %{"sensitive" => %{"sharing" => "deny"}}
               })

      assert Fleet.get_profile("strict").spec["sensitive"]["sharing"] == "deny"

      assert {:ok, _} =
               Admin.profile_put(context.actor, %{
                 "name" => "loose",
                 "extends" => "records",
                 "spec" => %{"sensitive" => %{"sharing" => "allow"}}
               })

      assert Fleet.get_profile("loose").spec["sensitive"]["sharing"] == "ask"
      assert {:ok, effective} = Fleet.Extends.resolve("loose")

      assert "loose sets sensitive.sharing to allow, and records's ask holds: a profile can only tighten it" in
               effective.problems

      assert Fleet.get_profile("loose").own["spec"]["sensitive"]["sharing"] == "allow"
    end
  end
end
