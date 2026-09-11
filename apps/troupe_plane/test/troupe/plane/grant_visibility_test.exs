defmodule Troupe.Plane.GrantVisibilityTest do
  @moduledoc """
  Granting a team a profile, and how soon a member can use it.

  The done item is about latency and about what has to happen first: the grant shows up
  in the member's fleet on their next token mint and without re-logging in, and the
  profile is `UpgradePending` until its pods restart idle with the team volume mounted.

  Those are two different clocks and it matters that they are. What a person *may* do
  changes the moment the grant is written; what the cluster has *mounted* changes when a
  pod is free to restart. A design that made the first wait for the second would make
  granting access a maintenance window.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Fleet, Harness, Identity, OIDC, Provision, Sessions, Tokens}
  alias Troupe.Protocol.Token

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    # A team with no grants at all, and somebody in it.
    {:ok, engineering_group} = Identity.upsert_group(%{external_id: "engineering", display_name: "engineering"})
    {:ok, engineering} = Identity.enable_team(engineering_group, %{name: "engineering"})
    member = person("ada@example.test", ["engineering"])

    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 2, sessions_per_pod: 4})

    %{root: Admin.actor_for(root), member: member, engineering: engineering}
  end

  test "a granted profile appears on the next mint, with no new login", context do
    # Before: the member is in an enabled team and can see nothing, because a team is not
    # access — a grant is.
    assert {:ok, before} = Harness.call("me", %{}, user_context(context.member))
    assert Enum.map(before["teams"], & &1["name"]) == ["engineering"]
    assert before["profiles"] == []

    {:ok, session} = mint(context.member)
    assert session["profiles"] == []

    # The grant.
    assert {:ok, _} = Admin.team_grant(context.root, "engineering", "dev")

    # After, with the same person and no second login: the fleet they see has changed.
    assert {:ok, now} = Harness.call("me", %{}, user_context(context.member))
    assert now["profiles"] == ["dev"]
    assert Enum.map(now["teams"], & &1["name"]) == ["engineering"]

    assert {:ok, %{"profiles" => [profile]}} =
             Harness.call("profiles.list", %{}, user_context(context.member))

    assert profile["name"] == "dev"

    # And the next token carries it, which is what a client actually reads.
    {:ok, fresh} = mint(context.member)
    assert fresh["profiles"] == ["dev"]
    assert fresh["teams"] == ["engineering"]
  end

  test "the token that was already minted is not retroactively widened", context do
    {:ok, before} = mint(context.member)
    assert {:ok, _} = Admin.team_grant(context.root, "engineering", "dev")

    # The old token still says what it said: a token is a claim about the moment it was
    # minted, and one that changed meaning afterwards would be unauditable.
    {:ok, jwks} = Tokens.jwks()
    assert {:ok, claims} = Token.verify(before["token"], jwks, audience: plane_audience())
    assert claims["teams"] == ["engineering"]

    # What it *can* do is decided per request against the grants as they now stand, which
    # is why widening does not need a new token to take effect.
    assert {:ok, %{"profiles" => ["dev"]}} = Harness.call("me", %{}, user_context(context.member))
  end

  test "the profile carries the team into the cluster as a projection of the grant", context do
    assert {:ok, _} = Admin.team_grant(context.root, "engineering", "dev", %{volume_mode: "rw"})

    manifest = Provision.manifest(Fleet.get_profile("dev"))
    assert [team] = manifest["spec"]["teams"]

    assert team["name"] == "engineering"
    assert team["mode"] == "rw"
    assert team["volume"] == "troupe-team-engineering"
  end

  test "revoking takes it away again, and the sessions with it", context do
    {:ok, _} = Admin.team_grant(context.root, "engineering", "dev")

    {:ok, running} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_subject: context.member.subject,
        team_id: context.engineering.id,
        profile: "dev",
        state: "active",
        epoch: 1
      })

    assert {:ok, _} = Admin.team_revoke(context.root, "engineering", "dev")

    assert {:ok, %{"profiles" => []}} = Harness.call("me", %{}, user_context(context.member))
    assert Sessions.get(running.id).state == "read_only"
    assert Provision.manifest(Fleet.get_profile("dev"))["spec"]["teams"] == []
  end

  defp user_context(user), do: %{user: user, platform_admin?: false}

  defp mint(user) do
    OIDC.exchange("stub", verifier: fn _token -> {:ok, claims_for(user)} end)
  end

  defp claims_for(user) do
    %{"sub" => user.subject, "email" => user.email, "name" => user.display_name, "groups" => ["engineering"]}
  end

  defp plane_audience, do: OIDC.audience()
end
