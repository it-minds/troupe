defmodule Troupe.Plane.PanelTest do
  @moduledoc """
  The page at `/admin`, driven the way a browser drives it.

  Everything an administrator does is the console's, at `/console`, and its tests are the
  console's own. What is left here is the read-only page, who it lets in, what a
  break-glass session can put back on it, and where each page that used to be here went.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Admin, Audit, Fleet, Identity, Ledger, Settings}

  @moduletag timeout: 60_000

  describe "signing in" do
    test "the authorize request asks for an id_token and nothing that is not a scope",
         %{conn: conn} do
      # `groups` was in this list, and it is not a scope — not in OIDC and not at any
      # provider. Entra validated it *after* authentication and redirected back with
      # `invalid_scope`, which the callback then reported as "you do not administer
      # anything here". The console asks for an identity and reads groups out of the
      # token it gets; it does not ask for them.
      previous = Application.get_env(:troupe_plane, :oidc)

      Application.put_env(:troupe_plane, :oidc,
        issuer: "https://login.example.test/v2.0",
        client_id: "troupe",
        authorization_endpoint: "https://login.example.test/authorize"
      )

      on_exit(fn -> Application.put_env(:troupe_plane, :oidc, previous) end)

      location =
        conn
        |> Phoenix.ConnTest.get("/admin/login")
        |> Plug.Conn.get_resp_header("location")
        |> List.first()

      scope =
        location
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("scope")
        |> String.split(" ", trim: true)

      assert "openid" in scope, "without `openid` the provider issues no id_token to verify"
      refute "groups" in scope, "`groups` is not a scope; group claims come from the token"

      # Every scope here has to be one a provider actually defines. The console needs an
      # identity and nothing else, so the list is short on purpose.
      assert Enum.all?(scope, &(&1 in ~w(openid profile email offline_access))),
             "unexpected scope(s): #{inspect(scope -- ~w(openid profile email offline_access))}"
    end
  end

  setup context do
    engineering =
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 1_000_000)

    design = team_with_grant("design", "ux", name: "design")

    {:ok, platform_group} =
      Identity.upsert_group(%{external_id: "platform", display_name: "platform"})

    {:ok, _} = Identity.enable_team(platform_group, %{name: "platform"})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    nobody = person("nobody@example.test", [])

    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    {:ok, _} =
      Fleet.put_profile(%{
        name: "dev",
        replicas: 2,
        sessions_per_pod: 4,
        image: "ghcr.io/troupe/worker:1"
      })

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

  describe "the overview" do
    test "an attention item's status has room for its word", context do
      # The status is a glyph and a word, and it had the glyph column's 16px: the word ran
      # over the sentence beside it, seen in a browser at 1280px. A LiveView test lays
      # nothing out, so the markup is checked here and the room in the stylesheet.
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")

      # The setup's `dev` asked for two pods and has one.
      assert html =~ ~r{<li class="attention__item[^"]*"><span class="status status--degraded"}

      css = File.read!(Application.app_dir(:troupe_plane, "priv/static/console.css"))
      [item] = Regex.run(~r/\.attention__item\s*\{([^}]*)\}/, css, capture: :all_but_first)

      refute item =~ "--size-glyph-column", "the status is squeezed into the glyph column"
      assert css =~ ~r/\.attention__item > \.status\s*\{[^}]*flex:\s*0 0 170px/
    end

    # The page points at the console, which is where everything is done, and says it only
    # reads: it is the way in on the day the console cannot be used.
    test "points at the console, and says it only reads", context do
      {:ok, view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin")

      assert html =~ ~s(<a href="/console">/console</a>)
      assert html =~ "This page only reads"
      assert has_element?(view, ~s(nav a[href="/console"]), "Console")

      # A profile is linked to its page in the console, and nothing links to a page here
      # that is not.
      assert html =~ ~s(href="/console#/profiles/dev")
      refute html =~ ~r{href="/admin/(?!logout|static/)}
    end

    test "names no console on a plane without one", context do
      Application.put_env(:troupe_plane, :console_url, "")
      on_exit(fn -> Application.delete_env(:troupe_plane, :console_url) end)

      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")

      refute html =~ "new-console"
      refute html =~ ~s(href="/console)
      assert html =~ "deployed without the console"
    end
  end

  describe "the page's spend" do
    test "a spend never says unlimited", context do
      # `amount/1` rendered through `money/1`, which reads a zero as *no ceiling*. Every
      # caller of it is a spend or a reservation and none is a ceiling, so a team that had
      # spent nothing was reported as having spent "unlimited".
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")

      spends =
        Regex.scan(
          ~r{<span class="mono" style="font-variant-numeric: tabular-nums">\s*(?:<span class="muted">\$</span>)?([^<]*)},
          html
        )
        |> Enum.map(&(&1 |> List.last() |> String.trim()))

      refute spends == [], "the page rendered no amount at all, so this proves nothing"

      # Nor does the metric that adds them up: "Spent unlimited" read off a plane where
      # nothing had been spent.
      assert html =~ ~r{<span class="metric__label">Spent</span><span class="metric__value"[^>]*>0\.00</span>}
      refute "unlimited" in spends, "a spend is rendered as a ceiling: #{inspect(Enum.uniq(spends))}"
    end

    test "a bar's fill is a box, so the width it is given is the width it draws", context do
      # The fill is a `<span>` with its width in a style attribute, and a span is inline
      # unless the stylesheet says otherwise: an inline box takes no width and no height.
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")

      assert html =~ ~r{<span class="budget__fill" style="width: \d+%"}

      css = File.read!(Application.app_dir(:troupe_plane, "priv/static/console.css"))
      [rule] = Regex.run(~r/\.budget__fill\s*\{([^}]*)\}/, css, capture: :all_but_first)

      assert rule =~ ~r/display:\s*(block|inline-block|flex)\b/,
             ".budget__fill is inline, so its width and height do not apply: #{rule}"
    end

    test "an amount is in the unit the rest of the product counts in", context do
      # A budget is millionths of a dollar: the gateways report cost in dollars, and the
      # desktop client and the daemon's budget question both say `$1.20`.
      {:ok, _} =
        Ledger.record(%{
          session_id: "spent-some",
          team_id: context.engineering.id,
          owner_subject: context.lead.subject,
          model: "fake-model",
          cost_micros: 250_000,
          gateway_request_id: "spent-some-1"
        })

      Ledger.Cache.invalidate(context.engineering.id)
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")

      refute html =~ ~r/\bkr\b/
      assert html =~ ~r{<span class="muted">\$</span>0\.25}
    end

    test "a ceiling that never turns over is a total, and promises no new period", context do
      {:ok, _} =
        Admin.team_update(Admin.actor_for(context.lead), "engineering", %{budget_period: "never"})

      {:ok, _} =
        Ledger.record(%{
          session_id: "spent-it-all",
          team_id: context.engineering.id,
          owner_subject: context.lead.subject,
          model: "fake-model",
          cost_micros: 1_000_000,
          gateway_request_id: "spent-it-all-1"
        })

      Ledger.Cache.invalidate(context.engineering.id)
      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin")

      figures =
        Regex.scan(~r{<span class="budget__figures">(.*?)</span>}s, html)
        |> Enum.map(&(&1 |> List.last() |> String.trim()))

      assert "1.00 / 1.00 in total" in figures
      assert html =~ "engineering is at its ceiling, which never turns over."
      refute html =~ "the period turns over"
    end

    test "a monthly ceiling says when it turns over, and is not reported once it has",
         context do
      # The sentence promised a new period long before anything delivered one (#106). It is
      # true now, so it says when: the 1st, in UTC, wherever the person reading it is.
      on_exit(fn -> Application.delete_env(:troupe_plane, :budget_clock) end)
      at = fn now -> Application.put_env(:troupe_plane, :budget_clock, fn -> now end) end

      {:ok, _} =
        Ledger.record(%{
          session_id: "spent-it-all",
          team_id: context.engineering.id,
          owner_subject: context.lead.subject,
          model: "fake-model",
          cost_micros: 1_000_000,
          gateway_request_id: "spent-it-all-1",
          occurred_at: ~U[2026-09-12 09:00:00.000000Z]
        })

      Ledger.Cache.invalidate(context.engineering.id)
      conn = sign_in(context.conn, context.root.subject)

      at.(~U[2026-09-30 23:59:59.000000Z])
      {:ok, _view, html} = live(conn, "/admin")

      assert html =~
               "engineering is at its monthly ceiling. New sessions are refused until it is raised or the period turns over, on the 1st of the month (UTC)."

      at.(~U[2026-10-01 00:00:00.000000Z])
      {:ok, _view, html} = live(conn, "/admin")

      refute html =~ "engineering is at its monthly ceiling"
    end
  end

  describe "behind the glass" do
    setup do
      Application.put_env(:troupe_plane, :breakglass, token: "a-break-glass-token-for-tests")

      on_exit(fn ->
        Application.delete_env(:troupe_plane, :breakglass)
        Settings.reset("platform_admin_group", "test")
        Settings.reset("issuer", "test")
        Settings.invalidate()
      end)

      :ok
    end

    test "the door opens the page, marked, with sign-in as the plane holds it", context do
      conn = context.conn |> breakglass()
      {:ok, view, html} = live(conn, "/admin")

      assert html =~ "Break-glass session."
      assert has_element?(view, "#repair")
      assert has_element?(view, "#identity-checks")
      assert has_element?(view, "#sign-in-settings")
      assert html =~ "platform_admin_group"

      # A person who signed in through the provider is not shown it: the console is where
      # they change anything.
      {:ok, view, _html} = context.conn |> sign_in(context.root.subject) |> live("/admin")
      refute has_element?(view, "#repair")
    end

    test "puts back a group that locked every administrator out, and records it", context do
      # Saved in error: nobody carries it, so the platform admin is one no longer.
      {:ok, _} = Settings.put("platform_admin_group", "nobody-carries-this", "root")
      assert {:error, {:redirect, %{to: "/admin/denied"}}} =
               context.conn |> sign_in(context.root.subject) |> live("/admin")

      {:ok, view, _html} = context.conn |> breakglass() |> live("/admin")

      view
      |> element(~s(button[phx-click="confirm-reset"][phx-value-what="platform_admin_group"]))
      |> render_click()

      html =
        view
        |> element(~s(button[phx-click="reset"][phx-value-what="platform_admin_group"]))
        |> render_click()

      assert html =~ "platform_admin_group is back to what the deployment says."
      assert Settings.get("platform_admin_group") == "platform"
      assert [%{actor: "breakglass", action: "setting.reset"} | _] = Audit.list(kind: "setting")

      # And the person it locked out is in again.
      assert {:ok, _view, _html} = context.conn |> sign_in(context.root.subject) |> live("/admin")
    end

    test "puts sign-in back to the deployment, and offers nothing to type", context do
      {:ok, _} = Settings.put("issuer", "https://elsewhere.example.test", "root")

      {:ok, view, html} = context.conn |> breakglass() |> live("/admin")

      assert html =~ "https://elsewhere.example.test"
      refute has_element?(view, "#repair input:not([type=hidden])")

      view
      |> element(~s(button[phx-click="confirm-reset"][phx-value-what="sign-in"]))
      |> render_click()

      html =
        view |> element(~s(button[phx-click="reset"][phx-value-what="sign-in"])) |> render_click()

      assert html =~ "Sign-in is back to what the deployment says."
      refute Enum.any?(Settings.all(), &(&1.group == :sign_in and &1.source == :stored))
      assert [%{actor: "breakglass", action: "provider.reset"} | _] = Audit.list(kind: "provider")
    end
  end

  describe "where the editors went" do
    test "each page of the LiveView console is sent to the same place in the console", context do
      for {from, to} <- [
            {"/admin/teams", "/console#/teams"},
            {"/admin/workers", "/console#/pods"},
            {"/admin/workers/dev", "/console#/profiles/dev"},
            {"/admin/profile/new", "/console#/profiles"},
            {"/admin/profile/dev", "/console#/profiles/dev"},
            {"/admin/provider", "/console#/signin"},
            {"/admin/provisioners", "/console#/hosts"},
            {"/admin/review", "/console#/runs"},
            {"/admin/settings", "/console#/policy"},
            {"/admin/triggers/engineering", "/console#/triggers/engineering"}
          ] do
        assert redirected_to(get(context.conn, from)) == to, from
      end

      assert get(context.conn, "/admin/nothing-was-ever-here").status == 404
    end

    test "and to the page here on a plane deployed without the console", context do
      Application.put_env(:troupe_plane, :console_url, "")
      on_exit(fn -> Application.delete_env(:troupe_plane, :console_url) end)

      assert redirected_to(get(context.conn, "/admin/teams")) == "/admin"
    end
  end
  # -- helpers ----------------------------------------------------------------

  # What the break-glass door leaves in a session: a subject that is the door's, and its
  # own expiry.
  defp breakglass(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:subject, "breakglass")
    |> Plug.Conn.put_session(:breakglass, true)
    |> Plug.Conn.put_session(:breakglass_expires_at, System.system_time(:second) + 600)
  end
end
