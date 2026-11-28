defmodule Troupe.Plane.Artifacts.Teams do
  @moduledoc """
  The teams that read an artifact (#1238): one row each in `artifact_teams`, kept by
  artifact and not by version, so every version is read by the same teams. A team's members
  open it at `view`, read from the identity provider's groups at every request, so a person
  who leaves the team stops reading it at their next click. Who may add a team, and the
  audit of each change, is `Troupe.Plane.Artifacts`'s; this module keeps the rows.
  """

  import Ecto.Query

  alias Troupe.Plane.Artifacts.{Artifact, TeamGrant}
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Repo

  @doc "The ids of the teams that read `artifact`, from its preloaded grants where it has them."
  @spec ids(Artifact.t()) :: [Ecto.UUID.t()]
  def ids(%Artifact{team_grants: grants}) when is_list(grants), do: Enum.map(grants, & &1.team_id)

  def ids(%Artifact{id: id}),
    do: Repo.all(from(g in TeamGrant, where: g.artifact_id == ^id, select: g.team_id))

  @doc "The names of the teams that read `artifact`, sorted."
  @spec names(Artifact.t()) :: [String.t()]
  def names(%Artifact{team_grants: grants}) when is_list(grants) do
    if Enum.all?(grants, &match?(%Team{}, &1.team)),
      do: grants |> Enum.map(& &1.team.name) |> Enum.sort(),
      else: grants |> Repo.preload(:team) |> Enum.map(& &1.team.name) |> Enum.sort()
  end

  def names(%Artifact{id: id}) do
    Repo.all(
      from(g in TeamGrant,
        join: t in Team,
        on: t.id == g.team_id,
        where: g.artifact_id == ^id,
        order_by: t.name,
        select: t.name
      )
    )
  end

  @doc "The teams that read `artifact`, each `{name, granted_by, at}`: for its owners."
  @spec list(Artifact.t()) :: [map()]
  def list(%Artifact{id: id}) do
    from(g in TeamGrant, where: g.artifact_id == ^id, preload: :team)
    |> Repo.all()
    |> Enum.map(&%{"name" => &1.team.name, "granted_by" => &1.granted_by, "at" => &1.inserted_at})
    |> Enum.sort_by(& &1["name"])
  end

  @doc "The ids of the artifacts any of `team_ids` reads, as a query."
  @spec reading([Ecto.UUID.t()]) :: Ecto.Query.t()
  def reading(team_ids),
    do: from(g in TeamGrant, where: g.team_id in ^team_ids, select: g.artifact_id)

  @doc "The ids of the artifacts any of the teams named `names` reads, as a query."
  @spec read_by([String.t()]) :: Ecto.Query.t()
  def read_by(names) do
    from(g in TeamGrant,
      join: t in Team,
      on: t.id == g.team_id,
      where: t.name in ^names,
      select: g.artifact_id
    )
  end

  @doc "The ids of the artifacts any team reads, as a query."
  @spec any() :: Ecto.Query.t()
  def any, do: from(g in TeamGrant, select: g.artifact_id)

  @doc "Add `teams` to who reads artifact `id`, as `by`; a team already there is left as it was."
  @spec add(String.t(), [Team.t()], String.t()) :: :ok
  def add(_id, [], _by), do: :ok

  def add(id, teams, by) do
    now = DateTime.utc_now()

    Repo.insert_all(
      TeamGrant,
      Enum.map(
        teams,
        &%{artifact_id: id, team_id: &1.id, granted_by: by, inserted_at: now, updated_at: now}
      ),
      on_conflict: :nothing,
      conflict_target: [:artifact_id, :team_id]
    )

    :ok
  end

  @doc "Take `teams` off who reads artifact `id`."
  @spec remove(String.t(), [Team.t()]) :: :ok
  def remove(_id, []), do: :ok

  def remove(id, teams) do
    ids = Enum.map(teams, & &1.id)
    Repo.delete_all(from(g in TeamGrant, where: g.artifact_id == ^id and g.team_id in ^ids))
    :ok
  end
end
