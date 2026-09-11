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

  alias Troupe.Plane.{Admin, Fleet, Identity, OIDC, Sessions, Tokens}
  alias Troupe.Plane.Admin.API
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
