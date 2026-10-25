defmodule Troupe.Plane.Repo.Migrations.RemoteSessionsPrivate do
  @moduledoc """
  A private session offered for steering, with its owner's consent (#765).

  `remote_sessions.private` says the offer is of a private session: while it is offered the
  relay carries what it says through the plane unsealed, and only the people invited into
  it with `control` steer it. The row still holds nothing the session says.
  """

  use Ecto.Migration

  def change do
    alter table(:remote_sessions) do
      add :private, :boolean, null: false, default: false
    end
  end
end
