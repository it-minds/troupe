defmodule Troupe.Plane.ConsoleWalkthroughTest do
  @moduledoc """
  A whole working deployment, configured from the console and nothing else.

  Done item 2 of `control-panel.md`, and the one that cannot be proven a screen at a time:
  *a platform admin configures a complete working deployment from the console alone —
  identity, a team, a policy, a bundle, a profile, a provisioner, a trigger, a budget —
  with no `kubectl`, no environment variable and no database write, and every step is in
  the audit trail.*

  Every other test here asks whether one screen does its job. This asks whether the screens
  join up, which is a different question and the one an administrator actually has: each
  step below starts from what the previous step left on the page, and a step that needed a
  shell would fail here rather than being discovered by somebody on their first evening.

  The plane starts empty. Nothing in this file writes through a context except to stand up
  the identity the provider would have supplied — which is exactly the one thing a console
  cannot do for itself, because a console with a way to create its own administrators is
  the escalation the whole arrangement refuses.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Audit, Bundles, Fleet, Identity, Sessions}

  @moduletag timeout: 120_000

  setup do
    start_supervised!(Troupe.Plane.Singleton)

    # What the identity provider supplies and the console cannot: a person, and the group
    # they arrive carrying. Everything after this is done through a screen.
    {:ok, platform} =
      Identity.upsert_group(%{external_id: "platform", display_name: "Platform engineering"})

    {:ok, delivery} =
      Identity.upsert_group(%{external_id: "itm-consultants", display_name: "ITM consultants"})

    root = person("root@example.test", ["platform"])
    _ada = person("ada@example.test", ["itm-consultants"])

    # The first team is the platform's own: `actor_for/1` reads the admin group against the
    # provider's groups rather than against enabled teams, which is what lets a fresh plane
    # have an administrator before any team exists.
    {:ok, _} = Identity.enable_team(platform, %{name: "platform"})

    %{root: root, platform: platform, delivery: delivery}
  end

  test "an empty plane becomes a working one, from the console alone", context do
    conn = sign_in(context.conn, context.root.subject)

    # -- 1. Identity: who administers this platform ---------------------------
    {:ok, identity, _html} = live(conn, "/admin/identity")

    html = identity |> form("#identity-check", %{"group" => "platform"}) |> render_submit()

    # The useful question, and the only one worth gating a save on: how many people would
    # administer this afterwards, and are you one of them.
    assert html =~ "including you."

    # -- 2. Policy: the group, and a ceiling every team will inherit ----------
    {:ok, policy, _html} = live(conn, "/admin/policy")

    policy
    |> element(~s(form[phx-submit="save"]), "platform_admin_group")
    |> render_change(%{"key" => "platform_admin_group", "value" => "platform"})

    policy |> element(~s(button[phx-click="check"])) |> render_click()

    policy
    |> element(~s(form[phx-submit="save"]), "platform_admin_group")
    |> render_submit(%{"key" => "platform_admin_group", "value" => "platform"})

    policy
    |> element(~s(form[phx-submit="save"]), "default_erase_after_days")
    |> render_submit(%{"key" => "default_erase_after_days", "value" => "30"})

    assert Troupe.Plane.Settings.get("default_erase_after_days") == 30

    # -- 3. Teams: a provider group becomes a team ----------------------------
    {:ok, teams, _html} = live(conn, "/admin/teams")

    teams
    |> form("#enable-team", %{
      "group" => "itm-consultants",
      "name" => "delivery",
      "budget_micros" => "500000000"
    })
    |> render_submit()

    assert %{budget_micros: 500_000_000} = Identity.get_team("delivery")

    # The ladder reached it on the way in: a team enabled after the platform narrowed
    # retention starts at the platform's value rather than at the release's.
    assert Identity.get_team("delivery").erase_after_days == 30

    # -- 4. Profiles: a worker profile, written from a screen -----------------
    {:ok, editor, _html} = live(conn, "/admin/profile/new")

    fields = %{
      "name" => "dev",
      "image" => "ghcr.io/troupe/worker:1.4.0",
      "sizeClass" => "standard",
      "configBundleChannel" => "stable"
    }

    # Typed, then applied. `apply` reads the form's state from the socket rather than from
    # the submit — which is what lets the page show the diff and the policy verdict *before*
    # anybody presses it, and means a submit that never changed anything applies nothing.
    editor |> element("#profile-editor") |> render_change(fields)
    editor |> element("#profile-editor") |> render_submit(fields)

    assert %Fleet.Profile{} = profile = Fleet.get_profile("dev")
    assert profile.image == "ghcr.io/troupe/worker:1.4.0"

    # -- 5. Provisioners: what makes its workers, and what that does not give --
    {:ok, _provisioners, html} = live(conn, "/admin/provisioners")

    assert html =~ "dev"
    assert html =~ "kubernetes"
    assert html =~ "everything is enforced"

    # -- 6. Bundles: what a session on that profile gets ----------------------
    {:ok, bundles, _html} = live(conn, "/admin/bundles")

    document =
      Jason.encode!(%{
        "schema" => 1,
        "skills" => [],
        "mcp_servers" => [],
        "agents" => [
          %{
            "name" => "reviewer",
            "definition" => "---\ndescription: Reviews\nmode: primary\n---\nYou review."
          }
        ]
      })

    html =
      bundles
      |> element("#bundle-draft")
      |> render_submit(%{"content" => document, "action" => "check"})

    # Rule 2: nothing is applied until its diff has been read. The first version has
    # nothing to be measured against, and the page says so rather than showing an empty
    # diff and letting somebody take it for "no change".
    assert html =~ "this would be the first version"

    bundles
    |> element("#bundle-draft")
    |> render_submit(%{"content" => document, "action" => "publish"})

    assert %{version: 1} = Bundles.current("stable")

    # -- 7. Teams again: the grant that lets the team use it ------------------
    {:ok, teams, _html} = live(conn, "/admin/teams")

    teams
    |> form("#grant-delivery", %{"team" => "delivery", "profile" => "dev"})
    |> render_submit()

    assert "dev" in Enum.map(Identity.grants_for_team(Identity.get_team("delivery")), & &1.profile)

    # -- 8. Identity again: a principal for work nobody starts by hand --------
    {:ok, identity, _html} = live(conn, "/admin/identity")

    html =
      identity
      |> form("#new-principal-delivery", %{
        "team" => "delivery",
        "name" => "nightly-deps",
        "profiles" => "dev",
        "sponsor" => "ada@example.test",
        "description" => "the nightly dependency update"
      })
      |> render_submit()

    assert html =~ "shown once"

    # -- 9. Triggers: a way for it to start on its own ------------------------
    {:ok, triggers, _html} = live(conn, "/admin/triggers/delivery")

    triggers
    |> form("#new-trigger", %{
      "name" => "nightly",
      "principal" => "svc:delivery/nightly-deps",
      "profile" => "dev",
      "cron" => "0 3 * * 1-5",
      "prompt_template" => "Update every dependency."
    })
    |> render_submit()

    assert Troupe.Plane.Triggers.get(Identity.get_team("delivery"), "nightly")

    # -- 10. Budgets: which ceiling would refuse, and for whom ----------------
    {:ok, budgets, _html} = live(conn, "/admin/budgets")

    html =
      budgets
      |> element("#explain-budget")
      |> render_submit(%{"team" => "delivery", "subject" => "ada@example.test"})

    assert html =~ "is what refuses first"
    assert html =~ "the team&#39;s ceiling" or html =~ "the team's ceiling"

    # -- 11. And a session can be created on what was configured --------------
    #
    # The proof that the eleven steps above join up rather than each being separately
    # plausible: what a person's client asks for, answered from configuration that only
    # ever came from a screen.
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
    {:ok, audit, _html} = live(conn, "/admin/audit")

    actions = Audit.list(limit: 100) |> Enum.map(& &1.action) |> MapSet.new()

    for action <- ~w(setting.put team.enable profile.put bundle.publish team.grant
                     principal.create trigger.put) do
      assert MapSet.member?(actions, action),
             "nothing recorded #{action}; the audit trail is not a record of this walkthrough"
    end

    # Keyed by the path that changed rather than by the object that contains it, which is
    # what makes an audit row readable a year later.
    setting = Audit.list(limit: 100) |> Enum.find(&(&1.action == "setting.put"))
    assert %{"default_erase_after_days" => %{"from" => _, "to" => 30}} = setting.detail

    # And the trail says so itself: every row of it written through the console verifies.
    html = audit |> element("#audit-verify") |> render_submit()
    assert html =~ "The chain verifies"
  end
end
