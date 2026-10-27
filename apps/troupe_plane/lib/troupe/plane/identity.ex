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
  alias Troupe.Plane.{Drain, Ledger, Principals, Repo, Sessions, Settings}
  alias Troupe.Plane.Ledger.UsageRecord

  alias Troupe.Plane.Identity.{
    Entitlement,
    Grant,
    Group,
    Membership,
    Team,
    TeamAdmin,
    TeamGroupLink,
    Tombstone,
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
      nil -> new_user(subject)
      user -> user
    end
    |> User.changeset(attrs)
    |> Repo.insert_or_update()
  end

  # A person's name at the key manager is fixed here, when they are first known, and
  # nothing changes it afterwards. Their subject, so the key manager's tree
  # reads as the people in it and a plane that never switches its claim sees what it
  # always did. Where that is already somebody's name, which only a switched claim can
  # make so, their own id, which nobody else's can be. A removed person's name is still
  # theirs: what they stored is under it until it is erased, and somebody arriving later
  # under the same subject is somebody new.
  defp new_user(subject) do
    if Repo.exists?(from(u in User, where: u.kms_name == ^subject)) or
         Repo.exists?(from(t in Tombstone, where: t.kms_name == ^subject)) do
      id = Ecto.UUID.generate()
      %User{id: id, kms_name: id}
    else
      %User{kms_name: subject}
    end
  end

  @doc """
  Record that these groups arrived in a sign-in just now, which is what lets the console
  list a group nobody links yet under a time a person can recognise it by.
  """
  @spec groups_seen([String.t()], DateTime.t()) :: :ok
  def groups_seen(external_ids, at \\ DateTime.utc_now())

  def groups_seen([], _at), do: :ok

  def groups_seen(external_ids, at) do
    Repo.update_all(from(g in Group, where: g.external_id in ^external_ids),
      set: [last_seen_at: at]
    )

    :ok
  end

  @doc "The ids of every group some team draws its members from."
  @spec linked_group_ids() :: MapSet.t(Ecto.UUID.t())
  def linked_group_ids do
    MapSet.new(Repo.all(from(l in TeamGroupLink, distinct: true, select: l.group_id)))
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
  Move a person from one subject to another, with everything the plane keys on it.

  What switching `subject_claim` needs (Decision 751). With nobody under `new` yet, the
  person's row is renamed. With somebody there already — SCIM provisioned them under the
  new value before they next signed in — the old row is folded into that one and removed,
  so the id SCIM addresses them by stays good. `:none` when nobody is under `old`.

  Moved are the columns that say *who*: a session's owner and the person its spend counts
  against, an ACL entry, a share made out to them, a team they administer, a trigger that
  tells them, their spend and open reservations, the principals they sponsor. What says
  *who did*, the audit trail and every `_by`, keeps the name it was written with. Their
  name at the key manager does not move either (Decision 755): what is stored under it is
  found under it.

  One transaction with the old row locked, so two devices signing in at once move the
  person once and the second finds nobody left to move.
  """
  @spec rekey(String.t(), String.t()) :: {:ok, :none | :rekeyed | :merged} | {:error, term()}
  def rekey(old, new) when is_binary(old) and is_binary(new) and old != new do
    if Repo.exists?(from(u in User, where: u.subject == ^old)),
      do: Repo.transaction(fn -> move_locked(old, new) end),
      else: {:ok, :none}
  end

  defp move_locked(old, new) do
    case lock_user(old) do
      nil -> :none
      known -> move_person(known, lock_user(new), new)
    end
  end

  defp lock_user(subject),
    do: Repo.one(from(u in User, where: u.subject == ^subject, lock: "FOR UPDATE"))

  # A row a replica of the release before wrote has no name and is read as its subject,
  # so the name is written down before the subject moves out from under it.
  defp move_person(known, nil, new) do
    move_references(known.subject, new)

    known
    |> User.changeset(%{subject: new})
    |> Ecto.Changeset.put_change(:kms_name, User.kms_name(known))
    |> Repo.update()
    |> case do
      {:ok, _user} -> :rekeyed
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp move_person(known, provisioned, new) do
    move_references(known.subject, new)

    Repo.update_all(
      from(s in "sessions", where: s.owner_id == ^Ecto.UUID.dump!(known.id)),
      set: [owner_id: Ecto.UUID.dump!(provisioned.id)]
    )

    # Their own memory is kept by their id, so it goes with them to the row that stays.
    # The row SCIM made has written none, as nobody could sign in as it.
    Repo.delete_all(from(d in "memory_documents", where: d.scope == "user" and d.owner == ^provisioned.id))

    Repo.update_all(
      from(d in "memory_documents", where: d.scope == "user" and d.owner == ^known.id),
      set: [owner: provisioned.id]
    )

    # A ceiling is the plane's opinion of the person, not the provider's, so the one they
    # had is kept where the row SCIM made has none.
    if is_nil(provisioned.budget_micros) and not is_nil(known.budget_micros) do
      {:ok, _} =
        provisioned
        |> User.budget_changeset(%{budget_micros: known.budget_micros})
        |> Repo.update()
    end

    Repo.delete!(known)

    # Theirs at the key manager is the old row's name, under which everything they stored
    # before the switch is. The row SCIM made has stored nothing, since nobody could sign
    # in as it without being moved here. After the delete, because the name is unique.
    {:ok, _} =
      provisioned
      |> Ecto.Changeset.change(kms_name: User.kms_name(known))
      |> Repo.update()

    :merged
  end

  # By table name, as `Sessions` reaches `Identity`'s tables: these rows are other modules'.
  # Where a person could be named twice — an ACL entry, a team's administrator — the entry
  # under the new name wins and the old one goes, or the rename would break the index.
  defp move_references(old, new) do
    for {table, column} <- [
          {"sessions", :owner_subject},
          {"session_shares", :audience},
          {"usage_records", :owner_subject},
          {"budget_reservations", :owner_subject},
          {"service_principals", :sponsor_subject}
        ] do
      Repo.update_all(from(r in table, where: field(r, ^column) == ^old), set: [{column, new}])
    end

    for {table, scope} <- [{"session_acls", :session_id}, {"team_admins", :team_id}] do
      taken = from(r in table, where: r.subject == ^new, select: field(r, ^scope))

      Repo.delete_all(
        from(r in table, where: r.subject == ^old and field(r, ^scope) in subquery(taken))
      )

      Repo.update_all(from(r in table, where: r.subject == ^old), set: [subject: new])
    end

    # Whose cap a trigger's run counts against: the sponsor, kept inside the session's
    # origin (`Principal`), and read back when the reservation is released.
    Repo.update_all(
      from(s in "sessions",
        where: fragment("?->'principal'->>'subject' = ?", s.origin, ^old),
        update: [
          set: [
            origin:
              fragment("jsonb_set(?, '{principal,subject}', to_jsonb(?::text))", s.origin, ^new)
          ]
        ]
      ),
      []
    )

    Repo.update_all(
      from(t in "triggers",
        where: fragment("? = ANY(?)", ^old, t.notify),
        update: [set: [notify: fragment("array_replace(?, ?, ?)", t.notify, ^old, ^new)]]
      ),
      []
    )

    :ok
  end

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
  The person SCIM calls this `externalId`, or `nil`.

  At most one: the column is unique where it is set. A push or a sign-in that finds nobody
  under its subject asks this before it makes anybody, because a person moved to another
  claim's value keeps the `externalId` SCIM gave them.
  """
  @spec get_user_by_external_id(String.t() | nil) :: User.t() | nil
  def get_user_by_external_id(nil), do: nil
  def get_user_by_external_id(value), do: Repo.get_by(User, external_id: value)

  @doc """
  Whether a sign-in or a push under `subject` may take over the row SCIM gave `external_id`.

  `:none` when no row carries the `externalId`, or when somebody SCIM named is under the
  subject already; then there is nothing to adopt. With nobody under the subject, the row
  is adopted only when its email or its `userName` agrees, ignoring case, with what the
  sign-in or push carries, or an administrator settled the pair (`settle/3`): an
  `externalId` is one provisioning attribute, and a wrong mapping of it alone would hand
  one person's row, with their sessions, shares and administration, to whoever signs in
  under that value. Nothing carried, nothing agrees.

  `{:fold, row, held}` when the one under the subject is a row a sign-in made, no push has
  named, and what is carried now agrees with SCIM's: a sign-in this answered `:refused`
  before, for a token that carried neither an email nor a username, say, whose person's
  next token carries one. The same rule as an adoption, met later. A push answers this too
  and is not given it (`Troupe.Plane.SCIM`): what a push says agrees with SCIM's row by
  being SCIM's, and is no evidence about who holds the token under the subject.
  """
  @spec adoption(String.t(), String.t() | nil, map()) ::
          :none | {:adopt, User.t()} | {:refused, User.t()} | {:fold, User.t(), User.t()}
  def adoption(subject, external_id, carried) do
    case get_user(subject) do
      nil -> adoption_of(subject, get_user_by_external_id(external_id), carried)
      %User{} = signed -> fold_of(signed, external_id, carried)
    end
  end

  defp adoption_of(_subject, nil, _carried), do: :none

  defp adoption_of(subject, held, carried) do
    if agrees?(held, carried) or settled?(subject, held),
      do: {:adopt, held},
      else: {:refused, held}
  end

  defp fold_of(
         %User{kind: "user", external_id: nil, user_name: nil} = signed,
         external_id,
         carried
       )
       when is_binary(external_id) do
    case get_user_by_external_id(external_id) do
      %User{id: id} = held when id != signed.id ->
        if agrees?(held, carried), do: {:fold, signed, held}, else: :none

      _nobody_else ->
        :none
    end
  end

  defp fold_of(_signed, _external_id, _carried), do: :none

  defp agrees?(held, carried) do
    same_text?(held.email, carried[:email]) or same_text?(held.user_name, carried[:user_name])
  end

  # An administrator said the row SCIM gave this value is the person under it, with nobody
  # there to fold in: the next push or sign-in under it adopts the row whatever it carries.
  defp settled?(subject, held) do
    Repo.exists?(
      from(e in "audit_events",
        where:
          e.action == "person.adopt" and fragment("?->>'subject' = ?", e.detail, ^subject) and
            fragment("?->>'row' = ?", e.detail, ^held.id)
      )
    )
  end

  @doc """
  Settle a pair `adoption/3` refused, as a platform administrator: the row SCIM gave
  `subject` as its `externalId` is that person's.

  Where a sign-in made a row of its own under the subject, it is folded into SCIM's row
  (`fold/2`), which takes the subject, as the upgrade's merge folded duplicates: SCIM's row
  is kept because its id is what the provider holds. Where nobody is under the subject (a
  refused push leaves no second row), nothing moves now; the next push or sign-in under it
  adopts the row whatever it carries, since this answer is on the audit trail where
  `adoption/3` reads it. A row under the subject that SCIM named by another `externalId`
  is somebody else's, and is refused.

  `{:error, :settled}` when the row no longer holds the value under another subject.
  """
  @spec settle(Ecto.UUID.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def settle(row_id, subject) when is_binary(row_id) and is_binary(subject) do
    Repo.transaction(fn ->
      held = row_id |> get_user_by_id() |> lock_row()

      case {held, lock_user(subject)} do
        {%User{external_id: ^subject, subject: other} = held, signed} when other != subject ->
          settle_pair(held, signed)

        _gone_or_settled ->
          Repo.rollback(:settled)
      end
    end)
  end

  defp lock_row(nil), do: nil

  defp lock_row(%User{id: id}),
    do: Repo.one(from(u in User, where: u.id == ^id, lock: "FOR UPDATE"))

  defp settle_pair(held, nil) do
    %{
      "subject" => held.external_id,
      "row" => held.id,
      "row_subject" => held.subject,
      "folded" => nil,
      "kms_names_left" => []
    }
  end

  defp settle_pair(_held, %User{external_id: other} = signed) when is_binary(other) do
    Repo.rollback({:named_by_scim, signed})
  end

  defp settle_pair(held, signed), do: fold_locked(held, signed)

  @doc """
  Fold the row a sign-in made under a subject into the row SCIM gave that subject as its
  `externalId`, which takes the subject.

  What `rekey/2` moves when it merges, in the other direction: the row kept is SCIM's,
  whose id the provider holds, and it moves to the subject the sign-in is under, as an
  adoption would have moved it. Its references follow it there; the sign-in row's are
  under that subject already, and its sessions are handed over by id. It keeps the
  key-manager name of whichever row was known first, under which what the person stored
  before there were two is; the other name is answered, since nothing is moved at the key
  manager. A ceiling is the kept row's, else the folded one's. The audit trail and every
  `*_by` keep the name they were written with.
  """
  @spec fold(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def fold(%User{} = held, %User{} = signed) do
    Repo.transaction(fn ->
      case {lock_row(held), lock_row(signed)} do
        {%User{} = held, %User{} = signed} -> fold_locked(held, signed)
        _gone -> Repo.rollback(:settled)
      end
    end)
  end

  defp fold_locked(held, signed) do
    subject = signed.subject
    move_references(held.subject, subject)

    Repo.update_all(
      from(s in "sessions", where: s.owner_id == ^Ecto.UUID.dump!(signed.id)),
      set: [owner_id: Ecto.UUID.dump!(held.id)]
    )

    first = Enum.min_by([held, signed], & &1.inserted_at, DateTime)
    name = User.kms_name(first)
    left = [held, signed] |> Enum.map(&User.kms_name/1) |> Enum.reject(&(&1 == name))

    Repo.delete!(signed)

    {:ok, _} =
      held
      |> User.changeset(%{subject: subject})
      |> Ecto.Changeset.put_change(:kms_name, name)
      |> Ecto.Changeset.put_change(:budget_micros, held.budget_micros || signed.budget_micros)
      |> Repo.update()

    %{
      "subject" => subject,
      "row" => held.id,
      "row_subject" => held.subject,
      "folded" => %{"id" => signed.id, "subject" => subject},
      "kms_names_left" => left
    }
  end

  defp same_text?(a, b) when is_binary(a) and is_binary(b) do
    a = a |> String.trim() |> String.downcase()
    a != "" and a == b |> String.trim() |> String.downcase()
  end

  defp same_text?(_a, _b), do: false

  @doc """
  Remove a person the identity provider removed, leaving a tombstone.

  Their row goes, so a lookup by the id the provider holds answers nobody and nobody signs
  in as them. What outlives them stays, under the tombstone: their sessions, read-only and
  owned by its marker, so somebody who later arrives under the same subject is somebody
  new and does not see them; and their name at the key manager, under which what they
  stored is until an erasure removes it. They stop administering any team, their ACL
  entries and the shares made out to them end, and the principals they sponsor stop. The
  audit trail and every `*_by` keep the name they were written with.

  Their running sessions are parked first, one at a time, giving back their slots and
  their slices under the subject they were reserved for; the rest happens in one
  transaction with the row held.
  """
  @spec remove_user(User.t(), String.t()) :: {:ok, Tombstone.t(), map()} | {:error, term()}
  def remove_user(%User{} = user, by) do
    parked = user.subject |> Sessions.holding_owned_by() |> Enum.map(&Drain.withdraw/1)

    Repo.transaction(fn ->
      case Repo.one(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE")) do
        nil -> Repo.rollback(:not_found)
        locked -> bury(locked, by, parked)
      end
    end)
    |> case do
      {:ok, {tombstone, effect}} -> {:ok, tombstone, effect}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bury(user, by, parked) do
    tombstone =
      %Tombstone{}
      |> Tombstone.changeset(%{
        former_id: user.id,
        subject: user.subject,
        external_id: user.external_id,
        user_name: user.user_name,
        display_name: user.display_name,
        kms_name: User.kms_name(user),
        removed_by: by,
        removed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    administered = Enum.map(teams_administered_by(user), & &1.name)
    Repo.delete_all(from(a in TeamAdmin, where: a.subject == ^user.subject))

    :ok = Sessions.drop_access(user.subject, by)
    {:ok, stopped} = Principals.sponsor_left(user.subject)
    marker = Tombstone.marker(tombstone)
    sessions = Sessions.hand_to_removed(user.subject, marker)
    notified_by = drop_from_notify(user.subject)
    :ok = hand_spend_to(user.subject, marker)

    # Their own memory is theirs and nobody else's to read, so it goes with them, every
    # version; the audit keeps what it has of each save, which never held the text.
    Repo.delete_all(from(d in "memory_documents", where: d.scope == "user" and d.owner == ^user.id))

    Repo.delete!(user)

    {tombstone,
     %{
       "id" => user.id,
       "tombstone" => tombstone.id,
       "sessions" => sessions,
       "parked" => length(parked),
       "team_admin_of" => administered,
       "principals_stopped" => Enum.map(stopped, & &1.subject),
       "notified_by" => notified_by
     }}
  end

  # A trigger's `notify` names whom each run lets in. Left there, somebody provisioned
  # later under the same subject would be let into the next run as the removed person
  # was, so they come off every list; the run already fired stays as it was.
  defp drop_from_notify(subject) do
    names =
      Repo.all(
        from(t in "triggers",
          where: fragment("? = ANY(?)", ^subject, t.notify),
          order_by: t.name,
          select: t.name
        )
      )

    Repo.update_all(
      from(t in "triggers",
        where: fragment("? = ANY(?)", ^subject, t.notify),
        update: [set: [notify: fragment("array_remove(?, ?)", t.notify, ^subject)]]
      ),
      []
    )

    names
  end

  # What they spent and still hold is theirs, and counts toward their teams' totals as it
  # did, but no longer under the subject: a person's cap reads this month's spend by
  # subject, and somebody arriving under it later starts with none.
  defp hand_spend_to(subject, marker) do
    teams =
      Repo.all(
        from(u in UsageRecord,
          where: u.owner_subject == ^subject,
          distinct: true,
          select: u.team_id
        )
      )

    for table <- ["usage_records", "budget_reservations"] do
      Repo.update_all(from(r in table, where: r.owner_subject == ^subject),
        set: [owner_subject: marker]
      )
    end

    # A team's spend by person is remembered for a minute, and it now says the marker.
    Enum.each(teams, &Ledger.Cache.invalidate/1)
  end

  @doc """
  The marker of the removed person who owns what names `subject` and was written at `at`,
  or `nil` when that is whoever is under the subject now: who owns a session whose manifest
  names `subject` and was last written at `at`, and who a trigger's revision written then
  meant by it.

  The first person removed under the subject at or after `at`, when there is one: a removed
  person's sessions are handed to their tombstone's marker and frozen, so one written no
  later than the removal was theirs. Written after every removal, it is still the last
  removed person's unless somebody has arrived under the subject since and wrote it after
  arriving: a session parked as its owner was removed can have its manifest written after
  the removal, and nobody else was under the subject to write one. Only a write after
  somebody new arrived is theirs.
  """
  @spec removed_owner(String.t() | nil, DateTime.t()) :: String.t() | nil
  def removed_owner(nil, _at), do: nil

  def removed_owner(subject, %DateTime{} = at) do
    tombstones =
      Repo.all(from(t in Tombstone, where: t.subject == ^subject, order_by: [asc: t.removed_at]))

    case Enum.find(tombstones, &(DateTime.compare(&1.removed_at, at) != :lt)) do
      nil -> last_removed(List.last(tombstones), get_user(subject), at)
      tombstone -> Tombstone.marker(tombstone)
    end
  end

  defp last_removed(nil, _holder, _at), do: nil

  defp last_removed(tombstone, %User{inserted_at: arrived}, at) do
    if DateTime.compare(at, arrived) == :lt, do: Tombstone.marker(tombstone)
  end

  defp last_removed(tombstone, _nobody, _at), do: Tombstone.marker(tombstone)

  @doc """
  The name at the key manager of whoever a session's `owner_subject` names: a person's,
  a removed person's from their tombstone, else the value itself, as a principal's and a
  row from before the column are.
  """
  @spec kms_name_of(String.t()) :: String.t()
  def kms_name_of(owner) do
    case Tombstone.parse_marker(owner) do
      {:ok, id} ->
        case Repo.get(Tombstone, id) do
          %Tombstone{kms_name: name} -> name
          nil -> owner
        end

      :error ->
        case get_user(owner) do
          %User{} = user -> User.kms_name(user)
          nil -> owner
        end
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

  @doc """
  The users a SCIM filter names. `userName` ignores case, as SCIM compares it, and is the
  subject for somebody no push has named; `externalId` is exact.
  """
  @spec find_users(:user_name | :external_id, String.t()) :: [User.t()]
  def find_users(:user_name, value) do
    Repo.all(
      from(u in User,
        where: fragment("lower(coalesce(?, ?)) = lower(?)", u.user_name, u.subject, ^value),
        order_by: u.subject
      )
    )
  end

  def find_users(:external_id, value),
    do: Repo.all(from(u in User, where: u.external_id == ^value, order_by: u.subject))

  @doc "A group by IdP id, or `nil`."
  @spec get_group(String.t()) :: Group.t() | nil
  def get_group(external_id), do: Repo.get_by(Group, external_id: external_id)

  @doc "A group by the id this plane gave it, or `nil`. SCIM addresses groups this way."
  @spec get_group_by_id(Ecto.UUID.t()) :: Group.t() | nil
  def get_group_by_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Group, uuid)
      :error -> nil
    end
  end

  @doc "The groups a SCIM filter names: `displayName` ignoring case, `externalId` exactly."
  @spec find_groups(:display_name | :external_id, String.t()) :: [Group.t()]
  def find_groups(:display_name, value) do
    Repo.all(
      from(g in Group,
        where: fragment("lower(?) = lower(?)", g.display_name, ^value),
        order_by: g.display_name
      )
    )
  end

  def find_groups(:external_id, value),
    do: Repo.all(from(g in Group, where: g.external_id == ^value))

  @doc "Every group, for an admin choosing which to enable."
  @spec list_groups() :: [Group.t()]
  def list_groups, do: Repo.all(from(g in Group, order_by: g.display_name))

  @doc """
  People and groups that look like one held twice: the same email or display name under
  different keys.

  Nothing merges these, because nothing proves they are one: two people may share an
  address, and only the provider knows which of a group's two ids is right. Each set comes
  with the mismatch it most likely comes from, for an administrator to settle at the
  provider.
  """
  @spec lookalikes() :: %{people: [map()], groups: [map()]}
  def lookalikes, do: %{people: people_alike(), groups: group_lookalikes()}

  defp people_alike do
    users = list_users()
    refused = refused_adoptions()
    held = Enum.map(refused, & &1.rows)
    by_email = users |> alike(& &1.email) |> Enum.reject(&within?(&1, held))

    by_name =
      users
      |> alike(& &1.display_name)
      |> Enum.reject(&within?(&1, by_email ++ held))

    claim = Settings.get("subject_claim")

    Enum.map(refused, &refused_set/1) ++
      Enum.map(by_email, &person_set(&1, "email", claim)) ++
      Enum.map(by_name, &person_set(&1, "display_name", claim))
  end

  defp within?(rows, sets), do: Enum.any?(sets, &subset?(rows, &1))

  # The adoptions `adoption/3` refused that still stand: the row SCIM gave the `externalId`
  # is still under another subject, and no administrator has settled the pair since. Read
  # from the audit trail, where each refusal is, because a refused push leaves no second row
  # behind to find; a sign-in leaves its own, under the subject, and it is listed beside the
  # row, as is the row a push keyed on when the unique `externalId` refused it (`other`).
  # A refusal a later push resolved by agreeing (`person.adopt_agreed`) is not listed; one
  # after that is.
  defp refused_adoptions do
    settled =
      from(e in "audit_events", where: e.action == "person.adopt", select: e.detail)
      |> Repo.all()
      |> MapSet.new(&{&1["subject"], &1["row"]})

    agreed = agreements()

    from(e in "audit_events",
      where: e.action == "person.adopt_refused",
      order_by: [desc: e.occurred_at],
      limit: 500,
      select: {e.detail, e.occurred_at}
    )
    |> Repo.all()
    |> Enum.uniq_by(fn {detail, _at} -> {detail["subject"], detail["row"]} end)
    |> Enum.reject(fn {detail, at} ->
      pair = {detail["subject"], detail["row"]}
      MapSet.member?(settled, pair) or later?(Map.get(agreed, pair), at)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.flat_map(fn detail ->
      subject = detail["subject"]

      case get_user_by_id(detail["row"]) do
        %User{external_id: ^subject, subject: other} = row when other != subject ->
          beside = get_user_by_id(detail["other"] || "") || get_user(subject)
          rows = Enum.reject([row, beside], &is_nil/1)
          [%{rows: rows, row: row, via: detail["via"], subject: subject}]

        _settled ->
          []
      end
    end)
    |> Enum.uniq_by(&Enum.map(&1.rows, fn row -> row.id end))
  end

  # The last time a push under each subject agreed with the row SCIM gave it, after a
  # refusal of the pair, by pair.
  defp agreements(pair \\ dynamic(true)) do
    from(e in "audit_events",
      where: e.action == "person.adopt_agreed",
      where: ^pair,
      group_by: [fragment("?->>'subject'", e.detail), fragment("?->>'row'", e.detail)],
      select:
        {fragment("?->>'subject'", e.detail), fragment("?->>'row'", e.detail), max(e.occurred_at)}
    )
    |> Repo.all()
    |> Map.new(fn {subject, row, at} -> {{subject, row}, at} end)
  end

  defp later?(nil, _refused_at), do: false

  defp later?(agreed_at, refused_at),
    do: NaiveDateTime.compare(stamp(agreed_at), stamp(refused_at)) == :gt

  defp stamp(%DateTime{} = at), do: DateTime.to_naive(at)
  defp stamp(at), do: at

  @doc """
  Whether a refusal of the pair still stands: the last `person.adopt_refused` of a push or
  a sign-in under `subject` onto the row SCIM gave it, with no administrator's settlement
  and no agreeing push since. A push that agrees then resolves it, audited
  `person.adopt_agreed` by its caller (`Troupe.Plane.SCIM`), and the pair is no longer
  listed; asked first, so that a provider's every sync of an agreeing record audits nothing.
  Unlike a settlement, an agreement lets no later push that disagrees past the check.
  """
  @spec refusal_standing?(String.t(), Ecto.UUID.t()) :: boolean()
  def refusal_standing?(subject, row_id) do
    pair =
      dynamic(
        [e],
        fragment("?->>'subject' = ?", e.detail, ^subject) and
          fragment("?->>'row' = ?", e.detail, ^row_id)
      )

    refused_at =
      Repo.one(
        from(e in "audit_events",
          where: e.action == "person.adopt_refused",
          where: ^pair,
          select: max(e.occurred_at)
        )
      )

    settled? =
      Repo.exists?(from(e in "audit_events", where: e.action == "person.adopt", where: ^pair))

    refused_at != nil and not settled? and
      not later?(Map.get(agreements(pair), {subject, row_id}), refused_at)
  end

  @settle "or, if they are one person, settle it here (admin.identity.adopt), which keeps SCIM's row"

  defp refused_set(%{rows: rows, row: row, via: via, subject: subject}) do
    likely =
      case {via, rows} do
        {"scim", [_scim, _keyed]} ->
          "SCIM pushed externalId #{subject} onto the row a sign-in made under it, and this other row already holds that externalId, so the push was refused and nothing merged: if they are one person, make the email or userName agree at the provider and the next sign-in folds the two, #{@settle}; if not, the provider's externalId mapping gives two people one value"

        {"scim", _alone} ->
          "SCIM pushed externalId #{subject}, which this row holds, but neither the email nor the userName it sent agrees with the row's, so the push was refused and nothing merged: if they are one person, make the email or userName agree at the provider, #{@settle}; if not, the provider's externalId mapping gives two people one value"

        _sign_in ->
          "a sign-in under #{subject} found this row by its SCIM externalId, but neither the email nor the userName its token carried agrees with the row's, so it was given a row of its own: if they are one person, make the email or userName agree at the provider and the next sign-in folds the two, #{@settle}; if not, the provider's externalId mapping gives two people one value"
      end

    %{
      by: "external_id",
      subject: subject,
      row: row.id,
      people: Enum.map(rows, &person_entry/1),
      likely: likely
    }
  end

  @doc "The groups half of `lookalikes/0`: groups sharing a display name under different ids."
  @spec group_lookalikes() :: [map()]
  def group_lookalikes do
    list_groups()
    |> alike(& &1.display_name)
    |> Enum.map(fn groups ->
      # A group a `groups` claim made is named by what the claim carried; one SCIM pushed
      # has its own id beside its name.
      from_claim = Enum.filter(groups, &(&1.display_name == &1.external_id))

      likely =
        if from_claim != [] and length(from_claim) < length(groups),
          do:
            "the groups claim names this group by its name and SCIM by its id: send the same value in both, the group's id, and link its teams to the group that stays",
          else: "the provider sent two groups of this name under different ids"

      %{
        by: "display_name",
        groups: Enum.map(groups, &Map.take(&1, [:external_id, :display_name])),
        likely: likely
      }
    end)
  end

  # Rows sharing a value, ignoring case, in sets of more than one.
  defp alike(rows, key) do
    rows
    |> Enum.filter(&is_binary(key.(&1)))
    |> Enum.group_by(&(&1 |> key.() |> String.downcase()))
    |> Map.values()
    |> Enum.filter(&match?([_, _ | _], &1))
    |> Enum.sort_by(&key.(hd(&1)))
  end

  defp subset?(rows, of), do: Enum.all?(rows, fn row -> Enum.any?(of, &(&1.id == row.id)) end)

  defp person_set(users, by, claim) do
    origins = users |> Enum.map(&origin/1) |> Enum.uniq() |> Enum.sort()

    likely =
      case origins do
        ["scim", "sign-in"] ->
          "a sign-in keyed one on the #{claim} claim and SCIM the other on its externalId (else its userName), and the two values differ: make them the same at the provider"

        ["scim"] ->
          "SCIM pushed them under two externalIds (or userNames): the provider holds two records, or its mapping changed"

        ["sign-in"] ->
          "they signed in under two subjects: the #{claim} claim changed for them, or two accounts share the #{String.replace(by, "_", " ")}"
      end

    %{by: by, people: Enum.map(users, &person_entry/1), likely: likely}
  end

  defp person_entry(user) do
    user
    |> Map.take([:id, :subject, :external_id, :user_name, :email, :display_name])
    |> Map.put(:origin, origin(user))
  end

  # A push writes `userName` whatever else it sends, and a sign-in writes neither.
  defp origin(%User{external_id: nil, user_name: nil}), do: "sign-in"
  defp origin(%User{}), do: "scim"

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
    name = team_name(group, wanted)

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

  @doc "The name `enable_team/2` gives the team: the one `attrs` asks for, else one made from the group's."
  @spec team_name(Group.t(), map()) :: term()
  def team_name(%Group{} = group, attrs),
    do: Map.get(attrs, "name") || Map.get(attrs, :name) || default_team_name(group)

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

  @doc """
  Every team built on a group: drawing members from it, or enabled from it, which is the
  group its `group_id` records.
  """
  @spec teams_built_on(Group.t()) :: [Team.t()]
  def teams_built_on(%Group{} = group) do
    (teams_drawing_from(group) ++ Repo.all(from(t in Team, where: t.group_id == ^group.id)))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)
  end

  # A name a person will type: the display name, lowercased, with anything that is not
  # a label character turned into a dash. Kubernetes has to accept it as part of a
  # claim name.
  defp default_team_name(%Group{display_name: display_name, external_id: external_id}) do
    (display_name || external_id)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    # Inside `Team`'s rule, so a long group name becomes a long team name rather than a
    # refused one. A name that is empty afterwards — a display name with no letters or
    # digits in it — is still refused, and the connector leaves that group for a person.
    |> String.slice(0, 58)
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
    # budget as two budgets. Ordered by name afterwards: `distinct` on the id orders by the id
    # first, and the first team, which an artifact with no team of its own counts against,
    # would be whichever id sorted first.
    Repo.all(
      from(t in Team,
        join: l in TeamGroupLink,
        on: l.team_id == t.id,
        join: m in Membership,
        on: m.group_id == l.group_id,
        where: m.user_id == ^user.id,
        distinct: t.id
      )
    )
    |> Enum.sort_by(& &1.name)
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
    # is not a reason to hide what it already did. A running one gives back its pod's slot
    # and its budget slice on the way, as one that went dormant would have, and its pod is
    # told to put it to sleep; one still waiting for room gives back its slice and is
    # never placed (Decision 697).
    parked = team.id |> Sessions.holding_for(profile) |> Enum.map(&Drain.withdraw/1)
    frozen = length(parked) + Sessions.read_only_for(team.id, profile)

    if frozen > 0 do
      Logger.info(
        "troupe plane: #{frozen} session(s) of #{team.name} on #{profile} are now read-only"
      )
    end

    :ok
  end

  @doc """
  Whether a team holds a grant on a profile.

  Asked again wherever a session would start, not only when one is created: a grant can
  go while its team's sessions sleep or wait for room.
  """
  @spec granted?(Team.t(), String.t()) :: boolean()
  def granted?(%Team{} = team, profile) do
    Repo.exists?(from(g in Grant, where: g.team_id == ^team.id and g.profile == ^profile))
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
