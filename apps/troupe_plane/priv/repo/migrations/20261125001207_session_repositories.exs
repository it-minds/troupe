defmodule Troupe.Plane.Repo.Migrations.SessionRepositories do
  @moduledoc """
  Every GitHub repository a session holds (#1207): the one it was created on first, then
  each attached since, each `{owner, name, ref, path, github, attached_by, attached_at}`,
  `path` its directory in the workspace and `github` what the session did there. The
  `repository` and `github` columns stay, as the first entry's, for a client and a pod
  from before the list.

  A row from before the column holds its one repository at the workspace's root, as it
  was cloned, so it is written as a list of that one with `path: "."` and its record.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add(:repositories, {:array, :map}, null: false, default: [])
    end

    flush()

    execute("""
    UPDATE sessions
       SET repositories = ARRAY[
             repository
             || jsonb_build_object('path', '.')
             || jsonb_build_object('github', COALESCE(github, '{}'::jsonb))
           ]
     WHERE repository IS NOT NULL
    """)
  end

  def down do
    alter table(:sessions) do
      remove(:repositories)
    end
  end
end
