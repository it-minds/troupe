defmodule Troupe.Plane.Repo.Migrations.ScimUserName do
  @moduledoc """
  SCIM's `userName`, kept beside the subject.

  A provisioning client asks `userName eq "<value>"` before it creates or changes
  somebody. Where the provider sends an `externalId`, which is the subject (Decision 751),
  the `userName` it asks about was kept nowhere, so the plane answered "nobody" about a
  person it had (Decision 754). The filter reads it case folded, and the subject for a row
  no push has named, which is what the first index is on; the second is for a filter on
  `externalId`.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:user_name, :string)
    end

    create(
      index(:users, ["lower(coalesce(user_name, subject))"], name: :users_scim_user_name_index)
    )

    create(index(:users, [:external_id]))
  end
end
