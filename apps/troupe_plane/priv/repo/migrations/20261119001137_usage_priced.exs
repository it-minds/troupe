defmodule Troupe.Plane.Repo.Migrations.UsagePriced do
  @moduledoc """
  Whether a model call was priced (#1137): a call nobody said the cost of is charged zero,
  as a free one is, and only this column tells the two apart. A row from before the column
  was charged as priced, and reads as priced.
  """

  use Ecto.Migration

  def change do
    alter table(:usage_records) do
      add(:priced, :boolean, null: false, default: true)
    end
  end
end
