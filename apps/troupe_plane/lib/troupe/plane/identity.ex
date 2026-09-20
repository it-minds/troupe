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
  alias Troupe.Plane.{Principals, Repo, Sessions, Settings}

  alias Troupe.Plane.Identity.{
    Entitlement,
    Grant,
    Group,
    Membership,
    Team,
    TeamAdmin,
    TeamGroupLink,
    User
  }

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
    groups = Repo.all(from(g in Group, where: g.external_id in ^external_ids))
    wanted = MapSet.new(groups, & &1.id)
    current = Repo.all(from(m in Membership, where: m.user_id == ^user.id))

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

  @doc """
  A user by IdP subject, or `nil`.

  A `svc:` subject is a service principal and resolves to the `%User{}` it is handled
  as — or to `nil` when it is disabled, which is what makes disabling one take effect at
  its next request rather than at its next login.
  """
  @spec get_user(String.t()) :: User.t() | nil
  def get_user("svc:" <> _ = subject), do: Principals.user_for(subject)
  def get_user(subject), do: Repo.get_by(User, subject: subject)

  @doc """
  Set or clear a person's own spend ceiling.

  Through `User.budget_changeset/2` rather than the changeset SCIM and a login write, so
  a provider push cannot reset it. `nil` and `0` both clear it.
  """
  @spec set_budget(User.t(), integer() | nil) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_budget(%User{} = user, budget_micros) do
    user
    |> User.budget_changeset(%{budget_micros: budget_micros})
    |> Repo.update()
  end

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
      from(m in Membership, where: m.group_id == ^group.id and m.user_id not in ^user_ids)
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
      from(u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.group_id == ^group.id,
        order_by: u.subject
      )
    )
  end

  @doc "Every user, for a SCIM listing."
  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from(u in User, order_by: u.subject))

  @doc "A group by IdP id, or `nil`."
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(external_id), do: Repo.get_by(Group, external_id: external_id)

  @doc "Every group, for an admin choosing which to enable."
  @spec list_groups() :: [Group.t()]
  def list_groups, do: Repo.all(from(g in Group, order_by: g.display_name))

  # -- teams ------------------------------------------------------------------

  @doc """
  Enable a group as a team.

  Idempotent: enabling one twice is the same team, not a second one. The group is the
  unique key, so there is no way to end up with two teams over the same people.
  """
  @spec enable_team(Group.t(), map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def enable_team(%Group{} = group, attrs \\ %{}) do
    # String keys throughout, whoever called. `Map.put_new(:group_id, ...)` on a map that
    # arrived from JSON produced a map with mixed keys, which Ecto refuses to cast — so
    # enabling a team with any attributes at all worked from the panel and raised from the
    # CLI and the API.
    wanted = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    name = wanted["name"] || default_team_name(group)

    # By name, not by group. Keying on the group meant enabling one under a second name
    # silently *renamed* the first team instead of making another — one group, one team,
    # for ever, which is the assumption this package exists to remove.
    existing = Repo.get_by(Team, name: name)

    attrs =
      wanted
      |> Map.put_new("group_id", group.id)
      |> Map.put("name", name)
      |> Map.put_new("enabled_at", DateTime.utc_now())

    (existing || %Team{})
    |> Team.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, team} ->
        # A team enabled from a group starts linked to it, which is what enabling one has
        # always meant. Everything after that is `link_group/3`.
        {:ok, _link} = link_group(team, group, "enable_team")
        {:ok, team}

      error ->
        error
    end
  end

  @doc """
  Enable a group as a team only if no team draws from it and its name is free.

  What the SCIM connector calls when its switch is on. `enable_team/2` is keyed on the
  name and *updates* a team that already has it — right for an administrator repeating
  themselves, wrong for a push: a group whose display name happens to be an existing
  team's would be linked into that team, and forty strangers would be in it by morning.
  So this refuses both cases and says which, and the connector leaves those groups for
  an administrator, who can see the collision.
  """
  @spec enable_team_if_new(Group.t(), map()) ::
          {:ok, Team.t()} | {:error, :already_a_team | :name_taken | Ecto.Changeset.t()}
  def enable_team_if_new(%Group{} = group, attrs \\ %{}) do
    name = default_team_name(group)

    cond do
      teams_drawing_from(group) != [] -> {:error, :already_a_team}
      Repo.get_by(Team, name: name) -> {:error, :name_taken}
      true -> enable_team(group, Map.put(attrs, "name", name))
    end
  end

  @doc "Every team that draws members from a group, through any link."
  @spec teams_drawing_from(Group.t()) :: [Team.t()]
  def teams_drawing_from(%Group{} = group) do
    Repo.all(
      from(t in Team,
        join: l in TeamGroupLink,
        on: l.team_id == type(t.id, :binary_id),
        where: l.group_id == type(^group.id, :binary_id),
        order_by: t.name
      )
    )
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
  def list_teams, do: Repo.all(from(t in Team, order_by: t.name))

  @doc """
  The teams a user is in.

  Derived from IdP membership every time rather than stored: a team's members are the
  group's members, and a cached answer is a way for access to outlive its revocation.
  """
  @spec teams_for(User.t()) :: [Team.t()]
  def teams_for(%User{kind: "service", principal: principal}) do
    # A principal is in the team that owns it and in no other; there is no group to
    # derive that from, and nothing that could revoke it short of disabling the principal.
    case Repo.get(Team, principal.team_id) do
      nil -> []
      team -> [team]
    end
  end

  def teams_for(%User{} = user) do
    # Through the links, and `distinct` because a person in two of a team's groups is in
    # the team *once*. Without it they get every team twice and a listing shows their
    # budget as two budgets.
    Repo.all(
      from(t in Team,
        join: l in TeamGroupLink,
        on: l.team_id == t.id,
        join: m in Membership,
        on: m.group_id == l.group_id,
        where: m.user_id == ^user.id,
        distinct: t.id,
        order_by: t.name
      )
    )
  end

  @doc """
  The identity-provider groups a user is in, by external id.

  Groups, not teams: a group is what the provider says about somebody, and a team is
  what this plane has decided to do about a group. The platform-admin check needs the
  first — a plane with no teams yet still has to have somebody who can make one.
  """
  @spec group_ids_for(User.t()) :: [String.t()]
  def group_ids_for(%User{kind: "service"}), do: []

  def group_ids_for(%User{} = user) do
    Repo.all(
      from(g in Group,
        join: m in Membership,
        on: m.group_id == g.id,
        where: m.user_id == ^user.id,
        select: g.external_id,
        order_by: g.external_id
      )
    )
  end

  # -- grants -----------------------------------------------------------------

  @doc """
  Let a team use a profile.

  `attrs` may carry `entitlements`: a list of `%{kind, name, mode}` that *replaces* the
  grant's rows. Replacement rather than merge, because the editor that writes them shows
  three checklists and a partial write of a checklist is a list somebody did not mean.
  Leaving the key out changes nothing, which is what keeps every existing caller — and
  every existing grant — exactly as it was.
  """
  @spec grant(Team.t(), String.t(), map()) :: {:ok, Grant.t()} | {:error, Ecto.Changeset.t()}
  def grant(%Team{} = team, profile, attrs \\ %{}) do
    existing = Repo.get_by(Grant, team_id: team.id, profile: profile)

    # String keys throughout, because callers reach here with both — a form's map, a
    # keyword-ish map from a test, and `Admin.team_grant/4`, which stringifies before it
    # can look for `entitlements`. Ecto refuses a map with mixed keys, and the mixture
    # only appears when one caller has already normalised and this function has not.
    {entitlements, attrs} = attrs |> stringify() |> pop_entitlements()

    attrs =
      attrs
      |> Map.put_new("team_id", team.id)
      |> Map.put_new("profile", profile)

    with {:ok, grant} <-
           (existing || %Grant{}) |> Grant.changeset(attrs) |> Repo.insert_or_update() do
      case entitlements do
        nil -> {:ok, grant}
        rows -> put_entitlements(grant, rows)
      end
    end
  end

  defp pop_entitlements(attrs), do: Map.pop(attrs, "entitlements")

  # -- entitlements -----------------------------------------------------------

  @doc """
  The rows narrowing a grant. None means no restriction.
  """
  @spec entitlements(Grant.t()) :: [Entitlement.t()]
  def entitlements(%Grant{} = grant) do
    Repo.all(
      from(e in Entitlement,
        where: e.grant_id == ^grant.id,
        order_by: [e.kind, e.name]
      )
    )
  end

  @doc """
  The rows narrowing what a team may use on a profile, or `[]` where there is no grant.

  `[]` from a team with no grant is not a widening: nothing reaches this without having
  already been told the team may use the profile at all, and a profile a team has no
  grant on offers it nothing to narrow.
  """
  @spec entitlements_for(Team.t() | nil, String.t()) :: [Entitlement.t()]
  def entitlements_for(nil, _profile), do: []

  def entitlements_for(%Team{} = team, profile) do
    Repo.all(
      from(e in Entitlement,
        join: g in Grant,
        on: g.id == e.grant_id,
        where: g.team_id == ^team.id and g.profile == ^profile,
        order_by: [e.kind, e.name]
      )
    )
  end

  @doc """
  Replace a grant's entitlement rows, in one transaction.

  Replacement is the operation the editor has: three checklists, written whole. A row
  naming something the current bundle does not have is kept rather than refused — a
  bundle can be rolled back, and an entitlement that vanished with a publish and did not
  come back with the revert would be a silent widening.
  """
  @spec put_entitlements(Grant.t(), [map()]) :: {:ok, Grant.t()} | {:error, Ecto.Changeset.t()}
  def put_entitlements(%Grant{} = grant, rows) when is_list(rows) do
    now = DateTime.utc_now()

    prepared =
      rows
      |> Enum.map(&stringify/1)
      |> collapse()
      |> Enum.map(fn row ->
        %Entitlement{}
        |> Entitlement.changeset(%{
          "grant_id" => grant.id,
          "kind" => row["kind"],
          "name" => row["name"],
          "mode" => row["mode"] || "allow"
        })
      end)

    case Enum.find(prepared, &(not &1.valid?)) do
      %Ecto.Changeset{} = bad ->
        {:error, bad}

      nil ->
        rows = Enum.map(prepared, &entitlement_row(&1, now))

        Repo.transaction(fn ->
          Repo.delete_all(from(e in Entitlement, where: e.grant_id == ^grant.id))
          Repo.insert_all(Entitlement, rows)
          grant
        end)
    end
  end

  # `insert_all` takes plain maps rather than changesets, so the defaults a changeset
  # would have applied have to be applied here — the changeset above is what validated
  # the row, and this is what writes it.
  defp entitlement_row(changeset, now) do
    changeset.changes
    |> Map.put(:id, Ecto.UUID.generate())
    |> Map.put_new(:mode, "allow")
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  defp stringify(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {to_string(key), value} end)
  end

  # One row per name, because that is what the unique index holds and what an editor of
  # three checklists can express. A list that names the same thing twice is a caller
  # saying two things at once, and the safe reading is the one that grants less — the
  # same rule `Entitlement.resolve/2` applies when rows arrive together from several
  # grants, reached here before anything is written rather than after.
  defp collapse(rows) do
    rows
    |> Enum.group_by(&{&1["kind"], &1["name"]})
    |> Enum.map(fn {_key, group} ->
      Enum.find(group, List.first(group), &(&1["mode"] == "deny"))
    end)
    |> Enum.sort_by(&{&1["kind"], &1["name"]})
  end

  @doc "Take a profile away from a team. Its live sessions become read-only."
  @spec revoke(Team.t(), String.t()) :: :ok
  def revoke(%Team{} = team, profile) do
    Repo.delete_all(from(g in Grant, where: g.team_id == ^team.id and g.profile == ^profile))

    # The grant is what made those sessions allowed, and it is no longer there. They
    # become read-only rather than erased: history is history, and a team losing a grant
    # is not a reason to hide what it already did.
    frozen = Sessions.read_only_for(team.id, profile)

    if frozen > 0 do
      Logger.info(
        "troupe plane: #{frozen} session(s) of #{team.name} on #{profile} are now read-only"
      )
    end

    :ok
  end

  @doc "Every grant on a profile, which is what the plane projects into its resource."
  @spec grants_for_profile(String.t()) :: [Grant.t()]
  def grants_for_profile(profile) do
    Repo.all(from(g in Grant, where: g.profile == ^profile, preload: [:team]))
  end

  @doc "Change a team's budget, retention or default visibility."
  @spec update_team(Team.t(), map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def update_team(%Team{} = team, attrs), do: team |> Team.changeset(attrs) |> Repo.update()

  @doc "A team's grants."
  @spec grants_for_team(Team.t()) :: [Grant.t()]
  def grants_for_team(%Team{} = team) do
    Repo.all(from(g in Grant, where: g.team_id == ^team.id, order_by: g.profile))
  end

  @doc """
  Everyone in a team, through the identity provider's group.

  Read-only everywhere: membership comes from the provider, and Troupe having a way to
  change it would be a second source of truth for who is in a team.
  """
  @spec members_of_team(Team.t()) :: [User.t()]
  def members_of_team(%Team{} = team) do
    Repo.all(
      from(u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        join: l in TeamGroupLink,
        on: l.group_id == m.group_id and l.team_id == type(^team.id, :binary_id),
        distinct: u.id,
        order_by: u.subject
      )
    )
  end

  @doc """
  The groups a team draws its members from, newest link last.

  What the console lists and what an administrator adds to. A team with none has no
  members, which is valid: it is what a team looks like while somebody is still deciding
  which groups belong in it.
  """
  @spec links_of(Team.t()) :: [TeamGroupLink.t()]
  def links_of(%Team{} = team) do
    Repo.all(
      from(l in TeamGroupLink,
        where: l.team_id == type(^team.id, :binary_id),
        order_by: l.inserted_at,
        preload: [:group]
      )
    )
  end

  @doc """
  Draw a team's members from one more group.

  Idempotent on the pair: linking a group twice is the same link, not a person counted
  twice — which matters because membership is a union and a union over duplicates is a
  listing with everybody in it twice.
  """
  @spec link_group(Team.t(), Group.t(), String.t()) ::
          {:ok, TeamGroupLink.t()} | {:error, Ecto.Changeset.t()}
  def link_group(%Team{} = team, %Group{} = group, by) do
    attrs = %{team_id: team.id, group_id: group.id, issuer: issuer(), linked_by: by}

    (Repo.get_by(TeamGroupLink, team_id: team.id, group_id: group.id) || %TeamGroupLink{})
    |> TeamGroupLink.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Stop drawing a team's members from a group.

  Removes access for everybody who was in the team *only* through it. `unlink_effect/2`
  is what says how many that is, and is meant to be shown before this is called.
  """
  @spec unlink_group(Team.t(), Group.t()) :: :ok
  def unlink_group(%Team{} = team, %Group{} = group) do
    Repo.delete_all(
      from(l in TeamGroupLink,
        where: l.team_id == type(^team.id, :binary_id) and l.group_id == type(^group.id, :binary_id)
      )
    )

    :ok
  end

  @doc """
  Who loses access if this link goes, and who does not.

  The count comes first and the identifier is typed, like every other irreversible
  action. Somebody unlinking a group is usually right about which group and often wrong
  about how many people are only in the team through it — that is exactly the number this
  answers, and it is the one worth putting in front of them.
  """
  @spec unlink_effect(Team.t(), Group.t()) :: map()
  def unlink_effect(%Team{} = team, %Group{} = group) do
    in_group = MapSet.new(members_of_group(group), & &1.subject)
    remaining = team |> members_without(group) |> MapSet.new(& &1.subject)

    losing = MapSet.difference(in_group, remaining)

    %{
      team: team.name,
      group: group.external_id,
      in_group: MapSet.size(in_group),
      keep_access: MapSet.size(MapSet.intersection(in_group, remaining)),
      lose_access: MapSet.size(losing),
      losing: losing |> MapSet.to_list() |> Enum.sort(),
      # Sessions do not move. A session's team is recorded at create and stays; unlinking
      # changes who may open it, not what it belongs to — which is the thing people assume
      # the other way round, so the dialog says it.
      sessions_they_can_open: sessions_open_to(team, losing)
    }
  end

  defp members_without(%Team{} = team, %Group{} = group) do
    Repo.all(
      from(u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        join: l in TeamGroupLink,
        on: l.group_id == m.group_id and l.team_id == type(^team.id, :binary_id),
        where: l.group_id != type(^group.id, :binary_id),
        distinct: u.id
      )
    )
  end

  defp members_of_group(%Group{} = group) do
    Repo.all(
      from(u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.group_id == type(^group.id, :binary_id),
        order_by: u.subject
      )
    )
  end

  # What those people could open today. Team-visible sessions of this team, plus the ones
  # they own or are on the ACL of — counted rather than listed, because a dialog wants a
  # number and a list of twenty-three session ids is not one.
  defp sessions_open_to(_team, losing) do
    if MapSet.size(losing) == 0, do: 0, else: Sessions.count_visible_to(MapSet.to_list(losing))
  end

  defp issuer, do: Settings.get("issuer")

  # -- team administrators ----------------------------------------------------

  @doc """
  Make somebody an administrator of one team.

  By subject rather than by user, so a platform admin can name a person who has not
  logged in yet and have the role waiting when they do.
  """
  @spec add_team_admin(Team.t(), String.t(), String.t()) ::
          {:ok, TeamAdmin.t()} | {:error, term()}
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
      {:ok, %TeamAdmin{id: nil}} ->
        {:ok, Repo.get_by(TeamAdmin, team_id: team.id, subject: subject)}

      other ->
        other
    end
  end

  @doc "Take the role away."
  @spec remove_team_admin(Team.t(), String.t()) :: :ok
  def remove_team_admin(%Team{} = team, subject) do
    Repo.delete_all(from(a in TeamAdmin, where: a.team_id == ^team.id and a.subject == ^subject))
    :ok
  end

  @doc "The teams this user administers, which may be none."
  @spec teams_administered_by(User.t()) :: [Team.t()]
  def teams_administered_by(%User{} = user) do
    Repo.all(
      from(t in Team,
        join: a in TeamAdmin,
        on: a.team_id == t.id,
        where: a.subject == ^user.subject,
        order_by: t.name
      )
    )
  end

  @doc "Who administers a team."
  @spec admins_of(Team.t()) :: [String.t()]
  def admins_of(%Team{} = team) do
    Repo.all(
      from(a in TeamAdmin, where: a.team_id == ^team.id, select: a.subject, order_by: a.subject)
    )
  end

  @doc """
  The profiles a user may create sessions on, with the team each comes through.

  A user in no enabled team gets an empty list, which is the whole of "and cannot
  create": there is nothing to create on.
  """
  @spec profiles_for(User.t()) :: [
          %{profile: String.t(), team: Team.t(), volume_mode: String.t()}
        ]
  def profiles_for(%User{kind: "service", principal: principal}),
    do: Principals.profiles_for(principal)

  def profiles_for(%User{} = user) do
    Repo.all(
      from(g in Grant,
        join: t in Team,
        on: t.id == g.team_id,
        join: l in TeamGroupLink,
        on: l.team_id == t.id,
        join: m in Membership,
        on: m.group_id == l.group_id,
        where: m.user_id == ^user.id,
        order_by: [g.profile, t.name],
        preload: [team: t]
      )
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
