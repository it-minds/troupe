defmodule Troupe.Plane.Repo.Migrations.GithubRun do
  @moduledoc """
  What a session did on GitHub (#147 slice 2): `sessions.github`.

  The commit its clone started from, the `troupe/*` branch it pushes to, its last commit
  there and that commit's tree, its draft pull request, and the CI rounds on it, with the
  moment it stopped after three red ones. Written by the pod that holds the session, over
  the control channel, and read by every listing of the session and of the run it is.
  Metadata only: never a commit message, a pull request's text or CI's output. Null for
  every session that has done nothing there.
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add(:github, :map)
    end
  end
end
