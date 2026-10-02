defmodule Troupe.Plane.Repo.Migrations.PersonKmsName do
  @moduledoc """
  A person's name at the key manager, which moving them to another claim leaves alone.

  What the key manager keeps for a person, their credentials for person-mode MCP servers
  and their private sessions' data keys, is under `troupe/people/<name>/`, and the name
  was their subject. A person moved to another claim (Decision 751) kept everything the
  plane holds and lost everything there, since the plane cannot reach that subtree to move
  it. The name is now a column of its own, fixed when the person is first known (Decision
  755).

  Filled with each person's subject, so nothing already in the key manager moves and an
  installation that never switches its claim sees no difference. Nullable, because a
  replica of the release before still serving while this one rolls out creates people
  without one; such a row is read as its subject. Unique, because two people with one
  name would share one subtree.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:kms_name, :string)
    end

    execute("UPDATE users SET kms_name = subject")

    create(unique_index(:users, [:kms_name]))
  end

  def down do
    drop(unique_index(:users, [:kms_name]))

    alter table(:users) do
      remove(:kms_name)
    end
  end
end
