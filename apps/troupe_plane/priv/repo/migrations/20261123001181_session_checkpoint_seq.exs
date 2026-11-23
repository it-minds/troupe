defmodule Troupe.Plane.Repo.Migrations.SessionCheckpointSeq do
  @moduledoc """
  The latest `checkpoint` a session's sealer reported sealed (#1181): the seq a reader of
  the session may start from, kept beside `last_seq`. A row from before the column, and a
  session that never compacted, has none.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:checkpoint_seq, :integer)
    end
  end
end
