defmodule Troupe.Plane.Repo.Migrations.SessionShares do
  @moduledoc """
  A capability over a session: a link that carries a role rather than a name.

  The ACL answers "who is allowed here", by subject, and it is the right answer whenever
  the person has an account. A share answers the other question people actually ask —
  *send them this* — and the two are different enough that folding one into the other
  would break both: an ACL entry for a person who has never signed in is a row waiting for
  a subject that may never arrive, and a capability with no expiry is an ACL entry nobody
  remembers granting.

  Three things are in the table and not in the ACL, and each is why this exists:

    * **It expires.** `expires_at` is required. A share with no end is a share that
      outlives the reason it was made.
    * **It is revocable on its own.** `revoked_at` ends this capability and nothing else,
      where removing somebody from the ACL ends every route they had.
    * **It is a secret, kept as a digest.** Salt and SHA-256, the same shape trigger keys
      use, so a dump of this table is not a set of working links.

  `role` is `observe` or `control` and the check is here as well as in the code, because a
  capability that could administer a session could mint further capabilities, and a link
  that can mint links is a link nobody can reason about.
  """

  use Ecto.Migration

  def change do
    create table(:session_shares, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false)
      add(:role, :string, null: false)

      # Salted, so two shares with the same secret — which cannot happen, but the reasoning
      # should not depend on that — do not have the same digest.
      add(:secret_hash, :string, null: false)
      add(:secret_salt, :string, null: false)

      add(:created_by, :string, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      # Who it is for, where somebody said. A share meant for one person is refused to
      # anybody else at redemption; a share with no audience is a link, and says so.
      add(:audience, :string)

      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_by, :string)
      add(:revoked_reason, :string)

      # What it has actually been used for, which is the question somebody asks before
      # revoking one: has anybody opened this, and when did they last.
      add(:redeemed_count, :integer, null: false, default: 0)
      add(:last_redeemed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:session_shares, [:session_id]))
    # Redemption looks a share up by its digest and nothing else, so the digest is what
    # carries the index and what must be unique.
    create(unique_index(:session_shares, [:secret_hash]))

    create(
      constraint(:session_shares, :session_shares_role,
        check: "role in ('observe', 'control')"
      )
    )
  end
end
