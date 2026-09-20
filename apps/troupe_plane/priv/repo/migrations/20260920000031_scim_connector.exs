defmodule Troupe.Plane.Repo.Migrations.ScimConnector do
  @moduledoc """
  The SCIM connector as a row, so its token can be rotated from the console.

  Until now the provider's credential was `TROUPE_SCIM_TOKEN`: a Kubernetes secret, a
  Helm value and a rollout to change, and nothing anywhere that said when the provider
  last pushed. The tools an operator has already used for this show a connector card —
  base URL, a token you rotate and see once, when it was rotated, when the provider last
  synced, and a switch for whether its groups become teams — and this is the row behind
  that card.

  One row, because a plane has one directory. The token is kept as a salted SHA-256 the
  way a service principal's secret is, and the environment variable stays the floor:
  a plane provisioned before this migration keeps working with no row at all.

  `last_seen_at` is written by the SCIM endpoint on an authorised request, at most once a
  minute, so a provider's full sync is one write and not one per user.
  """

  use Ecto.Migration

  def change do
    create table(:scim_connector, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token_hash, :string)
      add(:token_salt, :string)
      add(:rotated_at, :utc_datetime_usec)
      add(:rotated_by, :string)
      add(:last_seen_at, :utc_datetime_usec)
      add(:last_seen_op, :string)
      add(:teams_from_groups, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
