defmodule Troupe.Plane.SponsorsTest do
  @moduledoc """
  Somebody answerable for what a principal does.

  A service principal starts sessions, spends a budget and calls other people's systems
  with a credential a team owns. Until it named a sponsor, an automated run at four in
  the morning had nobody to ask about it — and the person who set it up might have left
  a year ago.

  The requirement is only worth having if it is enforced at both ends: nothing can be
  created without a sponsor the provider actually knows, and nothing keeps firing once
  that person is gone. The second half is the one that decays quietly, so it is proven
  through SCIM rather than by calling the disable path directly.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Principals, SCIM}
  alias Troupe.Plane.Identity.ServicePrincipal

  setup do
    team = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])
    %{team: team, ada: ada}
  end

  describe "creating one" do
    test "needs a sponsor", context do
      assert {:error, :no_sponsor} =
               Principals.create(context.team, %{name: "nightly", profiles: ["dev"]}, "root")

      assert Principals.list(context.team) == []
    end

    test "needs a sponsor the identity provider knows", context do
      assert {:error, {:no_such_sponsor, "ghost@example.test"}} =
               Principals.create(
                 context.team,
                 %{name: "nightly", profiles: ["dev"], sponsor: "ghost@example.test"},
                 "root"
               )
    end

    test "needs a sponsor who is in the team", context do
      # A person the provider knows, in another team entirely. Answerable is not a claim
      # anybody can make about anybody: a sponsor has to be somebody who could have
      # started the work themselves.
      _design = team_with_grant("design", "ux", name: "design")
      grace = person("grace@example.test", ["design"])

      assert {:error, {:sponsor_not_in_team, subject, "engineering"}} =
               Principals.create(
                 context.team,
                 %{name: "nightly", profiles: ["dev"], sponsor: grace.subject},
                 "root"
               )

      assert subject == grace.subject
    end

    test "needs a sponsor who has not already left", context do
      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      assert {:error, {:sponsor_inactive, _}} =
               Principals.create(
                 context.team,
                 %{name: "nightly", profiles: ["dev"], sponsor: context.ada.subject},
                 "root"
               )
    end

    test "records the sponsor and reports it", context do
      {:ok, principal, _secret} =
        Principals.create(
          context.team,
          %{name: "nightly", profiles: ["dev"], sponsor: context.ada.subject},
          "root"
        )

      assert principal.sponsor_subject == context.ada.subject
      assert ServicePrincipal.state(principal) == :enabled
    end
  end

  describe "when the sponsor leaves" do
    setup context do
      {:ok, principal, _secret} =
        Principals.create(
          context.team,
          %{name: "nightly", profiles: ["dev"], sponsor: context.ada.subject},
          "root"
        )

      %{principal: principal}
    end

    test "every principal they sponsored stops, within the push", context do
      # Through SCIM, not by calling the disable path: what has to be true is that the
      # provider removing somebody is enough, and a test that called `sponsor_left/1`
      # itself would pass on a plane where nothing ever calls it.
      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      stopped = Principals.get(context.principal.subject)
      refute ServicePrincipal.enabled?(stopped)
    end

    test "and the reason is that it needs one, not that it is broken", context do
      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      stopped = Principals.get(context.principal.subject)

      # The distinction a console lives on. One of these is a field for somebody to fill
      # in; the other is a decision somebody made. A list that showed both as "disabled"
      # would send people looking for a fault that is not there.
      assert ServicePrincipal.state(stopped) == :needs_sponsor
      assert stopped.disabled_reason == ServicePrincipal.sponsor_left()
    end

    test "a principal somebody disabled by hand still reads as disabled", context do
      {:ok, _} = Principals.disable(context.principal)

      assert ServicePrincipal.state(Principals.get(context.principal.subject)) == :disabled
    end

    test "a principal whose sponsor is someone else is untouched", context do
      bea = person("bea@example.test", ["engineering"])

      {:ok, other, _} =
        Principals.create(
          context.team,
          %{name: "weekly", profiles: ["dev"], sponsor: bea.subject},
          "root"
        )

      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      assert ServicePrincipal.enabled?(Principals.get(other.subject))
    end
  end

  describe "the admin surface" do
    setup do
      # Before the actor is resolved, not after: `actor_for/1` reads the group then and
      # there, so setting it afterwards makes a platform admin who is not one.
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)
      %{actor: Admin.actor_for(person("root@example.test", ["platform"]))}
    end

    test "refuses a create with no sponsor, and says which field", context do
      actor = context.actor

      assert {:error, error} =
               Admin.principal_create(actor, context.team.name, %{
                 "name" => "nightly",
                 "profiles" => ["dev"]
               })

      assert error.message == "invalid_params"
      assert error.data.missing == "sponsor"
    end

    test "reports the sponsor and the state", context do
      actor = context.actor

      assert {:ok, created} =
               Admin.principal_create(actor, context.team.name, %{
                 "name" => "nightly",
                 "profiles" => ["dev"],
                 "sponsor" => context.ada.subject
               })

      assert created.sponsor == context.ada.subject
      assert created.state == :enabled

      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      assert {:ok, listed} = Admin.principals_list(actor, context.team.name)
      assert Enum.find(listed, &(&1.subject == created.subject)).state == :needs_sponsor
    end
  end
end
