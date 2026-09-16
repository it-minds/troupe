defmodule Troupe.Plane.SharesTest do
  @moduledoc """
  A capability over a session: a link that carries a role rather than a name.

  The ACL already answers *who is allowed here*, by subject. This is the other half of
  what people mean by sharing — *send them this* — and the reason it is a separate thing
  is in the three properties an ACL entry does not have: it ends, it is revocable on its
  own, and it is a secret the plane keeps only a digest of.

  The property to watch is **refused at mint, never at use**. Everything about what the
  capability may carry is settled when it is made; redemption asks only what is true of the
  share itself. A link that re-derived its authority from the sharer would stop working
  when they changed teams, and what a recipient can see would depend on something they
  cannot see.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Fleet, Harness, Identity, Sessions}
  alias Troupe.Plane.Sessions.Share

  @moduletag timeout: 60_000

  setup do
    start_supervised!(Troupe.Plane.Singleton)
    :ok
  end

  describe "minting" do
    test "hands back the secret once, and keeps only a digest of it" do
      %{ada: ada, session: session} = a_session(members_may_control: true)

      assert {:ok, share} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "observe"},
                 context(ada)
               )

      secret = share["secret"]
      assert String.starts_with?(secret, "tsh_")
      assert share["role"] == "observe"
      assert share["state"] == "live"
      assert share["created_by"] == ada.subject
      assert share["redeemed_count"] == 0

      # The row is not the link. Whoever minted it has the secret now or mints another,
      # and a dump of this table is not a set of working links.
      row = Sessions.get_share(share["id"])
      refute row.secret_hash == secret
      refute inspect(Map.from_struct(row)) =~ secret

      # And a listing never carries it either.
      assert {:ok, listed} =
               Harness.call("session.shares", %{"session_id" => session.id}, context(ada))

      refute listed |> inspect() =~ secret
    end

    test "is never admin, whoever mints it" do
      %{ada: ada, session: session} = a_session(members_may_control: true)

      # ada owns it, so she holds `admin` — and it still cannot be shared. A capability
      # that could administer a session could mint further capabilities.
      assert Sessions.role_for(ada, session) == :admin

      assert {:error, error} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "admin"},
                 context(ada)
               )

      assert error.message == "forbidden"
      assert error.data.reason =~ "may not administer"
      assert Share.roles() == ~w(observe control)
    end

    test "needs control of the session, not a view of it" do
      %{bea: bea, session: session} = a_session(members_may_control: false)

      # bea sees the session through her team and may only watch. Minting a link would be
      # handing on a view she was given, which is the one thing an observe grant is not.
      assert Sessions.role_for(bea, session) == :observe

      assert {:error, error} =
               Harness.call("session.share", %{"session_id" => session.id}, context(bea))

      assert error.message == "forbidden"
      assert error.data.reason =~ "control"
    end

    test "is bounded by the team's ACL, through the ladder" do
      %{ada: ada, session: session, team: team} = a_session(members_may_control: false)

      # The team says its members may not steer. A link that let somebody steer would be a
      # way round the setting rather than an exception to it.
      assert {:error, error} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "control"},
                 context(ada)
               )

      assert error.data.reason =~ "may not steer"

      # Observe is fine, because that is what the team allows.
      assert {:ok, _} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "observe"},
                 context(ada)
               )

      # And turning it on makes control shareable at the next request, not the next edit.
      {:ok, _} = Identity.update_team(team, %{members_may_control: true})

      assert {:ok, control} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "control"},
                 context(ada)
               )

      assert control["role"] == "control"
    end

    test "always ends, and not too far away" do
      %{ada: ada, session: session} = a_session(members_may_control: true)

      # The default is a week, because a share with no end is an ACL entry nobody
      # remembers granting.
      assert {:ok, default} =
               Harness.call("session.share", %{"session_id" => session.id}, context(ada))

      {:ok, expires, _} = DateTime.from_iso8601(default["expires_at"])
      days = DateTime.diff(expires, DateTime.utc_now(), :day)
      assert days in 6..7

      assert {:error, error} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "expires_in_seconds" => 365 * 24 * 3600},
                 context(ada)
               )

      assert error.data.max_seconds == 30 * 24 * 3600
    end
  end

  describe "redeeming" do
    test "becomes an ordinary session token at the share's role" do
      %{ada: ada, bea: bea, session: session} = a_session(members_may_control: true)

      {:ok, share} =
        Harness.call(
          "session.share",
          %{"session_id" => session.id, "role" => "control"},
          context(ada)
        )

      assert {:ok, redeemed} =
               Harness.call("session.redeem", %{"secret" => share["secret"]}, context(bea))

      # Nothing special about what comes back: the same shape `token.mint` gives, at the
      # role the link carries. A share is a way in, not a second kind of session.
      assert redeemed["session_id"] == session.id
      assert redeemed["role"] == "collaborator"

      # And the share now says it has been used, which is the question somebody asks
      # before revoking one.
      row = Sessions.get_share(share["id"])
      assert row.redeemed_count == 1
      refute is_nil(row.last_redeemed_at)
    end

    test "does not re-ask what the sharer may do today" do
      %{ada: ada, bea: bea, session: session, team: team} = a_session(members_may_control: true)

      {:ok, share} =
        Harness.call(
          "session.share",
          %{"session_id" => session.id, "role" => "control"},
          context(ada)
        )

      # ada leaves. The link she sent is a decision that was made, not a standing claim
      # about her — one that quietly stopped working here would be a link whose behaviour
      # depended on something the recipient cannot see.
      {:ok, _} = Identity.set_memberships(ada, [])

      assert {:ok, redeemed} =
               Harness.call("session.redeem", %{"secret" => share["secret"]}, context(bea))

      assert redeemed["role"] == "collaborator"

      # Same for the team setting: it bounded the mint and does not bound the use.
      {:ok, _} = Identity.update_team(team, %{members_may_control: false})

      assert {:ok, still} =
               Harness.call("session.redeem", %{"secret" => share["secret"]}, context(bea))

      assert still["role"] == "collaborator"
    end

    test "says which kind of no it is" do
      %{ada: ada, bea: bea, session: session} = a_session(members_may_control: true)

      assert {:error, missing} =
               Harness.call("session.redeem", %{"secret" => "tsh_nope.nothing"}, context(bea))

      assert missing.message == "not_found"

      {:ok, expiring} =
        Harness.call(
          "session.share",
          %{"session_id" => session.id, "expires_in_seconds" => 60},
          context(ada)
        )

      # Backdated rather than waited for. What matters is the comparison, not the clock.
      {:ok, _} =
        Sessions.get_share(expiring["id"])
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
        |> Repo.update()

      assert {:error, expired} =
               Harness.call("session.redeem", %{"secret" => expiring["secret"]}, context(bea))

      assert expired.data.reason =~ "expired"

      {:ok, made_out} =
        Harness.call(
          "session.share",
          %{"session_id" => session.id, "audience" => "cyd@example.test"},
          context(ada)
        )

      assert {:error, not_theirs} =
               Harness.call("session.redeem", %{"secret" => made_out["secret"]}, context(bea))

      assert not_theirs.data.reason =~ "somebody else"
    end

    test "the id alone opens nothing" do
      %{ada: ada, bea: bea, session: session} = a_session(members_may_control: true)

      {:ok, share} =
        Harness.call("session.share", %{"session_id" => session.id}, context(ada))

      # The id is public — it is in `share_created` and in every listing — and the half
      # after the dot is the part that has to be right.
      forged = "tsh_" <> String.replace_prefix(share["id"], "shr_", "") <> ".guess"

      assert {:error, error} =
               Harness.call("session.redeem", %{"secret" => forged}, context(bea))

      assert error.message == "not_found"
    end
  end

  describe "revoking" do
    test "ends this link and nothing else" do
      %{ada: ada, bea: bea, session: session} = a_session(members_may_control: true)

      {:ok, one} = Harness.call("session.share", %{"session_id" => session.id}, context(ada))
      {:ok, two} = Harness.call("session.share", %{"session_id" => session.id}, context(ada))

      assert {:ok, revoked} =
               Harness.call(
                 "session.share.revoke",
                 %{"session_id" => session.id, "share" => one["id"], "reason" => "wrong chat"},
                 context(ada)
               )

      assert revoked["state"] == "revoked"
      assert revoked["revoked_by"] == ada.subject

      assert {:error, error} =
               Harness.call("session.redeem", %{"secret" => one["secret"]}, context(bea))

      assert error.data.reason =~ "revoked"

      # The other link is untouched, and so is bea's own route in through her team. This
      # is the difference from removing somebody from the ACL, which ends every way they
      # had in at once.
      assert {:ok, _} = Harness.call("session.redeem", %{"secret" => two["secret"]}, context(bea))
      assert Sessions.role_for(bea, session) == :control
    end

    test "twice keeps the first revocation" do
      %{ada: ada, session: session} = a_session(members_may_control: true)
      {:ok, share} = Harness.call("session.share", %{"session_id" => session.id}, context(ada))

      {:ok, first} =
        Harness.call(
          "session.share.revoke",
          %{"session_id" => session.id, "share" => share["id"]},
          context(ada)
        )

      {:ok, again} =
        Harness.call(
          "session.share.revoke",
          %{"session_id" => session.id, "share" => share["id"], "reason" => "making sure"},
          context(ada)
        )

      # When it stopped working is a fact. The second attempt is somebody making sure.
      assert again["revoked_at"] == first["revoked_at"]
      assert is_nil(Sessions.get_share(share["id"]).revoked_reason)
    end

    test "a listing shows the ones that already stopped working" do
      %{ada: ada, session: session} = a_session(members_may_control: true)

      {:ok, live} = Harness.call("session.share", %{"session_id" => session.id}, context(ada))
      {:ok, dead} = Harness.call("session.share", %{"session_id" => session.id}, context(ada))

      {:ok, _} =
        Harness.call(
          "session.share.revoke",
          %{"session_id" => session.id, "share" => dead["id"]},
          context(ada)
        )

      assert {:ok, %{"shares" => shares}} =
               Harness.call("session.shares", %{"session_id" => session.id}, context(ada))

      by_id = Map.new(shares, &{&1["id"], &1})
      assert by_id[live["id"]]["state"] == "live"
      # Somebody deciding which link to revoke needs to see the ones already gone, or they
      # revoke the wrong one.
      assert by_id[dead["id"]]["state"] == "revoked"
    end
  end

  defp a_session(opts) do
    team =
      team_with_grant("engineering", "dev",
        name: "engineering",
        budget_micros: 0
      )

    {:ok, team} = Identity.update_team(team, Map.new(opts))

    ada = person("ada@example.test", ["engineering"])
    bea = person("bea@example.test", ["engineering"])

    {:ok, session} =
      Sessions.create(%{
        id: "s-" <> to_string(System.unique_integer([:positive])),
        owner_id: ada.id,
        owner_subject: ada.subject,
        team_id: team.id,
        profile: "dev",
        kind: "team",
        visibility: "team",
        state: "active",
        epoch: 1
      })

    # Redeeming hands back an endpoint, which means the session has to be somewhere. A
    # share is a way in to a running session, not a way to start one.
    {:ok, worker} =
      Fleet.enrol(%{
        profile: "dev",
        namespace: "troupe-w-dev",
        pod_name: "troupe-w-dev-0",
        ordinal: 0,
        endpoint: "https://0.dev.workers.example.test",
        capacity: 4,
        disk_total_bytes: 1_000_000
      })

    {:ok, session} = Sessions.place(session.id, worker)

    %{team: team, ada: ada, bea: bea, session: session, worker: worker}
  end

  defp context(user), do: %{user: user, platform_admin?: false}
end
