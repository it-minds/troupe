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

  alias Troupe.Plane.{
    Admin,
    Audit,
    Bundles,
    Fleet,
    Identity,
    Ledger,
    Principals,
    SCIM,
    Sessions,
    Settings,
    Triggers
  }

  alias Troupe.Plane.Identity.ServicePrincipal
  alias Troupe.Plane.Triggers.Run
  alias Troupe.Plane.Web.Live.ProfileEditor

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
      links =
        Regex.scan(~r|/admin/workers/([\w-]+)|, html) |> Enum.map(&List.last/1) |> Enum.uniq()

      assert "dev" in links
      refute "ux" in links
    end

    test "only a platform admin is offered the drain button", context do
      {:ok, _view, lead_html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/workers")

      refute lead_html =~ "drain"

      {:ok, _view, root_html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/workers")

      assert root_html =~ "drain"
    end
  end

  describe "the sessions page" do
    test "shows metadata and says so", context do
      session = session!(context.engineering, "dev")

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      assert html =~ session.id
      assert html =~ "Metadata only"
      assert html =~ "No administrative role grants access to what a session said"
    end

    test "a team admin sees their team's and no others", context do
      mine = session!(context.engineering, "dev")
      theirs = session!(context.design, "ux")

      {:ok, _view, html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/sessions")

      assert html =~ mine.id
      refute html =~ theirs.id
    end

    test "erasing takes two clicks", context do
      session = session!(context.engineering, "dev")

      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      # The first click asks rather than does: erasure is irreversible and a misclick
      # should not be enough.
      html = view |> element("button[phx-value-session='#{session.id}']") |> render_click()
      assert html =~ "Irreversible"
      assert Sessions.get(session.id).state != "erased"
    end
  end

  describe "the triggers page" do
    test "lists a team's triggers with their runs, and switches one off", context do
      {:ok, principal, _secret} =
        principal!(context.engineering, %{name: "bot", profiles: ["dev"]})

      {:ok, _} =
        Triggers.put(
          context.engineering,
          %{
            "name" => "nightly-deps",
            "principal" => principal.subject,
            "profile" => "dev",
            "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5"},
            "prompt_template" => "Update every dependency."
          },
          "root"
        )

      {:ok, view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/triggers")

      assert html =~ "nightly-deps"
      assert html =~ "cron 0 3 * * 1-5"
      assert html =~ principal.subject
      assert html =~ "never run"

      html =
        view
        |> element("button[phx-click='disable'][phx-value-name='nightly-deps']")
        |> render_click()

      assert html =~ "nightly-deps disabled"
      refute Triggers.get(context.engineering, "nightly-deps").enabled

      # Another team's admin page shows none of it.
      {:ok, _view, design_html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/design")

      refute design_html =~ "nightly-deps"
    end
  end

  describe "the teams page" do
    test "shows members and offers no way to change them", context do
      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/teams")

      assert html =~ "member" or html =~ "Members"
      assert html =~ "From the identity provider, and read-only here"
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

    test "every period the page offers is one the team takes", context do
      # `daily` was offered here and refused by the team, so choosing it saved nothing and
      # said why only in a changeset's words.
      {:ok, view, _html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/teams")
      view |> element("button[phx-value-team='engineering']") |> render_click()

      offered =
        ~r/<option[^>]* value="([^"]+)"/
        |> Regex.scan(view |> element("select[name='budget_period']") |> render())
        |> Enum.map(fn [_option, value] -> value end)

      assert offered == Admin.budget_periods()

      for period <- offered do
        # A save that worked closes the form; one that was refused leaves it open.
        edit = element(view, "button[phx-value-team='engineering']")
        if has_element?(edit), do: render_click(edit)

        view
        |> form("form[phx-submit='save']", %{"team" => "engineering", "budget_period" => period})
        |> render_submit()

        assert Identity.get_team("engineering").budget_period == period
      end
    end

    test "a team admin is not offered grants", context do
      {:ok, _view, html} = context.conn |> sign_in(context.lead.subject) |> live("/admin/teams")
      refute html =~ ">grant<"

      {:ok, _view, root_html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/teams")

      assert root_html =~ ">grant<"
    end
  end

  describe "the audit page" do
    test "shows who changed what, with the diff", context do
      {:ok, _} =
        Admin.team_update(Admin.actor_for(context.lead), "engineering", %{budget_micros: 7})

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
        |> form("form[phx-submit='draft']", %{"content" => ~s({"agents": ["build"]})})
        |> render_submit()

      assert html =~ "sha256:"
      assert Bundles.current("stable").version == 1

      {:ok, _view, lead_html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/bundles")

      refute lead_html =~ "publish to"
    end

    test "the current version is shown as what it carries, and a bad draft as its errors",
         context do
      {:ok, view, _html} = context.conn |> sign_in(context.root.subject) |> live("/admin/bundles")

      bad =
        ~s({"schema": 1, "agents": [{"name": "reviewer", "definition": "---\\nmode: odd\\n---\\nHi"}]})

      html =
        view
        |> form("form[phx-submit='draft']", %{"content" => bad})
        |> render_submit(%{"action" => "check"})

      assert html =~ "bad_mode"
      assert Bundles.current("stable") == nil

      good =
        Jason.encode!(%{
          "schema" => 1,
          "agents" => [
            %{
              "name" => "reviewer",
              "definition" => "---\nmode: primary\ndescription: Reviews code\n---\nGo."
            }
          ],
          "skills" => [
            %{
              "name" => "checklist",
              "description" => "The list",
              "files" => %{
                "SKILL.md" => "---\nname: checklist\ndescription: The list\n---\nCheck."
              }
            }
          ],
          "mcp_servers" => [
            %{
              "name" => "jira",
              "url" => "https://mcp.jira.example/mcp",
              "credential_ref" => "JIRA_TOKEN"
            }
          ]
        })

      html = view |> form("form[phx-submit='draft']", %{"content" => good}) |> render_submit()

      assert html =~ "published v1"
      assert html =~ "reviewer"
      assert html =~ "Reviews code"
      assert html =~ "checklist"
      assert html =~ "troupe-mcp-jira"
      assert html =~ "JIRA_TOKEN"
      # And who has it: the enrolled pod has reported no hash yet.
      assert html =~ "troupe-w-dev-0 behind"
    end
  end

  describe "the profile editor" do
    test "shows the diff before applying, and only a platform admin sees it", context do
      assert {:error, {:redirect, %{to: "/admin"}}} =
               context.conn |> sign_in(context.lead.subject) |> live("/admin/profile/dev")

      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      assert html =~ "What will happen"
      assert html =~ "Change something to see what would be written"

      html = view |> element("form") |> render_change(%{"name" => "dev", "replicas" => "5"})

      assert html =~ "replicas"
      assert html =~ "5"
    end

    test "edits every part of the spec, not four fields of it", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      # The fields a profile actually has. A page that edits a subset of them is a page
      # that quietly makes the rest unreachable except by hand-written JSON.
      for field <- ~w(
            image sizeClass maxSessions warmWorkers
            llm.endpoint llm.provider llm.model llm.secretRef.name
            egress.fqdns egress.gitHosts
            storage.storageClassName
            configBundleChannel orgMount
          ) do
        assert html =~ ~s(name="#{field}"), "the editor has no field for #{field}"
      end

      # And the seven that left. They are still in the custom resource and the plane
      # writes them; an editor that still asked would be asking for a number it does not
      # use, which is worse than not asking.
      for gone <- ~w(
            replicas sessionsPerPod storage.size
            resources.requests.cpu resources.requests.memory
            resources.limits.cpu resources.limits.memory
          ) do
        refute html =~ ~s(name="#{gone}"), "the editor still asks for #{gone}"
      end
    end

    test "says what an image of release resolves to on this plane", context do
      image = "ghcr.io/objective-mj/troupe-worker:0.2.17"
      Application.put_env(:troupe_plane, :worker_image, image)
      on_exit(fn -> Application.delete_env(:troupe_plane, :worker_image) end)
      {:ok, _} = Fleet.put_profile(%{name: "dev", image: "release"})

      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      assert html =~ "Follows the release — #{image}"

      # A plane that cannot say is read before pressing apply rather than in the refusal
      # after it.
      Application.delete_env(:troupe_plane, :worker_image)
      html = view |> element("form") |> render_change(%{"name" => "dev", "image" => "release"})

      assert html =~ "deployed without a worker image"
    end

    test "a blank field is absent from the spec rather than empty in it" do
      draft =
        ProfileEditor.draft(%{
          fields: %{
            "name" => "dev",
            "image" => "ghcr.io/troupe/worker:1",
            "llm.model" => "gpt-4o",
            "storage.size" => "",
            "egress.fqdns" => "gateway.example.test\nregistry.example.test",
            "orgMount" => false
          },
          servers: []
        })

      assert draft["spec"]["llm"] == %{"model" => "gpt-4o"}
      assert draft["spec"]["egress"]["fqdns"] == ~w(gateway.example.test registry.example.test)

      # Not `%{"size" => ""}`, which is a resource the API server refuses, and not
      # `%{}`, which is a branch that says nothing.
      refute Map.has_key?(draft["spec"], "storage")
      refute Map.has_key?(draft["spec"], "resources")

      # A boolean is a value even when it is false: without this, unmounting the org
      # volume would be a change the form could express and never send.
      assert draft["spec"]["orgMount"] == false
    end

    # `llm.prices` is set through `admin.profile.put`, not on this page (Decision 689). A
    # draft rebuilt from the form alone would drop it on the next save, and the profile's
    # models would go back to costing nothing on the ledger.
    test "keeps the prices it does not show, so a save from here does not drop them", context do
      prices = %{"qwen3-235b" => %{"input" => 0.2, "output" => 0.6}}

      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          spec: %{"llm" => %{"model" => "qwen3-235b", "prices" => prices}}
        })

      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      html =
        view
        |> element("form")
        |> render_change(%{
          "name" => "dev",
          "llm.model" => "qwen3-235b",
          "llm.smallModel" => "qwen3-32b"
        })

      assert html =~ "qwen3-32b"
      refute html =~ "prices"
    end

    test "an MCP row with no url is a row being typed, not a server" do
      draft =
        ProfileEditor.draft(%{
          fields: %{"name" => "dev", "image" => "ghcr.io/troupe/worker:1"},
          servers: [
            %{"name" => "jira", "url" => "https://mcp.example.test", "timeoutMs" => "5000"},
            %{"name" => "half-typed", "url" => ""}
          ]
        })

      assert [server] = draft["spec"]["mcpServers"]
      assert server["name"] == "jira"
      assert server["timeoutMs"] == 5000
    end
  end

  describe "the review page" do
    setup context do
      {:ok, principal, _secret} =
        principal!(context.engineering, %{name: "nightly-bot", profiles: ["dev"]})

      {:ok, trigger} =
        Triggers.put(
          context.engineering,
          %{
            "name" => "nightly",
            "principal" => principal.subject,
            "profile" => "dev",
            "source" => %{"kind" => "schedule", "cron" => "0 3 * * *"},
            "prompt_template" => "Update every dependency."
          },
          "root"
        )

      # A session that ended badly. The run row is written here rather than fired, because
      # firing one would create a session on a worker and what is under test is the screen.
      failed = session!(context.engineering, "dev")

      failed
      |> Ecto.Changeset.change(%{status: "interrupted"})
      |> Repo.update!()

      # The revision the run ran, which every firing names: a run is answered against the
      # document as it was, not as it is now.
      {:ok, revision} = Triggers.revise(trigger, "root")

      run =
        %Run{}
        |> Run.changeset(%{
          trigger_id: trigger.id,
          revision_id: revision.id,
          idempotency_key: "nightly-#{System.unique_integer([:positive])}",
          session_id: failed.id,
          fired_at: DateTime.utc_now(),
          fired_by: "schedule",
          source: "schedule",
          event: %{},
          payload_digest: "sha256:none",
          state: "created"
        })
        |> Repo.insert!()

      %{trigger: trigger, run: run, session: failed}
    end

    test "leads with what needs a person, grouped by what fired it", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/review")

      assert html =~ "nightly"
      assert html =~ "failed"

      # Unreviewed, and said as a word rather than as an empty cell somebody has to
      # interpret.
      assert html =~ "nobody"
      assert html =~ "mark read"
    end

    test "and marking one read takes it off the list, with the reviewer's name", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/review")

      html =
        view
        |> element(~s(button[phx-value-session="#{context.session.id}"]))
        |> render_click()

      assert html =~ "marked read"

      # It is gone from the default view, because reviewed is a state somebody put it in
      # rather than a filter that hides it — and showing everything brings it back with the
      # name of whoever said it was fine.
      refute html =~ "mark read"

      html = view |> element("#review-scope") |> render_submit()
      assert html =~ context.root.subject
    end
  end

  describe "the integrations page" do
    test "checks every host against the policy that will actually decide", context do
      # A policy that allows nothing, which is the seam the bundle validator uses too.
      Application.put_env(:troupe_plane, :egress_allowed, fn host -> host == "ok.example" end)
      on_exit(fn -> Application.delete_env(:troupe_plane, :egress_allowed) end)

      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          spec: %{"egress" => %{"fqdns" => ["ok.example", "refused.example"]}}
        })

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/integrations")

      assert html =~ "ok.example"
      assert html =~ "refused.example"
      assert html =~ "allowed"
      assert html =~ "refused"

      # And where the host was declared, because that is where the repair is made.
      assert html =~ "declared by"
      assert html =~ "dev"
    end

    test "and re-checks a notification target rather than trusting that it passed once",
         context do
      {:ok, principal, _secret} =
        principal!(context.engineering, %{name: "nightly-bot", profiles: ["dev"]})

      {:ok, _} =
        Triggers.put(
          context.engineering,
          %{
            "name" => "nightly",
            "principal" => principal.subject,
            "profile" => "dev",
            "source" => %{"kind" => "schedule", "cron" => "0 3 * * *"},
            "prompt_template" => "Update every dependency.",
            "notify_url" => "https://hooks.example/troupe"
          },
          "root"
        )

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/integrations")

      assert html =~ "Where outcomes are sent"
      assert html =~ "hooks.example"

      # The rule it is held to is stated where somebody would otherwise wonder why their
      # localhost target was refused.
      assert html =~ "must name a host"
    end
  end

  describe "the identity page" do
    test "shows a team's principals, and makes one with the secret shown once", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/identity")

      assert html =~ "Service principals"

      html =
        view
        |> form("form[phx-submit='create-principal']", %{
          "team" => "engineering",
          "name" => "nightly-deps",
          "profiles" => "dev",
          "sponsor" => context.lead.subject,
          "description" => "the nightly dependency update"
        })
        |> render_submit()

      assert html =~ "svc:engineering/nightly-deps"
      assert html =~ "shown once"

      principal = Principals.get("svc:engineering/nightly-deps")
      assert principal.profiles == ["dev"]
      assert principal.sponsor_subject == context.lead.subject

      # The hash is not on the page, and neither is the salt.
      refute html =~ principal.secret_hash
      refute html =~ principal.secret_salt
    end

    test "refuses one with no sponsor, and says so in words", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/identity")

      html =
        view
        |> form("form[phx-submit='create-principal']", %{
          "team" => "engineering",
          "name" => "unsponsored",
          "profiles" => "dev"
        })
        |> render_submit()

      # Not "invalid_params". Four things can be wrong with a sponsor and the person at
      # the form has to be told which.
      assert html =~ "answerable"
      refute Principals.get("svc:engineering/unsponsored")
    end

    test "says a principal needs a sponsor rather than that it is disabled", context do
      {:ok, principal, _secret} =
        principal!(context.engineering, %{
          name: "orphan",
          profiles: ["dev"],
          sponsor: context.lead.subject
        })

      {:ok, _} = SCIM.deactivate_user(Identity.get_user(context.lead.subject).id)

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/identity")

      assert html =~ "needs a sponsor"
      refute Principals.get(principal.subject) |> ServicePrincipal.enabled?()
    end

    test "runs the check against the group in the field, not the one that is stored",
         context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/identity")

      html =
        view
        |> form("#identity-check", %{"group" => "nobody-carries-this"})
        |> render_submit()

      # The useful question is not whether that is a valid group but how many people would
      # administer this platform afterwards.
      assert html =~ "never arrived in the"

      html =
        view
        |> form("#identity-check", %{"group" => "platform"})
        |> render_submit()

      assert html =~ "including you."
    end

    test "lists the groups this plane has actually seen", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/identity")

      assert html =~ "Groups this plane has seen"
      assert html =~ "engineering"

      # Mirrored, never authored — and the page says so where somebody would look for the
      # button that is not there.
      assert html =~ "Mirrored, never authored"
      refute html =~ "add member"
    end
  end

  describe "deleting a profile" do
    test "names the teams that lose the grant, and what happens to the sessions", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      # `admin.profile.delete` was in the API, in the CLI and in the MCP tool list, and on
      # no screen at all. This is the screen the coverage test said it was owed.
      assert html =~ "Delete dev"

      html = view |> element(~s(button[phx-click="confirm-delete"])) |> render_click()

      assert html =~ "every grant goes"
      assert html =~ "engineering"
      assert html =~ "its sessions become read-only"
    end

    test "and refuses until the profile's own name is typed", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      view |> element(~s(button[phx-click="confirm-delete"])) |> render_click()

      html =
        view
        |> element("#delete-profile")
        |> render_submit(%{"confirm" => "devv"})

      assert html =~ "nothing was deleted"
      refute is_nil(Fleet.get_profile("dev"))
    end
  end

  describe "publishing a bundle" do
    setup context do
      {:ok, _} =
        Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

      {:ok, _} =
        Bundles.publish(
          "stable",
          %{
            "schema" => 1,
            "skills" => [],
            "mcp_servers" => [],
            "agents" => [
              %{"name" => "reviewer", "definition" => "---
description: Reviews
mode: primary
---
You review."},
              %{"name" => "builder", "definition" => "---
description: Builds
mode: primary
---
You build."}
            ]
          },
          announce: false
        )

      actor = Admin.actor_for_subject(context.root.subject)

      # `engineering` is allowed the agent the next version removes. A deny row on the
      # other one, so the test also says what a loss is not.
      {:ok, _} =
        Admin.team_grant(actor, "engineering", "dev", %{
          "entitlements" => [
            %{"kind" => "agent", "name" => "reviewer", "mode" => "allow"},
            %{"kind" => "agent", "name" => "builder", "mode" => "deny"}
          ]
        })

      %{actor: actor}
    end

    test "shows what changes and names the teams that lose an entitlement", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/bundles")

      without_reviewer =
        Jason.encode!(%{
          "schema" => 1,
          "skills" => [],
          "mcp_servers" => [],
          "agents" => [%{"name" => "builder", "definition" => "---
description: Builds
mode: primary
---
You build."}]
        })

      html =
        view
        |> element("#bundle-draft")
        |> render_submit(%{"content" => without_reviewer, "action" => "check"})

      assert html =~ "What publishing this would change"
      assert html =~ "agents"

      # Done item 4's second half, and the question a publish actually raises.
      assert html =~ "Who loses something"
      assert html =~ "engineering"
      assert html =~ "reviewer"
    end

    test "and a deny row losing its target is not a loss", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/bundles")

      without_builder =
        Jason.encode!(%{
          "schema" => 1,
          "skills" => [],
          "mcp_servers" => [],
          "agents" => [%{"name" => "reviewer", "definition" => "---
description: Reviews
mode: primary
---
You review."}]
        })

      html =
        view
        |> element("#bundle-draft")
        |> render_submit(%{"content" => without_builder, "action" => "check"})

      # `engineering` denies `builder`, so it was not getting it and has lost nothing.
      # Reporting it would bury the rows that matter under the rows that do not.
      assert html =~ "No team holds an entitlement naming an entry this version removes"
    end

    test "and a draft that changes nothing says so rather than showing an empty diff",
         context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/bundles")

      same =
        Jason.encode!(%{
          "schema" => 1,
          "skills" => [],
          "mcp_servers" => [],
          "agents" => [
            %{"name" => "reviewer", "definition" => "---
description: Reviews
mode: primary
---
You review."},
            %{"name" => "builder", "definition" => "---
description: Builds
mode: primary
---
You build."}
          ]
        })

      html =
        view
        |> element("#bundle-draft")
        |> render_submit(%{"content" => same, "action" => "check"})

      assert html =~ "Nothing changes"
    end
  end

  describe "the erase dialog" do
    setup context do
      # Erasing releases the session's place, which is a `:global` actor — the rest of this
      # page reads tables and does not need one.
      start_supervised!(Troupe.Plane.Singleton)

      parent = session!(context.engineering, "dev")

      {:ok, child} =
        Sessions.create(%{
          id: "s-fork-#{System.unique_integer([:positive])}",
          owner_subject: "someone@example.test",
          team_id: context.engineering.id,
          profile: "dev",
          state: "active",
          epoch: 1,
          parent_session_id: parent.id,
          parent_seq: 4,
          fork_reason: "attempt"
        })

      %{parent: parent, child: child}
    end

    test "names the three consequences, and counts the forks that survive", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      html =
        view
        |> element(
          ~s(button[phx-click="confirm-erase"][phx-value-session="#{context.parent.id}"])
        )
        |> render_click()

      # One: the key, in every version, so a restore recovers ciphertext and nothing else.
      assert html =~ "the key is destroyed"
      assert html =~ "every version of it, in the key manager"

      # Two: the whole prefix, prior versions included.
      assert html =~ "every object version goes"
      assert html =~ "versioned bucket"

      # Three, and the one people expect to go the other way.
      assert html =~ "1 fork survives"
      assert html =~ context.child.id
    end

    test "refuses until the session's own identifier is typed", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      view
      |> element(~s(button[phx-click="confirm-erase"][phx-value-session="#{context.parent.id}"]))
      |> render_click()

      # Typing something else erases nothing, and says so. Checked on the server as well as
      # disabled in the page: a check that lived only in the markup is one a form post
      # walks past.
      html =
        view
        |> element("#erase-session")
        |> render_submit(%{"session" => context.parent.id, "confirm" => "s-not-that-one"})

      assert html =~ "nothing was erased"
      assert Sessions.get(context.parent.id).state != "erased"
    end

    test "and the fork is still there afterwards", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/sessions")

      view
      |> element(~s(button[phx-click="confirm-erase"][phx-value-session="#{context.parent.id}"]))
      |> render_click()

      view
      |> element("#erase-session")
      |> render_submit(%{"session" => context.parent.id, "confirm" => context.parent.id})

      # The dialog's third claim, checked rather than taken on trust: the child has its own
      # key and is not erased with its parent.
      assert Sessions.get(context.child.id).state != "erased"
    end
  end

  describe "the audit page's integrity tab" do
    test "says the chain verifies, and how far back it reaches", context do
      {:ok, _} = Audit.record(context.root.subject, "team.grant", "engineering", %{"a" => 1})

      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/audit")

      # Run on request, not on load: the walk reads the whole trail.
      assert html =~ "check the chain"
      refute html =~ "The chain verifies"

      html = view |> element("#audit-verify") |> render_submit()

      assert html =~ "The chain verifies"
      assert html =~ "back to"
    end

    test "and names the row when one byte is changed behind the application", context do
      {:ok, _} = Audit.record(context.root.subject, "setting.put", "pins_allowed", %{})
      {:ok, two} = Audit.record("ada@example.test", "team.grant", "delivery", %{})
      {:ok, _} = Audit.record(context.root.subject, "team.revoke", "delivery", %{})

      {:ok, _} =
        Repo.query(
          "UPDATE audit_events SET subject_id = $1 WHERE id = $2",
          ["deIivery", Ecto.UUID.dump!(two.id)]
        )

      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/audit")

      html = view |> element("#audit-verify") |> render_submit()

      assert html =~ "A row does not verify"
      assert html =~ "altered"

      # The row, not the fact. "The trail is wrong" is not something anybody can act on.
      assert html =~ "ada@example.test"
      assert html =~ "team.grant"
      assert html =~ "still verifies"
    end

    test "and a trail with nothing chained does not claim to have verified it", context do
      # Read off the page against a plane whose six rows all predated the migration:
      # "The chain verifies — 0 rows" is a verification of nothing, said as though it were
      # one. The number is the honest headline.
      #
      # Reproduced by leaving exactly what an upgrade leaves: rows with no hash and nothing
      # written since.
      {:ok, _} = Repo.query("DELETE FROM audit_events", [])

      {:ok, _} =
        Repo.query(
          """
          INSERT INTO audit_events
            (id, actor, on_behalf_of, action, subject_kind, subject_id, detail,
             occurred_at, inserted_at, updated_at)
          VALUES ($1, 'old@example.test', 'old@example.test', 'team.enable', 'team',
                  'engineering', '{}', $2, $2, $2)
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), ~U[2020-01-01 00:00:00.000000Z]]
        )

      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/audit")

      html = view |> element("#audit-verify") |> render_submit()

      assert html =~ "Nothing is chained yet"
      refute html =~ "The chain verifies"
      assert html =~ "The chain starts at the next"
    end

    test "and a team admin is not offered a check of a trail they cannot see", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/audit")

      refute html =~ "check the chain"
    end
  end

  describe "the connections page" do
    setup context do
      {:ok, _} =
        Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

      {:ok, _} =
        Bundles.publish(
          "stable",
          %{
            "schema" => 1,
            "agents" => [],
            "skills" => [],
            "mcp_servers" => [
              %{
                "name" => "jira",
                "url" => "https://mcp.jira.example/mcp",
                "credential_mode" => "person"
              }
            ]
          },
          announce: false
        )

      session = session!(context.engineering, "dev")
      %{session: session}
    end

    test "lists the server, its slot, and who has connected", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/connections")

      assert html =~ "jira"
      assert html =~ "Slot"

      # Nobody has filled it — and "not connected" has to be said rather than left as an
      # empty list a reader would take for "everybody has".
      assert html =~ "Not connected" or html =~ "Nobody has connected this one yet"
    end

    test "names the credential's owner and says a session has one identity", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/connections")

      # Done item 9's two names: whose credential the calls go out with, against the
      # session that makes them.
      assert html =~ "A session has one identity"
      assert html =~ "calls go out as"
      assert html =~ context.session.id
      assert html =~ "someone@example.test"
    end

    test "and says where somebody would look for it that there is nothing to read",
         context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/connections")

      assert html =~ "cannot read or remove"
      assert html =~ "There is no method for either"
    end
  end

  describe "the provisioners page" do
    setup do
      {:ok, _} = Fleet.put_profile(%{name: "laptops", provisioner: "ssh"})
      :ok
    end

    test "names every guarantee a substrate does not give, one at a time", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/provisioners")

      assert html =~ "kubernetes"
      assert html =~ "ssh"

      # Four names rather than the word. "Unenforced" is not a useful thing to tell
      # somebody deciding whether their team's work may run on somebody's build box.
      for name <- [
            "admission policy",
            "network policy",
            "egress by hostname",
            "disruption budget"
          ] do
        assert html =~ name, "the #{name} guarantee is not named anywhere"
      end

      assert html =~ "not given"
      assert html =~ "laptops"
    end

    test "and says plainly that this is not a way around the policy", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/provisioners")

      assert html =~ "deliberate friction"
      assert html =~ "not a way around the policy"

      # Nobody has been allowed, so the page says so rather than showing an empty list
      # that reads as "anybody may".
      assert html =~ "No team may be granted"
    end
  end

  describe "the budgets page" do
    # The ceilings are actors, one per rung, registered with `:global` — so asking which
    # one binds starts three of them. The rest of the panel reads tables and does not,
    # which is why this is the one screen here that needs the supervisor they live under.
    setup do
      start_supervised!(Troupe.Plane.Singleton)
      :ok
    end

    test "lists every team's ceiling with the figures, not only a bar", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/budgets")

      assert html =~ "engineering"
      assert html =~ "design"

      # The design's rule, and the reason this page exists rather than a bar on Overview:
      # a bar alone says "quite full", which is not a number and is nothing at all without
      # colour. The figures are in the markup beside every bar.
      assert html =~ "budget__figures"
      assert html =~ "1.00"
    end

    test "and a team that has spent nothing is not reported as having spent unlimited",
         context do
      # `money/1` reads a zero as *no ceiling*, which is right for a ceiling and wrong for
      # a spend — and the figures beside every bar are a spend. Read off the rendered page
      # as `unlimited / 500.00 this period` for a team that had spent nothing at all.
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/budgets")

      figures =
        Regex.scan(~r{<span class="budget__figures">(.*?)</span>}s, html)
        |> Enum.map(&(&1 |> List.last() |> String.trim()))

      refute figures == [], "no budget bar rendered, so this proves nothing"

      for figure <- figures do
        refute String.starts_with?(figure, "unlimited"),
               "a spend was rendered as a ceiling: #{inspect(figure)}"
      end
    end

    test "and a spend column never says unlimited, on any screen that has one", context do
      # `amount/1` rendered through `money/1`, which reads a zero as *no ceiling*. Every
      # caller of it is a spend or a reservation and none is a ceiling, so a team that had
      # spent nothing was reported as having spent "unlimited" — on three screens.
      conn = sign_in(context.conn, context.root.subject)

      for path <- ["/admin", "/admin/teams", "/admin/budgets"] do
        {:ok, _view, html} = live(conn, path)

        spends =
          Regex.scan(
            ~r{<span class="mono" style="font-variant-numeric: tabular-nums">\s*([^<]*)},
            html
          )
          |> Enum.map(&(&1 |> List.last() |> String.trim()))

        refute spends == [], "#{path} rendered no amount at all, so this proves nothing"

        refute "unlimited" in spends,
               "#{path} renders a spend as a ceiling: #{inspect(Enum.uniq(spends))}"
      end
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
      conn = sign_in(context.conn, context.root.subject)

      {:ok, _view, html} = live(conn, "/admin/budgets")

      figures =
        Regex.scan(~r{<span class="budget__figures">(.*?)</span>}s, html)
        |> Enum.map(&(&1 |> List.last() |> String.trim()))

      assert "1.00 / 1.00 in total" in figures
      refute Enum.any?(figures, &String.ends_with?(&1, "never"))

      {:ok, _view, html} = live(conn, "/admin")

      assert html =~ "engineering is at its ceiling, which never turns over."
      refute html =~ "never ceiling"
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

    test "names which ceiling refuses first, and says it in words", context do
      actor = Admin.actor_for_subject(context.root.subject)

      # A personal cap tighter than the team's, so the answer is not the number somebody
      # would have guessed from the team page.
      {:ok, _} = Admin.person_budget(actor, context.lead.subject, 40_000)

      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/budgets")

      html =
        view
        |> element("#explain-budget")
        |> render_submit(%{"team" => "engineering", "subject" => context.lead.subject})

      assert html =~ "this person&#39;s own cap" or html =~ "this person's own cap"
      assert html =~ "is what refuses first"
      # The number, not the word: a scope with nothing said about the amount is the
      # support ticket this page exists to stop somebody opening.
      assert html =~ "0.04 left"
      assert html =~ "binds first"

      # Every rung that was asked, not only the winner: the other two are what somebody
      # changes if the tight one is right.
      assert html =~ "the team&#39;s ceiling" or html =~ "the team's ceiling"

      assert html =~ "the platform&#39;s, or the deployment&#39;s" or
               html =~ "the platform's, or the deployment's"
    end

    test "and a rung with no ceiling is not reported as the reason", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/budgets")

      # `design` has no ceiling and nobody here has a personal cap, so nothing binds —
      # and "absence means everything" has to read as nothing refusing rather than as a
      # rung at zero.
      html =
        view
        |> element("#explain-budget")
        |> render_submit(%{"team" => "design", "subject" => ""})

      assert html =~ "No rung here has a ceiling at all"
      refute html =~ "binds first"
    end
  end

  describe "the policy page" do
    # Done item 3 of the console document, which is also rule 1: for a setting decided at
    # three rungs, the view names the winner and *both losers with their values*, and a
    # team's attempt to widen it is refused with the floor quoted.
    #
    # Three rungs are arranged in the order they happen in life rather than the order they
    # are read in: the team asks for ninety days while the platform has no opinion, and the
    # platform then narrows to thirty. That is the case the ladder exists for — the team's
    # row is left alone and stops being what runs — and it is the case a page showing one
    # rung's value cannot explain.
    setup context do
      actor = Admin.actor_for_subject(context.root.subject)

      {:ok, _team} = Admin.team_update(actor, "engineering", %{erase_after_days: 90})
      {:ok, _applied} = Admin.setting_put(actor, "default_erase_after_days", "30")

      on_exit(fn -> Settings.reset("default_erase_after_days", "test") end)

      %{actor: actor, deployed: 365}
    end

    test "names the winner and both losers, with their values", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/policy")

      # Two rungs without a team: what no team may exceed.
      assert html =~ "default_erase_after_days"
      assert html =~ "the platform — what no team may exceed"

      # The team's opinion joins the two above it.
      html =
        view
        |> element("#policy-as-team")
        |> render_change(%{"team" => "engineering"})

      row = ladder_row(html, "default_erase_after_days")

      # The winner, named as a rung rather than implied by being first.
      assert row =~ "30"
      assert row =~ ~s(class="rung rung--platform")
      assert row =~ "in force"

      # And both losers, with the values they hold. This is the half a settings page
      # leaves out: 30 says nothing about why somebody's 365 is not in force.
      assert row =~ "365", "the deployment's opinion is missing, so a loser is unnamed"
      assert row =~ "90", "the team's own opinion is missing, so a loser is unnamed"
    end

    test "and a team's attempt to widen it is refused with the floor quoted", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/teams")

      # The edit form only exists once somebody opens it, which is also how a reader gets
      # to it: the page is a list of teams and not a page of open forms.
      view
      |> element(~s(button[phx-click="edit"][phx-value-team="engineering"]))
      |> render_click()

      html =
        view
        |> element("#edit-engineering")
        |> render_submit(%{"team" => "engineering", "erase_after_days" => "200"})

      # Not "forbidden", and not the rule alone: the number they do not have.
      assert html =~ "erase_after_days"
      assert html =~ "200"
      assert html =~ "30"
      assert html =~ "wider than"
      assert html =~ "platform"
    end

    test "says what the deployment is and that this console does not edit it", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/policy")

      assert html =~ "The floor, and read-only from this console."
      assert html =~ "may narrow the deployment and never widen it"
    end

    test "says what every setting does and where its value came from", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/policy")

      assert html =~ "platform_admin_group"
      assert html =~ "provisioning_mode"

      # The panels, so a reader is not handed a flat list of twenty keys.
      assert html =~ "Who administers this platform"
      assert html =~ "What this plane was deployed with"

      # Where the value came from, which is the question a settings page usually leaves
      # a person guessing at.
      assert html =~ "from the deployment"
    end

    test "a secret is reported as set and never shown", context do
      Application.put_env(:troupe_plane, :scim_token, "sh-do-not-print-me")
      on_exit(fn -> Application.delete_env(:troupe_plane, :scim_token) end)

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/policy")

      assert html =~ "scim_token"
      assert html =~ "reference only, never shown"
      refute html =~ "sh-do-not-print-me"
    end

    test "a team admin reads it and cannot save any of it", context do
      {:ok, _view, html} =
        context.conn |> sign_in(context.lead.subject) |> live("/admin/policy")

      assert html =~ "read-only for you"
      assert html =~ "platform_admin_group"

      # Not one enabled save button on the page.
      refute html =~ ~r/<button type="submit"(?![^>]*disabled)/
    end

    test "the group that decides who administers cannot be saved unchecked", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/policy")

      assert html =~ "Run the check below before saving this one"

      # Checking a group nobody is in leaves it locked: this is the whole point, and the
      # reason is written where the person about to lock themselves out will read it.
      html =
        view
        |> element(~s(form[phx-submit="save"]), "platform_admin_group")
        |> render_change(%{"key" => "platform_admin_group", "value" => "nobody-carries-this"})

      _ = html
      html = view |> element(~s(button[phx-click="check"])) |> render_click()

      assert html =~ "never arrived in the"
      assert html =~ "Run the check below before saving this one"

      # Checking one that people do carry unlocks it, and says who.
      html =
        view
        |> element(~s(form[phx-submit="save"]), "platform_admin_group")
        |> render_change(%{"key" => "platform_admin_group", "value" => "platform"})

      _ = html
      html = view |> element(~s(button[phx-click="check"])) |> render_click()

      assert html =~ "including you."
      refute html =~ "Run the check below before saving this one"
    end
  end

  # -- helpers ----------------------------------------------------------------

  # One row of the ladder table. Asserting against the whole page would let a claim about
  # `default_erase_after_days` pass on another setting's numbers, and three of the five
  # laddered settings are counts of days.
  defp ladder_row(html, key) do
    [row] =
      Regex.scan(~r{<tr>(?:(?!</tr>).)*?<code>#{Regex.escape(key)}</code>.*?</tr>}s, html)
      |> Enum.map(&List.first/1)

    row
  end

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
