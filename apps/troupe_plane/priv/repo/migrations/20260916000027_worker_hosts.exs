defmodule Troupe.Plane.Repo.Migrations.WorkerHosts do
  @moduledoc """
  Hosts registered to run a profile's workers outside Kubernetes.

  A host that answers, rather than a host we built. The plane does not create these
  machines and cannot: somebody registers one, gets a secret back once, and installs the
  worker on it however they install things. That is the whole contract, and it is what
  makes the single-developer case work at all — the laptop already exists.

  ## The secret is the enrolment

  A pod proves which profile it is with a `TokenReview`: the namespace decides the profile
  and a pod cannot mint a token from another namespace's ServiceAccount. A host has no
  namespace, so the equivalent is a secret issued to *this host for this profile*, kept
  here as a salted digest — the same shape a trigger key and a session share have, for the
  same reason: a dump of this table is not a set of working credentials.

  The digest is unique, which is what makes a lookup by secret one indexed query rather
  than a scan, and what makes presenting another host's secret land on that host's row and
  be refused for being the wrong host rather than quietly succeeding as it.

  ## No guarantees are recorded here

  What a host does not give you — admission policy, NetworkPolicy, FQDN egress, disruption
  budget — is a property of not being in a cluster, not a column somebody can set. Asking
  the provisioner is the only answer that cannot be edited into a lie.
  """

  use Ecto.Migration

  def change do
    create table(:worker_hosts, primary_key: false) do
      add(:id, :string, primary_key: true)
      # `profiles` is keyed by its name, so the reference says so. A host outlives nothing:
      # deleting the profile deletes its hosts, because a host registered to a profile that
      # is gone is a credential nobody is watching.
      add(
        :profile,
        references(:profiles, column: :name, type: :string, on_delete: :delete_all),
        null: false
      )

      # What an operator calls it, and where a person would ssh to. The address is for a
      # human reading a listing: the plane never dials it, the worker dials the plane.
      add(:name, :string, null: false)
      add(:address, :string)

      # A number of its own, because a worker has one everywhere else: drain takes the
      # highest first, and a host called `build-box` has no trailing integer to read one
      # out of. Assigned at registration and never reused, so draining is in a stable
      # order rather than whatever order a listing came back in.
      add(:ordinal, :integer, null: false)

      add(:secret_hash, :string, null: false)
      add(:secret_salt, :string, null: false)
      add(:secret_rotated_at, :utc_datetime_usec)
      add(:secret_rotated_by, :string)

      add(:registered_by, :string, null: false)
      add(:enabled, :boolean, null: false, default: true)

      # The last enrolment this host made, so a listing can say "registered and never seen"
      # — which is the state somebody debugging an install is actually in.
      add(:last_enrolled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:worker_hosts, [:profile, :name]))
    create(unique_index(:worker_hosts, [:profile, :ordinal]))
    create(unique_index(:worker_hosts, [:secret_hash]))
    create(index(:worker_hosts, [:profile]))
  end
end
