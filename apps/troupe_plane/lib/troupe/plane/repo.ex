defmodule Troupe.Plane.Repo do
  @moduledoc """
  The plane's database.

  PostgreSQL holds the organisational state: who exists, which teams they are in, what
  those teams may use, what it has cost, and an index of the sessions that exist. It
  holds no session content, and a test asserts that — a marker string sent as session
  input must never appear in a dump of this database.

  It is not a source of truth about infrastructure either. What runs where lives in
  Kubernetes, and the session index here can be rebuilt from object storage, which
  `troupe admin index rebuild` does.
  """

  use Ecto.Repo, otp_app: :troupe_plane, adapter: Ecto.Adapters.Postgres
end
