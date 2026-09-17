defmodule Troupe.Plane.Repo.Migrations.PrincipalSponsors do
  @moduledoc """
  Somebody answerable for what a principal does.

  A service principal is a credential that starts sessions, spends a budget and calls
  other people's systems, and until now nothing named a human who stood behind it. That
  is the attribute worth taking from Entra Agent ID — not its object model, which is four
  types where Troupe needs one, but the field that makes an automated run have an owner
  who can be asked about it.

  The sponsor is a person, by subject rather than by row id: a subject survives an
  identity provider re-creating a user, and it is what every other reference to a person
  in this database already uses. It is required for anything created from here on, and
  nullable in the column because rows already exist — a principal with no sponsor is
  reported as *needing* one rather than deleted, because deleting it would take its
  sessions' owner with it.
  """

  use Ecto.Migration

  def change do
    alter table(:service_principals) do
      add :sponsor_subject, :string
      # Why it stopped, which is not the same question as whether it stopped. A principal
      # disabled because its sponsor left is a name somebody has to put in a field; one
      # disabled by an admin is a decision. Reporting both as "disabled" is how an
      # afternoon goes missing.
      add :disabled_reason, :string
    end

    # Finding every principal a departing person sponsors is what SCIM does on each push,
    # so it is a lookup by sponsor and not by principal.
    create index(:service_principals, [:sponsor_subject])
  end
end
