defmodule Troupe.Plane.PanelTest do
  @moduledoc """
  The admin panel, driven the way a browser drives it.

  Two kinds of test here. The first is that each page renders what its operator needs,
  and that killing a pod shows up on the workers page within a couple of seconds. The
  second is the set of refusals: a team admin who can see another team's sessions, or any
  admin who can read what a session said, is a breach — so the panel is checked for what
  it does *not* show as carefully as for what it does.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Admin, Bundles, Fleet, Identity, Sessions}

  @moduletag timeout: 60_000

  setup context do
    engineering = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 1_000_000)
    design = team_with_grant("design", "ux", name: "design")

    {:ok, platform_group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(platform_group, %{name: "platform"})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    nobody = person("nobody@example.test", [])

    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 2, sessions_per_pod: 4, image: "ghcr.io/troupe/worker:1"})
    {:ok, _} = Fleet.put_profile(%{name: "ux", replicas: 1, sessions_per_pod: 2})

    {:ok, pod} =
      Fleet.enrol(%{
        profile: "dev",
        namespace: "troupe-w-dev",
        pod_name: "troupe-w-dev-0",
        ordinal: 0,
        capacity: 4,
        disk_total_bytes: 1_000,
        version: "0.2.0"
      })

    Map.merge(context, %{
      engineering: engineering,
      design: design,
      root: root,
      lead: lead,
      nobody: nobody,
      pod: pod
    })
  end

  describe "getting in" do
    test "somebody who administers nothing is turned away", context do
      conn = sign_in(context.conn, context.nobody.subject)
      assert {:error, {:redirect, %{to: "/admin/denied"}}} = live(conn, "/admin")
    end

    test "no session at all is turned away", context do
      assert {:error, {:redirect, %{to: "/admin/denied"}}} = live(context.conn, "/admin")
    end

    test "a team admin gets in and is told what they are", context do
      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin")

      assert html =~ "lead@example.test"
      assert html =~ "team admin"
    end

    test "a platform admin gets in", context do
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")
      assert html =~ "platform admin"
    end

    test "the role is derived on mount, not carried in the cookie", context do
      conn = sign_in(context.conn, context.lead.subject)
      assert {:ok, _view, _html} = live(conn, "/admin")

      # The role is taken away while the browser is still holding the same cookie.
      :ok = Identity.remove_team_admin(context.engineering, context.lead.subject)

      assert {:error, {:redirect, %{to: "/admin/denied"}}} = live(conn, "/admin")
    end
  end

  describe "the workers page" do
    test "lists profiles, pods, conditions and load", context do
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/workers")

      assert html =~ "dev"
      assert html =~ "troupe-w-dev-0"
      assert html =~ "ready"
      assert html =~ "0.2.0"
      assert html =~ "no conditions reported"
    end

    test "a pod going unhealthy is reflected within two seconds", context do
      {:ok, view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/workers")
      assert html =~ "ready"

      # What the sweeper does to a pod that has stopped heartbeating.
      {:ok, _} = Fleet.heartbeat(context.pod, %{})
      :ok = mark_unhealthy(context.pod)

      assert eventually(fn -> render(view) =~ "unhealthy" end, 2_000),
             "the panel still showed the pod as ready two seconds after it went unhealthy"
    end

    test "a team admin sees only the profiles their team is granted", context do
      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/workers")

      # Against the profile links rather than the raw page. A page carries a base64
      # LiveView session token, and a two-letter substring turns up inside it often
      # enough to make a bare `refute html =~ "ux"` a coin toss.
      links = Regex.scan(~r|/admin/workers/([\w-]+)|, html) |> Enum.map(&List.last/1) |> Enum.uniq()

      assert "dev" in links
      refute "ux" in links
    end

    test "only a platform admin is offered the drain button", context do
      {:ok, _view, lead_html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/workers")
      refute lead_html =~ "drain"

      {:ok, _view, root_html} = context.conn |> sign_in(context.root.subject) |> live("/admin/workers")
      assert root_html =~ "drain"
    end
  end

  describe "the sessions page" do
    test "shows metadata and says so", context do
      session = session!(context.engineering, "dev")

      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      assert html =~ session.id
      assert html =~ "Metadata only"
      assert html =~ "No administrative role grants access to what a session said"
    end

    test "a team admin sees their team's and no others", context do
      mine = session!(context.engineering, "dev")
      theirs = session!(context.design, "ux")

      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/sessions")

      assert html =~ mine.id
      refute html =~ theirs.id
    end

    test "erasing takes two clicks", context do
      session = session!(context.engineering, "dev")
      {:ok, view, _html} = context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      # The first click asks rather than does: erasure is irreversible and a misclick
      # should not be enough.
      html = view |> element("button[phx-value-session='#{session.id}']") |> render_click()
      assert html =~ "irreversible"
      assert Sessions.get(session.id).state != "erased"
    end
  end

  describe "the teams page" do
    test "shows members and offers no way to change them", context do
      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/teams")

      assert html =~ "member" or html =~ "Members"
      assert html =~ "From the identity provider, and read-only here."
      refute html =~ "add member"
      refute html =~ "remove member"
    end

    test "a team admin can change their own team's budget", context do
      {:ok, view, _html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/teams")

      html =
        view
        |> element("button[phx-value-team='engineering']")
        |> render_click()

      assert html =~ "budget"

      view
      |> form("form[phx-submit='save']", %{
        "team" => "engineering",
        "budget_micros" => "4000000",
        "idle_timeout_seconds" => "1800",
        "erase_after_days" => "365"
      })
      |> render_submit()

      assert Identity.get_team("engineering").budget_micros == 4_000_000
    end

    test "a team admin is not offered grants", context do
      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/teams")
      refute html =~ ">grant<"

      {:ok, _view, root_html} = context.conn |> sign_in(context.root.subject) |> live("/admin/teams")
      assert root_html =~ ">grant<"
    end
  end

  describe "the audit page" do
    test "shows who changed what, with the diff", context do
      {:ok, _} = Admin.team_update(Admin.actor_for(context.lead), "engineering", %{budget_micros: 7})

      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/audit")

      assert html =~ "team.update"
      assert html =~ "lead@example.test"
      assert html =~ "budget_micros"
    end
  end

  describe "the bundles page" do
    test "publishing is a platform admin's and shows the hash", context do
      {:ok, view, _html} = context.conn |> sign_in(context.root.subject) |> live("/admin/bundles")

      html =
        view
        |> form("form[phx-submit='publish']", %{"content" => ~s({"agents": ["build"]})})
        |> render_submit()

      assert html =~ "sha256:"
      assert Bundles.current("stable").version == 1

      {:ok, _view, lead_html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/bundles")
      refute lead_html =~ "publish to"
    end
  end

  describe "the profile editor" do
    test "shows the diff before applying, and only a platform admin sees it", context do
      assert {:error, {:redirect, %{to: "/admin"}}} =
               context.conn |> sign_in(context.lead.subject) |> live("/admin/profile/dev")

      {:ok, view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")
      assert html =~ "What will be applied"

      html = view |> element("form") |> render_change(%{"name" => "dev", "replicas" => "5"})
      assert html =~ "replicas"
      assert html =~ "→"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp session!(team, profile) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_subject: "someone@example.test",
        team_id: team.id,
        profile: profile,
        state: "active",
        epoch: 1
      })

    session
  end

  # What `Fleet.sweep/0` does, without waiting fifteen seconds for the lease.
  defp mark_unhealthy(worker) do
    worker
    |> Ecto.Changeset.change(%{healthy: false})
    |> Repo.update()

    :ok
  end

  defp eventually(check, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(check, deadline)
  end

  defp do_eventually(check, deadline) do
    cond do
      check.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(50) && do_eventually(check, deadline)
    end
  end
end
