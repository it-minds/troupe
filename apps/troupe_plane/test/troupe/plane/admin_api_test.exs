defmodule Troupe.Plane.AdminAPITest do
  @moduledoc """
  The admin API over `/rpc`, as a client reaches it.

  `Troupe.Plane.AdminTest` covers what the context decides; this covers that the decision
  survives the trip — that a method name reaches the right function with the right
  arguments, that the role comes from the token rather than from anything the caller
  says, and that an ordinary user calling an admin method is refused by the same rule a
  team admin calling a platform method is.
  """

  use Troupe.Plane.DataCase, async: false

  import Phoenix.ConnTest

  alias Troupe.Plane.{Admin, Audit, Fleet, Identity, OIDC, Repo, Sessions, Tokens}
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Admin.API.Method
  alias Troupe.Protocol.Token

  @endpoint Troupe.Plane.Web.Endpoint

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    engineering = team_with_grant("engineering", "dev", name: "engineering")
    design = team_with_grant("design", "ux", name: "design")

    {:ok, platform_group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(platform_group, %{name: "platform"})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    user = person("ada@example.test", ["engineering"])

    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)
    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 1, sessions_per_pod: 2})

    %{engineering: engineering, design: design, root: root, lead: lead, user: user}
  end

  describe "over the wire" do
    test "an admin method answers for a platform admin", context do
      assert %{"result" => result} = rpc(context.root, "admin.overview", %{})
      assert result["sessions"]
      assert result["profiles"]
    end

    test "an ordinary user is refused, with the role they would need", context do
      assert %{"error" => error} = rpc(context.user, "admin.overview", %{})

      assert error["message"] == "forbidden"
      assert error["data"]["required_role"] == "team_admin"
    end

    test "a team admin is refused a platform method, with the role they would need", context do
      assert %{"error" => error} = rpc(context.lead, "admin.profile.put", %{"profile" => %{"name" => "new"}})

      assert error["message"] == "forbidden"
      assert error["data"]["required_role"] == "platform_admin"
    end

    test "the role comes from the caller's identity, not from what they send", context do
      # A caller who claims to be a platform admin in the params is still whatever their
      # token's subject is.
      assert %{"error" => error} =
               rpc(context.user, "admin.overview", %{"role" => "platform_admin", "actor" => "root@example.test"})

      assert error["message"] == "forbidden"
    end

    test "an unknown admin method is a method error", context do
      assert %{"error" => error} = rpc(context.root, "admin.nonsense", %{})
      assert error["message"] == "method_not_found"
    end

    test "an admin method reached without a token is unauthenticated", context do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/rpc", Jason.encode!(request("admin.overview", %{})))

      assert conn.status == 401
      _ = context
    end
  end

  describe "arguments" do
    test "reach the context in the right order", context do
      actor = Admin.actor_for(context.root)

      assert {:ok, result} =
               API.call("admin.team.grant", %{"name" => "engineering", "profile" => "ux"}, actor)

      assert Enum.map(result.grants, & &1.profile) |> Enum.sort() == ["dev", "ux"]
    end

    test "a filter is turned into the options the context takes", context do
      actor = Admin.actor_for(context.root)
      session!(context.engineering, "dev", "active")
      session!(context.engineering, "dev", "dormant")

      assert {:ok, all} = API.call("admin.sessions.list", %{}, actor)
      assert length(all) == 2

      assert {:ok, [only]} = API.call("admin.sessions.list", %{"filter" => %{"state" => "dormant"}}, actor)
      assert only.state == "dormant"
    end

    test "a required argument that was not sent is named, not crashed on", context do
      actor = Admin.actor_for(context.root)

      # `admin.bundles.list` is the one that found this: its `channel` reached
      # `Bundles.list/1` as nil and Ecto refuses to compare a column with nil, which is an
      # ArgumentError, which is a 500 on a public endpoint.
      assert {:error, error} = API.call("admin.bundles.list", %{}, actor)
      assert error.message == "invalid_params"
      assert error.data.missing == ["channel"]
    end

    test "every method with a required argument says so rather than raising", context do
      actor = Admin.actor_for(context.root)

      # The whole surface, because the defect was never about bundles: forty arguments
      # were declared `required: true` and not one of them was enforced, so *any* client
      # omitting *any* of them got whatever that context function did with a nil. A test
      # naming one method would have left thirty-nine.
      for method <- API.list(), Method.required_names(method) != [] do
        answer =
          try do
            API.call(method.name, %{}, actor)
          rescue
            error -> {:raised, error}
          end

        assert {:error, %{message: "invalid_params"} = error} = answer,
               "#{method.name} answered #{inspect(answer)}"

        assert error.data.missing != [], method.name
      end
    end

    test "an unknown filter key is ignored rather than crashing", context do
      actor = Admin.actor_for(context.root)

      # `String.to_existing_atom` on caller-supplied keys would be a way to grow the atom
      # table from outside; anything not on the list is simply not an option.
      assert {:ok, _} = API.call("admin.sessions.list", %{"filter" => %{"nonsense" => "x"}}, actor)
    end
  end

  describe "scoping, over the wire" do
    test "a team admin sees only their team's sessions and spend", context do
      mine = session!(context.engineering, "dev", "active")
      theirs = session!(context.design, "ux", "active")

      assert %{"result" => sessions} = rpc(context.lead, "admin.sessions.list", %{})
      ids = Enum.map(sessions, & &1["id"])

      assert mine.id in ids
      refute theirs.id in ids

      assert %{"result" => overview} = rpc(context.lead, "admin.overview", %{})
      assert Enum.map(overview["teams"], & &1["name"]) == ["engineering"]
    end

    test "and nothing returns session content", context do
      session!(context.engineering, "dev", "active")

      assert %{"result" => [rendered]} = rpc(context.lead, "admin.sessions.list", %{})

      for key <- ~w(events content conversation log messages) do
        refute Map.has_key?(rendered, key), "the admin API returned #{key}"
      end
    end
  end

  # #695: what a team admin reads of the trail, an audit check that fails, a session filter
  # by team, and enabling a group under a name a team already has.
  describe "the admin API's answers" do
    test "a team admin's audit trail is the rows about their own teams", context do
      mine = session!(context.engineering, "dev", "active")
      theirs = session!(context.design, "ux", "active")
      root = context.root.subject

      {:ok, _} = Audit.record(root, "team.update", "engineering", %{})
      {:ok, _} = Audit.record(root, "team.update", "design", %{})
      {:ok, _} = Audit.record(root, "trigger.put", "engineering/nightly", %{})
      {:ok, _} = Audit.record(root, "trigger.put", "design/nightly", %{})
      {:ok, _} = Audit.record(root, "principal.create", "svc:engineering/bot", %{})
      {:ok, _} = Audit.record(root, "principal.create", "svc:design/bot", %{})
      {:ok, _} = Audit.record(root, "session.share", mine.id, %{})
      {:ok, _} = Audit.record(root, "session.share", theirs.id, %{})
      {:ok, _} = Audit.record(root, "run.review", theirs.id, %{}, kind: "run")
      {:ok, _} =
        Audit.record("worker:p-0", "github.token", "example-org/app", %{"session_id" => mine.id})

      {:ok, _} =
        Audit.record("worker:p-1", "github.token", "example-org/web", %{"session_id" => theirs.id})

      {:ok, _} = Audit.record(root, "profile.put", "dev", %{})
      {:ok, _} = Audit.record(root, "setting.put", "pins_allowed", %{})

      assert %{"result" => rows} = rpc(context.lead, "admin.audit.list", %{})

      assert rows |> Enum.map(&{&1["action"], &1["subject_id"]}) |> Enum.sort() ==
               Enum.sort([
                 {"team.update", "engineering"},
                 {"trigger.put", "engineering/nightly"},
                 {"principal.create", "svc:engineering/bot"},
                 {"session.share", mine.id},
                 {"github.token", "example-org/app"}
               ])

      # The platform admin's is the whole trail.
      assert %{"result" => all} = rpc(context.root, "admin.audit.list", %{})
      assert length(all) >= 13
      assert Enum.any?(all, &(&1["subject_id"] == "design"))
      assert Enum.any?(all, &(&1["subject_id"] == "pins_allowed"))
    end

    test "admin.audit.verify answers a failed check, naming the first bad row", context do
      {:ok, _} = Audit.record(context.root.subject, "setting.put", "pins_allowed", %{})
      {:ok, two} = Audit.record("ada@example.test", "team.grant", "delivery", %{})
      {:ok, _} = Audit.record(context.root.subject, "team.revoke", "delivery", %{})

      {:ok, _} =
        Repo.query("UPDATE audit_events SET subject_id = $1 WHERE id = $2", [
          "deIivery",
          Ecto.UUID.dump!(two.id)
        ])

      assert %{"result" => answer} = rpc(context.root, "admin.audit.verify", %{})
      assert answer["checked"] >= 3

      assert %{
               "id" => id,
               "reason" => "altered",
               "action" => "team.grant",
               "actor" => "ada@example.test",
               "subject_id" => "deIivery"
             } = answer["result"]

      assert id == two.id
    end

    test "admin.sessions.list applies its team filter", context do
      mine = session!(context.engineering, "dev", "active")
      theirs = session!(context.design, "ux", "active")

      assert %{"result" => design} =
               rpc(context.root, "admin.sessions.list", %{"filter" => %{"team" => "design"}})

      assert Enum.map(design, & &1["id"]) == [theirs.id]

      assert %{"result" => engineering} =
               rpc(context.lead, "admin.sessions.list", %{"filter" => %{"team" => "engineering"}})

      assert Enum.map(engineering, & &1["id"]) == [mine.id]

      # Another team's name is not one a team admin can see, by the rule `admin.teams.list`
      # keeps: whether a team exists is not theirs to learn.
      assert %{"error" => %{"message" => "not_found"}} =
               rpc(context.lead, "admin.sessions.list", %{"filter" => %{"team" => "design"}})
    end

    test "admin.team.enable refuses a name a team already has, unless asked to link into it",
         context do
      {:ok, _} = Identity.upsert_group(%{external_id: "grp-newcomers", display_name: "Newcomers"})

      assert %{"error" => error} =
               rpc(context.root, "admin.team.enable", %{
                 "group" => "grp-newcomers",
                 "attrs" => %{"name" => "engineering", "budget_micros" => 1}
               })

      assert error["message"] == "conflict"
      assert error["data"]["team"] == "engineering"
      assert error["data"]["reason"] =~ "link"

      team = Identity.get_team("engineering")
      refute team.budget_micros == 1
      refute "grp-newcomers" in linked_groups(team)

      # Asked for, it links the group into the team.
      assert %{"result" => linked} =
               rpc(context.root, "admin.team.enable", %{
                 "group" => "grp-newcomers",
                 "attrs" => %{"name" => "engineering"},
                 "link" => true
               })

      assert linked["name"] == "engineering"
      assert "grp-newcomers" in linked_groups(Identity.get_team("engineering"))

      # Enabling a team's own group again is the same team, as it always was.
      assert %{"result" => %{"name" => "design"}} =
               rpc(context.root, "admin.team.enable", %{
                 "group" => "design",
                 "attrs" => %{"name" => "design"}
               })
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp rpc(user, method, params) do
    {:ok, token, _payload} = mint(user)

    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> post("/rpc", Jason.encode!(request(method, params)))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp request(method, params) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp mint(user) do
    Tokens.mint(
      %{
        "sub" => user.subject,
        "name" => user.display_name,
        "scopes" => Enum.map(Token.scopes_for("owner"), &Atom.to_string/1)
      },
      audience: OIDC.audience()
    )
  end

  defp linked_groups(team), do: Enum.map(Identity.links_of(team), & &1.group.external_id)

  defp session!(team, profile, state) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_subject: "someone@example.test",
        team_id: team.id,
        profile: profile,
        state: state,
        epoch: 1
      })

    session
  end
end
