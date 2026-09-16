defmodule Troupe.Plane.PrincipalPairTest do
  @moduledoc """
  On whose authority, beside who did it.

  An audit row has always said what made a change. It has not said whose authority the
  change was made under, and those differ exactly where the interesting things happen: a
  trigger firing as a principal, a delegated call going out with somebody else's
  credential. One value had to pick, and whichever it picked the other was invisible.

  Both halves are written even when they match, which is the part worth a test of its
  own: a column that is null when they are equal is a column a reader cannot interpret a
  year later. Null because they were the same, and null because that day's code did not
  fill it in, look identical.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Principals, Repo}
  alias Troupe.Plane.Audit.Event
  alias Troupe.Protocol.Principal

  setup do
    team = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])

    {:ok, principal, _secret} =
      Principals.create(
        team,
        %{name: "nightly", profiles: ["dev"], sponsor: ada.subject},
        "root"
      )

    %{team: team, ada: ada, principal: principal}
  end

  describe "an audit row" do
    test "names a person as both halves when they act for themselves", context do
      {:ok, _} = Audit.record(context.ada.subject, "session.review", "s-1", %{})

      row = latest()
      assert row.actor == context.ada.subject

      # Written, not left null. This is the assertion the whole design turns on.
      assert row.on_behalf_of == context.ada.subject
    end

    test "names both halves separately when one acts for another", context do
      {:ok, _} =
        Audit.record(context.principal.subject, "trigger.fire", "nightly", %{},
          on_behalf_of: context.ada.subject
        )

      row = latest()
      assert row.actor == context.principal.subject
      assert row.on_behalf_of == context.ada.subject
    end

    test "takes a principal whole, so the halves cannot be swapped", context do
      pair = Principal.of(context.ada.subject, context.principal.subject)
      {:ok, _} = Audit.record(pair, "trigger.fire", "nightly", %{})

      row = latest()

      # A caller that had to take the pair apart and hand the halves over one at a time
      # is a caller that can put them back the wrong way round, and nothing downstream
      # could tell.
      assert row.actor == context.principal.subject
      assert row.on_behalf_of == context.ada.subject
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp latest do
    Repo.one!(from(e in Event, order_by: [desc: e.inserted_at], limit: 1))
  end
end
