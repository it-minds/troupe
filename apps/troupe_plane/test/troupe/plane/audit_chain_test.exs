defmodule Troupe.Plane.AuditChainTest do
  @moduledoc """
  The audit trail says whether it has been altered.

  The claim is a negative one and the only way to check it is to do the thing: write a
  trail through the ordinary path, change one byte in one row with SQL — behind the
  application, the way somebody with database access would — and ask.

  A table of rows is exactly as trustworthy as the database it is in. Before there was a
  chain, changing what a record said happened left nothing to notice it with, and a trail
  that answers only the easy questions is not evidence of anything.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Repo}

  @moduletag timeout: 60_000

  defp trail do
    {:ok, one} = Audit.record("ada@example.test", "setting.put", "pins_allowed", %{"a" => 1})
    {:ok, two} = Audit.record("ada@example.test", "team.grant", "delivery", %{"b" => 2})
    {:ok, three} = Audit.record("grace@example.test", "team.revoke", "delivery", %{"c" => 3})
    [one, two, three]
  end

  describe "a trail written through the ordinary path" do
    test "chains every row, and each link is a function of the row's own content" do
      [one, two, three] = trail()

      # The first row points at nothing, which is what starting a chain looks like.
      assert is_nil(one.prev_hash)
      assert two.prev_hash == one.hash
      assert three.prev_hash == two.hash

      assert String.starts_with?(one.hash, "sha256:")
      assert one.hash != two.hash
    end

    test "and verifies" do
      trail()

      assert %{result: :ok, checked: 3, unchained: 0} = Audit.verify()
    end
  end

  describe "one byte, changed behind the application" do
    test "is named: the row, the actor, and what it claims against what it hashes to" do
      [_one, two, _three] = trail()

      # Exactly what somebody with a psql prompt would do, and the smallest version of it:
      # one character of one field, leaving every other column and the row's own hash
      # alone.
      {:ok, _} =
        Repo.query(
          "UPDATE audit_events SET subject_id = $1 WHERE id = $2",
          ["deIivery", Ecto.UUID.dump!(two.id)]
        )

      assert %{result: {:error, bad}, checked: 3} = Audit.verify()

      assert bad.id == two.id
      assert bad.reason == :altered
      assert bad.actor == "ada@example.test"
      assert bad.action == "team.grant"

      # Both halves, because "does not verify" without them is a sentence nobody can act
      # on: what the row says its digest is, and what its content actually comes to.
      assert bad.recorded_hash == two.hash
      assert bad.computed_hash != two.hash
    end

    test "and a row removed from the middle is a different answer from a row rewritten" do
      [_one, two, _three] = trail()

      {:ok, _} =
        Repo.query("DELETE FROM audit_events WHERE id = $1", [Ecto.UUID.dump!(two.id)])

      assert %{result: {:error, bad}, checked: 2} = Audit.verify()

      # The row *after* the hole is the one that cannot be explained — its predecessor is
      # not the one that was there. Reported apart from `:altered` because the repairs are
      # different: one row was rewritten, or one is missing.
      assert bad.reason == :chain_broken
      assert bad.action == "team.revoke"
    end
  end

  describe "rows written before the chain existed" do
    test "are counted as unchained rather than reported as bad" do
      # What an upgrade leaves behind. Rewriting these with hashes computed now would be a
      # trail claiming to be verified back to a row nothing verified, which is worse than
      # saying how far back the chain actually reaches.
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO audit_events
            (id, actor, on_behalf_of, action, subject_kind, subject_id, detail,
             occurred_at, inserted_at, updated_at)
          VALUES ($1, 'old@example.test', 'old@example.test', 'team.enable', 'team',
                  'delivery', '{}', $2, $2, $2)
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), ~U[2020-01-01 00:00:00.000000Z]]
        )

      trail()

      assert %{result: :ok, checked: 3, unchained: 1, from: from} = Audit.verify()

      # And the answer says where the chain begins, so "verified" has a beginning somebody
      # can see rather than being a word about the whole table.
      refute is_nil(from)
      assert DateTime.compare(from, ~U[2020-01-01 00:00:00.000000Z]) == :gt
    end
  end
end
