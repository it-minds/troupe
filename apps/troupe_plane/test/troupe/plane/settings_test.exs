defmodule Troupe.Plane.SettingsTest do
  @moduledoc """
  What an operator may change without a deploy, and what the deployment keeps.

  The property worth protecting is the ordering: a stored value overrides the deployment
  and never replaces it, so resetting always has somewhere to fall back to. Everything
  else here follows from that — including the reason `reset` deletes a row rather than
  writing the current default into it.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Identity, Provision, Settings}
  alias Troupe.Plane.Identity.Team

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :provisioning_mode, :direct)

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :provisioning_mode)
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})

    engineering = team_with_grant("engineering", "dev", name: "engineering")
    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    %{root: Admin.actor_for(root), lead: Admin.actor_for(lead)}
  end

  describe "where a value comes from" do
    test "the deployment, when nobody has changed it" do
      assert Settings.get("provisioning_mode") == :direct

      setting = Enum.find(Settings.all(), &(&1.key == "provisioning_mode"))
      assert setting.source == :deployed
    end

    test "the stored value, once somebody has" do
      assert {:ok, _} = Settings.put("provisioning_mode", "gitops", "root@example.test")

      assert Settings.get("provisioning_mode") == :gitops

      setting = Enum.find(Settings.all(), &(&1.key == "provisioning_mode"))
      assert setting.source == :stored
    end

    test "resetting goes back to the deployment, not to this release's default" do
      assert {:ok, _} = Settings.put("provisioning_mode", "gitops", "root@example.test")
      assert {:ok, _} = Settings.reset("provisioning_mode", "root@example.test")

      # The deployment said `:direct`; the fallback in the code says `:direct` too, so the
      # distinction is proved by changing the deployment and resetting again.
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      assert Settings.get("provisioning_mode") == :gitops
    end

    test "a stored value that no longer parses falls back rather than crashing" do
      assert {:ok, _} = Settings.put("default_budget_micros", "500", "root@example.test")

      # As if the setting's type had changed under a value written by an older release.
      Repo.update_all(Troupe.Plane.Settings.Stored, set: [value: "half a krone"])
      Settings.invalidate()

      assert Settings.get("default_budget_micros") == 0
    end
  end

  describe "what will not be changed from here" do
    test "a value the deployment owns is refused" do
      assert {:error, :not_editable} = Settings.put("audience", "somebody-else", "root")
    end

    test "a value that does not fit its type is refused" do
      assert {:error, {:invalid, message}} = Settings.put("default_budget_micros", "lots", "root")
      assert message =~ "whole number"

      assert {:error, {:invalid, _}} = Settings.put("provisioning_mode", "sideways", "root")
    end

    test "every declared choice is accepted" do
      # `daily`, a choice here once, appeared nowhere else in the codebase, so converting
      # the string to an atom raised rather than accepting a value the setting itself
      # declared. Matched against the declared atoms now, never converted.
      for %{type: :enum, key: key, values: values} <- Settings.definitions(), value <- values do
        assert {:ok, %{value: ^value}} = Settings.put(key, to_string(value), "root")
        assert Settings.get(key) == value
      end
    end

    test "a budget period a team would refuse is refused here" do
      assert {:error, {:invalid, message}} =
               Settings.put("default_budget_period", "daily", "root")

      assert message =~ "monthly, never"
    end

    test "a setting nobody declared is refused" do
      assert {:error, :unknown_setting} = Settings.put("turn_off_the_audit", "yes", "root")
    end

    test "a secret is reported as set, never returned" do
      Application.put_env(:troupe_plane, :scim_token, "a-real-token")
      on_exit(fn -> Application.delete_env(:troupe_plane, :scim_token) end)

      setting = Enum.find(Settings.all(), &(&1.key == "scim_token"))

      assert setting.set
      refute Map.has_key?(setting, :value)
      refute setting.deployed == "a-real-token"
    end
  end

  describe "the settings actually decide something" do
    test "provisioning mode is read through settings, not the environment" do
      assert Provision.mode() == :direct
      assert {:ok, _} = Settings.put("provisioning_mode", "gitops", "root@example.test")
      assert Provision.mode() == :gitops
    end

    test "the platform admin group can be changed from inside the console", context do
      # The repair this exists for: the group was wrong, and the only administrator is a
      # break-glass session with no way to fix it short of a rollout.
      assert {:ok, _} =
               Admin.setting_put(context.root, "platform_admin_group", "some-other-group")

      assert Settings.get("platform_admin_group") == "some-other-group"

      # And it takes effect at once, on the actor's next request rather than their next
      # login: the same person is no longer an administrator.
      assert Admin.actor_for(Identity.get_user("root@example.test")).role != :platform_admin
    end

    test "a new team starts with what the platform says, not what the schema says", context do
      assert {:ok, _} = Admin.setting_put(context.root, "default_budget_micros", "750000")
      assert {:ok, _} = Admin.setting_put(context.root, "default_erase_after_days", "30")

      {:ok, group} = Identity.upsert_group(%{external_id: "newcomers", display_name: "newcomers"})
      assert {:ok, team} = Admin.team_enable(context.root, "newcomers", %{})

      assert team.budget_micros == 750_000
      assert team.erase_after_days == 30
      assert Identity.get_team(team.name).group_id == group.id
    end

    test "every period a new team can be given is one a team accepts", context do
      # `daily` was offered here and refused by the team, so once somebody chose it every
      # team enabled afterwards failed.
      periods = Settings.definition("default_budget_period").values
      assert Enum.map(periods, &to_string/1) == Team.budget_periods()

      for period <- periods do
        name = "period-#{period}"
        {:ok, _} = Identity.upsert_group(%{external_id: name, display_name: name})

        assert {:ok, _} =
                 Admin.setting_put(context.root, "default_budget_period", to_string(period))

        assert {:ok, team} = Admin.team_enable(context.root, name, %{})
        assert team.budget_period == to_string(period)
      end
    end

    test "enabling a team with attributes from the wire does not raise", context do
      {:ok, _} = Identity.upsert_group(%{external_id: "wire", display_name: "wire"})

      # String keys, as JSON delivers them. This used to be mixed with an atom key and
      # Ecto refuses to cast a map with both, so the panel worked and the CLI did not.
      assert {:ok, team} =
               Admin.team_enable(context.root, "wire", %{"budget_micros" => 42, "name" => "wire"})

      assert team.budget_micros == 42
    end
  end

  describe "who may" do
    test "a team admin reads the settings", context do
      assert {:ok, %{settings: settings, groups: groups}} = Admin.settings_list(context.lead)
      assert Enum.any?(settings, &(&1.key == "platform_admin_group"))
      assert Enum.any?(groups, &(&1.key == :deployment))
    end

    test "a team admin does not change them", context do
      assert {:error, error} = Admin.setting_put(context.lead, "provisioning_mode", "gitops")
      assert error.data.required_role == "platform_admin"
    end

    test "a change is in the audit trail with who made it", context do
      assert {:ok, _} = Admin.setting_put(context.root, "groups_claim", "roles")

      assert {:ok, [entry | _]} = Admin.audit_list(context.root, kind: "setting")
      assert entry.actor == "root@example.test"
      assert entry.subject_id == "groups_claim"
      assert entry.detail["groups_claim"]["to"] == "roles"
    end
  end
end
