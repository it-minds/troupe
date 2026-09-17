defmodule Troupe.Plane.DeactivationTest do
  @moduledoc """
  What stops when the identity provider says somebody has gone.

  SCIM deletes are soft — an audit trail outlives a person's account — so deactivation is
  a flag on a row, and a flag nothing reads is a deprovision that did not happen. Three
  doors, and the third is the one that is easy to miss:

  * signing in, which must not *resurrect* the account it is refusing;
  * the harness, on every call rather than only at sign-in, because a plane token outlives
    the moment it was issued;
  * the control channel, where a pod asks for an assertion to read that person's
    credentials — and needs nobody to sign in at all. That one is in `ControlTest`, with
    the rest of the fake pod.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{FakePod, Harness, Identity, Login, SCIM}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])

    %{port: Listener.port(), team: team, ada: ada}
  end

  describe "the harness" do
    test "answers a person while they are active and refuses them afterwards", context do
      assert {:ok, %{"subject" => subject}} = Harness.call("me", %{}, as(context.ada))
      assert subject == context.ada.subject

      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      # The same token, the same caller, the same method. A person deactivated at ten
      # o'clock holds a valid plane token until it expires, and checking only at sign-in
      # would let every method here go on answering them until it did.
      assert {:error, error} = Harness.call("me", %{}, as(context.ada))
      assert error.message == "forbidden"
      assert error.data.reason == "account deactivated"

      # Including the one that hands out a credential grant, which is the point.
      assert {:error, refused} =
               Harness.call("me.connections.grant", %{"slot" => "jira"}, as(context.ada))

      assert refused.message == "forbidden"
    end
  end

  describe "signing in" do
    test "refuses a deactivated person, and does not reactivate them", context do
      {:ok, _} = SCIM.deactivate_user(context.ada.id)

      claims = %{"sub" => context.ada.subject, "email" => "ada@example.test"}
      assert {:error, :deactivated} = Login.from_claims(claims)

      # The failure mode this replaces: `active: true` was written on every login, so a
      # SCIM deprovision lasted exactly until its subject next authenticated.
      refute Identity.get_user(context.ada.subject).active
    end

    test "still creates somebody nobody has ever deactivated", context do
      claims = %{"sub" => "new@example.test", "email" => "new@example.test"}

      assert {:ok, user, _teams} = Login.from_claims(claims)
      assert user.active

      # And an active person signing in again is unaffected.
      assert {:ok, again, _} =
               Login.from_claims(%{"sub" => context.ada.subject, "email" => "ada@example.test"})

      assert again.active
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}
end
