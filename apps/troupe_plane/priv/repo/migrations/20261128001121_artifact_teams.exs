defmodule Troupe.Plane.Repo.Migrations.ArtifactTeams do
  @moduledoc """
  An artifact's readers are a set (#1238): its owner, the teams in `artifact_teams`, the
  people in `artifact_people`, the organisation when `visibility` is `organisation`, and its
  links. One row per team that reads it: who added the team and when. Removing the team or
  the artifact removes the row; there is nothing to keep of a grant whose team is gone.

  `visibility` was one audience, `private`, `organisation`, `team:<name>` or
  `profile:<name>`; it is now `private` or `organisation` alone. Each row of the old two
  forms is turned into the set here (`convert/1`), so nobody who read one stops reading it:

  - `team:<name>` is that team in the set, then `private`; a team no longer there gave
    nobody access, and leaves the set empty.
  - `profile:<name>` is every team granted that profile now, then `private`; a profile no
    team is granted gave nobody access either, and its artifacts are left private, the
    count logged.

  The conversions are not audited: they change who is named for an artifact, not who reads
  it, and the migration's log line counts them. A plane from before it reads a converted row
  as private, its owner's and its links' alone, so a rollback narrows who reads those
  artifacts until the plane is upgraded again; `down` drops the table and leaves the rows
  private.
  """

  use Ecto.Migration

  require Logger

  @by "migration:artifact_teams"

  def up do
    create table(:artifact_teams, primary_key: false) do
      add(:artifact_id, references(:artifacts, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:team_id, references(:teams, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:granted_by, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:artifact_teams, [:team_id]))

    flush()

    counts = convert(repo())
    Logger.info("troupe plane: artifact readers made a set: #{inspect(counts)}")
  end

  def down do
    drop(table(:artifact_teams))
  end

  @doc """
  Turn every `team:<name>` and `profile:<name>` visibility into rows of `artifact_teams`
  and `private`, and say how many of each there were and how many profiles granted no team.

  Public so a test can run it on rows seeded in the old shape; the migration is its one
  caller in production.
  """
  @spec convert(module()) :: map()
  def convert(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT id, visibility FROM artifacts WHERE visibility LIKE 'team:%' OR visibility LIKE 'profile:%'"
      )

    Enum.reduce(rows, %{"team" => 0, "profile" => 0, "no_team" => 0}, &convert_one(repo, &1, &2))
  end

  defp convert_one(repo, [id, visibility], counts) do
    teams = teams_of(repo, visibility)
    Enum.each(teams, &grant(repo, id, &1))
    repo.query!("UPDATE artifacts SET visibility = 'private' WHERE id = $1", [id])

    counts
    |> Map.update!(kind(visibility), &(&1 + 1))
    |> Map.update!("no_team", &if(teams == [], do: &1 + 1, else: &1))
  end

  defp kind("team:" <> _name), do: "team"
  defp kind("profile:" <> _name), do: "profile"

  # The ids of the teams the old audience named: the one team, or every team granted the
  # profile, as `Identity.grants_for_profile/1` has them now.
  defp teams_of(repo, "team:" <> name),
    do: repo.query!("SELECT id FROM teams WHERE name = $1", [name]).rows |> Enum.map(&hd/1)

  defp teams_of(repo, "profile:" <> name),
    do:
      repo.query!("SELECT DISTINCT team_id FROM grants WHERE profile = $1", [name]).rows
      |> Enum.map(&hd/1)

  defp grant(repo, artifact_id, team_id) do
    repo.query!(
      "INSERT INTO artifact_teams (artifact_id, team_id, granted_by, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, now(), now()) ON CONFLICT DO NOTHING",
      [artifact_id, team_id, @by]
    )
  end
end
