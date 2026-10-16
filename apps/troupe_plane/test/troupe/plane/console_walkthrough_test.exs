defmodule Troupe.Plane.ConsoleWalkthroughTest do
  @moduledoc """
  A whole working deployment, configured through the console's surface and nothing else.

  Done item 2 of `control-panel.md`, and the one that cannot be proven a method at a time:
  *a platform admin configures a complete working deployment from the console alone —
  identity, a team, a policy, a bundle, a profile, a provisioner, a trigger, a budget —
  with no `kubectl`, no environment variable and no database write, and every step is in
  the audit trail.*

  The console is an app of its own (`/console`) and calls the admin methods and nothing
  else, so the console alone is those methods: each step below is the call its screen
  makes, through `Troupe.Plane.Admin.API` as `/rpc` dispatches it. The console's own tests
  prove each screen makes its call; this proves the calls join up, which is the question
  an administrator actually has on their first evening.

  The plane starts empty. Nothing in this file writes through a context except to stand up
  the identity the provider would have supplied — which is exactly the one thing a console
  cannot do for itself, because a console with a way to create its own administrators is
  the escalation the whole arrangement refuses.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Bundles, Fleet, Identity, Sessions, Settings, Triggers}
  alias Troupe.Plane.Admin.API

  @moduletag timeout: 120_000

  setup do
    start_supervised!(Troupe.Plane.Singleton)
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    # What the identity provider supplies and the console cannot: a person, and the group
    # they arrive carrying. Everything after this is done through the console's methods.
    {:ok, platform} =
      Identity.upsert_group(%{external_id: "platform", display_name: "Platform engineering"})

    {:ok, _delivery} =
      Identity.upsert_group(%{external_id: "org-consultants", display_name: "Consultants"})

    root = person("root@example.test", ["platform"])
    _ada = person("ada@example.test", ["org-consultants"])

    # The first team is the platform's own: `actor_for/1` reads the admin group against the
    # provider's groups rather than against enabled teams, which is what lets a fresh plane
    # have an administrator before any team exists.
    {:ok, _} = Identity.enable_team(platform, %{name: "platform"})

    on_exit(fn ->
      Settings.reset("platform_admin_group", "test")
      Settings.reset("default_erase_after_days", "test")
    end)

    %{root: Admin.actor_for(root)}
  end

  test "an empty plane becomes a working one, from the console's methods alone", context do
    call = fn method, params ->
      assert {:ok, answer} = API.call(method, params, context.root), "#{method} was refused"
      answer
    end

    # -- 1. Identity: who administers this platform ---------------------------
    # The useful question, and the only one worth gating a save on: how many people would
    # administer this afterwards, and are you one of them.
    check = call.("admin.identity.check", %{"group" => "platform"})
    assert List.last(check.checks).detail =~ "including you."

    # -- 2. Policy: the group, and a ceiling every team will inherit ----------
    call.("admin.setting.put", %{"key" => "platform_admin_group", "value" => "platform"})
    call.("admin.setting.put", %{"key" => "default_erase_after_days", "value" => "30"})
    assert Settings.get("default_erase_after_days") == 30

    # -- 3. Teams: a provider group becomes a team ----------------------------
    call.("admin.team.enable", %{
      "group" => "org-consultants",
      "attrs" => %{"name" => "delivery", "budget_micros" => 500_000_000}
    })

    assert %{budget_micros: 500_000_000} = Identity.get_team("delivery")

    # The ladder reached it on the way in: a team enabled after the platform narrowed
    # retention starts at the platform's value rather than at the release's.
    assert Identity.get_team("delivery").erase_after_days == 30

    # -- 4. Profiles: a worker profile, from the choices the plane offers -----
    choices = call.("admin.profile.choices", %{})
    assert "standard" in Enum.map(choices.size_classes, & &1.name)

    profile = %{
      "name" => "dev",
      "image" => "ghcr.io/troupe/worker:1.4.0",
      "size_class" => "standard",
      "spec" => %{"configBundleChannel" => "stable"}
    }

    # Rule 2: nothing is applied until its diff has been read.
    preview = call.("admin.profile.preview", %{"profile" => profile})
    assert preview.changes["image"]["to"] == "ghcr.io/troupe/worker:1.4.0"

    call.("admin.profile.put", %{"profile" => profile})
    assert %Fleet.Profile{image: "ghcr.io/troupe/worker:1.4.0"} = Fleet.get_profile("dev")

    # -- 5. Provisioners: what makes its workers, and what that does not give --
    [kubernetes | _] = call.("admin.provisioners.list", %{})
    assert kubernetes.name == "kubernetes"

    # No operator has reconciled `dev` here, so nothing says its workers have egress by
    # hostname, and what stands in for it is named. It is still a profile a team may be
    # granted as it stands.
    [dev] = call.("admin.profiles.list", %{})
    assert "fqdn_egress" in dev.missing_guarantees
    assert dev.guarantees_instead["fqdn_egress"]
    refute dev.unenforced

    # -- 6. Bundles: what a session on that profile gets ----------------------
    document = %{
      "schema" => 1,
      "skills" => [],
      "mcp_servers" => [],
      "agents" => [
        %{
          "name" => "pr-reviewer",
          "definition" => "---\ndescription: Reviews\nmode: primary\n---\nYou review."
        }
      ]
    }

    # The first version has nothing to be measured against, and says so.
    assert call.("admin.bundle.preview", %{"channel" => "stable", "content" => document}).from ==
             nil

    call.("admin.bundle.publish", %{"channel" => "stable", "content" => document})
    assert %{version: 1} = Bundles.current("stable")

    # -- 7. Teams again: the grant that lets the team use it ------------------
    call.("admin.team.grant", %{"name" => "delivery", "profile" => "dev"})

    assert "dev" in Enum.map(
             Identity.grants_for_team(Identity.get_team("delivery")),
             & &1.profile
           )

    # -- 8. Identity again: a principal for work nobody starts by hand --------
    principal =
      call.("admin.principal.create", %{
        "team" => "delivery",
        "principal" => %{
          "name" => "nightly-deps",
          "profiles" => ["dev"],
          "sponsor" => "ada@example.test",
          "description" => "the nightly dependency update"
        }
      })

    # Shown once: in this answer and in no other.
    assert is_binary(principal.secret)

    # -- 9. Triggers: a way for it to start on its own ------------------------
    call.("admin.trigger.put", %{
      "trigger" => %{
        "team" => "delivery",
        "name" => "nightly",
        "principal" => "svc:delivery/nightly-deps",
        "profile" => "dev",
        "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5", "tz" => "UTC"},
        "prompt_template" => "Update every dependency."
      }
    })

    assert Triggers.get(Identity.get_team("delivery"), "nightly")

    # -- 10. Budgets: which ceiling would refuse, and for whom ----------------
    ceilings =
      call.("admin.budget.explain", %{"subject" => "ada@example.test", "team" => "delivery"})

    assert ceilings != []

    # -- 11. And a session can be created on what was configured --------------
    #
    # The proof that the steps above join up rather than each being separately plausible:
    # what a person's client asks for, answered from configuration that only ever came
    # through the console's methods.
    ada = Identity.get_user("ada@example.test")
    assert Identity.may_use?(ada, "dev")

    {:ok, session} =
      Sessions.create(%{
        id: "s-walkthrough",
        owner_subject: "ada@example.test",
        team_id: Identity.get_team("delivery").id,
        profile: "dev",
        state: "active",
        epoch: 1
      })

    assert session.profile == "dev"

    # -- 12. Audit: every step of it, with diffs keyed by path ----------------
    actions = Audit.list(limit: 100) |> Enum.map(& &1.action) |> MapSet.new()

    for action <- ~w(setting.put team.enable profile.put bundle.publish team.grant
                     principal.create trigger.put) do
      assert MapSet.member?(actions, action),
             "nothing recorded #{action}; the audit trail is not a record of this walkthrough"
    end

    # Keyed by the path that changed rather than by the object that contains it, which is
    # what makes an audit row readable a year later.
    setting =
      Audit.list(limit: 100)
      |> Enum.find(&(&1.action == "setting.put" and &1.subject_id == "default_erase_after_days"))

    assert %{"default_erase_after_days" => %{"from" => _, "to" => 30}} = setting.detail

    # And the trail says so itself: every row of it written through the console verifies.
    assert call.("admin.audit.verify", %{}).result == :ok
  end
end
