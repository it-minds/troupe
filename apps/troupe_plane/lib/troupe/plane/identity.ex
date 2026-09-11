defmodule Troupe.Plane.Identity do
  @moduledoc """
  Who exists, what they belong to, and what that lets them use.

  Two ways in, one result. SCIM pushes users and groups from the identity provider;
  where SCIM is off, the same rows are created just in time from the `groups` claim at
  login. A done item requires both paths to yield the same teams, which is why they end
  in the same three functions rather than two parallel implementations.

  Nothing here edits membership. A group's members are the IdP's, and the only thing
  Troupe adds is *enabling* a group as a team. Two places to grant access would be one
  place too many to revoke it.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Troupe.Plane.Identity.{Grant, Group, Membership, Team, TeamAdmin, User}
  alias Troupe.Plane.{Repo, Sessions}

  require Logger

  # -- users and groups -------------------------------------------------------

  @doc """
  Create or update a user by subject.

  Idempotent, because both SCIM and login call it and neither knows what the other has
  done.
  """
  @spec upsert_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def upsert_user(%{subject: subject} = attrs) do
    case Repo.get_by(User, subject: subject) do
      nil -> %User{}
      user -> user
    end
    |> User.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Create or update a group by its identity-provider id."
  @spec upsert_group(map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def upsert_group(%{external_id: external_id} = attrs) do
    case Repo.get_by(Group, external_id: external_id) do
      nil -> %Group{}
      group -> group
    end
    |> Group.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Replace a user's group membership with exactly this list.

  Replace, not merge. A login carries the whole `groups` claim and a SCIM push carries
  the whole member list, so a group that is *absent* is a group the user has left — and
  merging would mean access outliving the IdP's decision to remove it.
  """
  @spec set_memberships(User.t(), [String.t()]) :: {:ok, [Group.t()]} | {:error, term()}
  def set_memberships(%User{} = user, external_ids) do
    groups = Repo.all(from g in Group, where: g.external_id in ^external_ids)
    wanted = MapSet.new(groups, & &1.id)
    current = Repo.all(from m in Membership, where: m.user_id == ^user.id)

    Multi.new()
    |> Multi.delete_all(
      :removed,
      from(m in Membership,
        where: m.user_id == ^user.id and m.group_id not in ^MapSet.to_list(wanted)
      )
    )
    |> then(fn multi ->
      have = MapSet.new(current, & &1.group_id)

      wanted
      |> MapSet.difference(have)
      |> Enum.reduce(multi, fn group_id, acc ->
        Multi.insert(
          acc,
          {:added, group_id},
          Membership.changeset(%Membership{}, %{user_id: user.id, group_id: group_id}),
          on_conflict: :nothing
        )
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, groups}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "A user by IdP subject, or `nil`."
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(subject), do: Repo.get_by(User, subject: subject)

  @doc "A user by the id this plane gave them, or `nil`. SCIM addresses people this way."
  @spec get_user_by_id(Ecto.UUID.t()) :: User.t() | nil
  def get_user_by_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  @doc """
  Replace a group's membership with exactly these users.

  The mirror image of `set_memberships/2`, for the direction SCIM pushes in. Replace,
  not merge, for the same reason: the push carries the whole list.
  """
  @spec set_group_members(Group.t(), [Ecto.UUID.t()]) :: :ok
  def set_group_members(%Group{} = group, user_ids) do
    Repo.delete_all(
      from m in Membership, where: m.group_id == ^group.id and m.user_id not in ^user_ids
    )

    for user_id <- user_ids do
      %Membership{}
      |> Membership.changeset(%{user_id: user_id, group_id: group.id})
      |> Repo.insert(on_conflict: :nothing)
    end

    :ok
  end

  @doc "Every user in a group."
  @spec members_of(Group.t()) :: [User.t()]
  def members_of(%Group{} = group) do
    Repo.all(
      from u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.group_id == ^group.id,
        order_by: u.subject
    )
  end

  @doc "Every user, for a SCIM listing."
  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from u in User, order_by: u.subject)

  @doc "A group by IdP id, or `nil`."
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(external_id), do: Repo.get_by(Group, external_id: external_id)

  @doc "Every group, for an admin choosing which to enable."
  @spec list_groups() :: [Group.t()]
  def list_groups, do: Repo.all(from g in Group, order_by: g.display_name)

  # -- teams ------------------------------------------------------------------

  @doc """
  Enable a group as a team.

  Idempotent: enabling one twice is the same team, not a second one. The group is the
  unique key, so there is no way to end up with two teams over the same people.
  """
  @spec enable_team(Group.t(), map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def enable_team(%Group{} = group, attrs \\ %{}) do
    existing = Repo.get_by(Team, group_id: group.id)

    attrs =
      attrs
      |> Map.put_new(:group_id, group.id)
      |> Map.put_new(:name, default_team_name(group))
      |> Map.put_new(:enabled_at, DateTime.utc_now())

    (existing || %Team{})
    |> Team.changeset(attrs)
    |> Repo.insert_or_update()
  end

  # A name a person will type: the display name, lowercased, with anything that is not
  # a label character turned into a dash. Kubernetes has to accept it as part of a
  # claim name.
  defp default_team_name(%Group{display_name: display_name, external_id: external_id}) do
    (display_name || external_id)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc "Stop a group being a team. Its grants go with it; its sessions do not."
  @spec disable_team(Team.t()) :: {:ok, Team.t()} | {:error, term()}
  def disable_team(%Team{} = team), do: Repo.delete(team)

  @doc "A team by name, or `nil`."
  @spec get_team(String.t()) :: Team.t() | nil
  def get_team(name), do: Repo.get_by(Team, name: name)

  @doc "A team by id, or `nil`."
  @spec fetch_team(Ecto.UUID.t()) :: Team.t() | nil
  def fetch_team(id), do: Repo.get(Team, id)

  @doc "Every enabled team."
  @spec list_teams() :: [Team.t()]
  def list_teams, do: Repo.all(from t in Team, order_by: t.name)

  @doc """
  The teams a user is in.

  Derived from IdP membership every time rather than stored: a team's members are the
  group's members, and a cached answer is a way for access to outlive its revocation.
  """
  @spec teams_for(User.t()) :: [Team.t()]
  def teams_for(%User{} = user) do
    Repo.all(
      from t in Team,
        join: m in Membership,
        on: m.group_id == t.group_id,
        where: m.user_id == ^user.id,
        order_by: t.name
    )
  end

  @doc """
  The identity-provider groups a user is in, by external id.

  Groups, not teams: a group is what the provider says about somebody, and a team is
  what this plane has decided to do about a group. The platform-admin check needs the
  first — a plane with no teams yet still has to have somebody who can make one.
  """
  @spec group_ids_for(User.t()) :: [String.t()]
  def group_ids_for(%User{} = user) do
    Repo.all(
      from g in Group,
        join: m in Membership,
        on: m.group_id == g.id,
        where: m.user_id == ^user.id,
        select: g.external_id,
        order_by: g.external_id
    )
  end

  # -- grants -----------------------------------------------------------------

  @doc "Let a team use a profile."
  @spec grant(Team.t(), String.t(), map()) :: {:ok, Grant.t()} | {:error, Ecto.Changeset.t()}
  def grant(%Team{} = team, profile, attrs \\ %{}) do
    existing = Repo.get_by(Grant, team_id: team.id, profile: profile)

    attrs = attrs |> Map.put_new(:team_id, team.id) |> Map.put_new(:profile, profile)

    (existing || %Grant{})
    |> Grant.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Take a profile away from a team. Its live sessions become read-only."
  @spec revoke(Team.t(), String.t()) :: :ok
  def revoke(%Team{} = team, profile) do
    Repo.delete_all(from g in Grant, where: g.team_id == ^team.id and g.profile == ^profile)

    # The grant is what made those sessions allowed, and it is no longer there. They
    # become read-only rather than erased: history is history, and a team losing a grant
    # is not a reason to hide what it already did.
    frozen = Sessions.read_only_for(team.id, profile)

    if frozen > 0 do
      Logger.info("troupe plane: #{frozen} session(s) of #{team.name} on #{profile} are now read-only")
    end

    :ok
  end

  @doc "Every grant on a profile, which is what the plane projects into its resource."
  @spec grants_for_profile(String.t()) :: [Grant.t()]
  def grants_for_profile(profile) do
    Repo.all(from g in Grant, where: g.profile == ^profile, preload: [:team])
  end

  @doc "Change a team's budget, retention or default visibility."
  @spec update_team(Team.t(), map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def update_team(%Team{} = team, attrs), do: team |> Team.changeset(attrs) |> Repo.update()

  @doc "A team's grants."
  @spec grants_for_team(Team.t()) :: [Grant.t()]
  def grants_for_team(%Team{} = team) do
    Repo.all(from g in Grant, where: g.team_id == ^team.id, order_by: g.profile)
  end

  @doc """
  Everyone in a team, through the identity provider's group.

  Read-only everywhere: membership comes from the provider, and Troupe having a way to
  change it would be a second source of truth for who is in a team.
  """
  @spec members_of_team(Team.t()) :: [User.t()]
  def members_of_team(%Team{} = team) do
    Repo.all(
      from u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.group_id == type(^team.group_id, :binary_id),
        order_by: u.subject
    )
  end

  # -- team administrators ----------------------------------------------------

  @doc """
  Make somebody an administrator of one team.

  By subject rather than by user, so a platform admin can name a person who has not
  logged in yet and have the role waiting when they do.
  """
  @spec add_team_admin(Team.t(), String.t(), String.t()) :: {:ok, TeamAdmin.t()} | {:error, term()}
  def add_team_admin(%Team{} = team, subject, granted_by) do
    %TeamAdmin{}
    |> TeamAdmin.changeset(%{
      team_id: team.id,
      subject: subject,
      granted_by: granted_by,
      granted_at: DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:team_id, :subject])
    |> case do
      {:ok, %TeamAdmin{id: nil}} -> {:ok, Repo.get_by(TeamAdmin, team_id: team.id, subject: subject)}
      other -> other
    end
  end

  @doc "Take the role away."
  @spec remove_team_admin(Team.t(), String.t()) :: :ok
  def remove_team_admin(%Team{} = team, subject) do
    Repo.delete_all(from a in TeamAdmin, where: a.team_id == ^team.id and a.subject == ^subject)
    :ok
  end

  @doc "The teams this user administers, which may be none."
  @spec teams_administered_by(User.t()) :: [Team.t()]
  def teams_administered_by(%User{} = user) do
    Repo.all(
      from t in Team,
        join: a in TeamAdmin,
        on: a.team_id == t.id,
        where: a.subject == ^user.subject,
        order_by: t.name
    )
  end

  @doc "Who administers a team."
  @spec admins_of(Team.t()) :: [String.t()]
  def admins_of(%Team{} = team) do
    Repo.all(from a in TeamAdmin, where: a.team_id == ^team.id, select: a.subject, order_by: a.subject)
  end

  @doc """
  The profiles a user may create sessions on, with the team each comes through.

  A user in no enabled team gets an empty list, which is the whole of "and cannot
  create": there is nothing to create on.
  """
  @spec profiles_for(User.t()) :: [%{profile: String.t(), team: Team.t(), volume_mode: String.t()}]
  def profiles_for(%User{} = user) do
    Repo.all(
      from g in Grant,
        join: t in Team,
        on: t.id == g.team_id,
        join: m in Membership,
        on: m.group_id == t.group_id,
        where: m.user_id == ^user.id,
        order_by: [g.profile, t.name],
        preload: [team: t]
    )
    |> Enum.map(&%{profile: &1.profile, team: &1.team, volume_mode: &1.volume_mode})
  end

  @doc "Whether a user may create a session on a profile through a given team."
  @spec may_use?(User.t(), String.t(), Team.t() | nil) :: boolean()
  def may_use?(%User{} = user, profile, team \\ nil) do
    user
    |> profiles_for()
    |> Enum.any?(fn entry ->
      entry.profile == profile and (is_nil(team) or entry.team.id == team.id)
    end)
  end
end
