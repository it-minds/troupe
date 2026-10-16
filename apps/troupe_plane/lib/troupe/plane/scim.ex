defmodule Troupe.Plane.SCIM do
  @moduledoc """
  SCIM 2.0, translated into the identity the plane keeps.

  An identity provider pushes users and groups here; Troupe mirrors them and adds
  nothing. The one thing worth being careful about is which field is the *identity*:
  SCIM's `id` is the provider's handle for the record, and `externalId` — or failing
  that `userName` — is the subject that will appear in an access token at login. Keying
  on the wrong one means a user who logs in is a different person from the one SCIM
  created.

  Where SCIM is disabled, `Troupe.Plane.Login` creates the same rows from the `groups`
  claim. A done item requires both paths to yield the same teams, which is why both end
  in `Troupe.Plane.Identity` rather than in two parallel implementations.

  After the first push a provider asks with a filter whether somebody is already here,
  and changes what it pushed with `PATCH`; Microsoft Entra ID does both for every change,
  so both are read the way it writes them (`Troupe.Plane.SCIM.Filter`,
  `Troupe.Plane.SCIM.Patch`). A `PATCH` changes what a push of the whole resource would,
  is applied whole or not at all, and never makes a person somebody else (Decision 754).
  """

  import Ecto.Query

  alias Troupe.Plane.{Audit, Identity, Principals, Provision, Repo, Settings, Triggers}
  alias Troupe.Plane.Identity.{Group, User}
  alias Troupe.Plane.SCIM.{Connector, Filter, Patch}

  require Logger

  # Who writes a profile's teams again when a group's deletion disables a team on it.
  @scim_actor %{subject: "scim", role: :platform_admin, teams: []}

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  # What a filter may ask about: what a provider matches on before it creates somebody.
  @user_filters %{"userName" => :user_name, "externalId" => :external_id}
  @group_filters %{"displayName" => :display_name, "externalId" => :external_id}

  @typedoc "Why a request was refused: no such resource, or SCIM's `scimType` and a detail."
  @type error :: :not_found | {String.t(), String.t()} | Ecto.Changeset.t()

  @doc """
  Apply a SCIM User resource.

  `active: false` deactivates the person as `deactivate_user/1` does, whether the resource
  came as a `POST` or a `PUT`.
  """
  @spec put_user(map()) :: {:ok, User.t()} | {:error, error()}
  def put_user(resource) do
    attrs = user_attrs(resource)

    with {:ok, subject} <- subject_of(resource),
         {:ok, subject} <- unreserved(subject),
         {:ok, subject} <- subject_for(subject, attrs) do
      save_user(Map.put(attrs, :subject, subject))
    end
  end

  @doc """
  Replace the user the plane gave this id with a SCIM User resource, which is what a `PUT`
  to `/Users/<id>` does (RFC 7644 §3.5.1).

  The resource at that id, and nobody else: a body that would key the person on another
  subject, a different `externalId` or, without one, a different `userName`, is refused as
  a `PATCH` that would is, rather than applied to whoever that subject names.
  """
  @spec replace_user(String.t(), map()) :: {:ok, User.t()} | {:error, error()}
  def replace_user(id, resource) do
    changes = user_attrs(resource)

    with {:ok, user} <- fetch_user(id),
         {:ok, subject} <- subject_of(resource),
         {:ok, _subject} <- unreserved(subject),
         :ok <- same_person(user, changes) do
      update_user(user, changes)
    end
  end

  defp user_attrs(resource) do
    %{
      external_id: Map.get(resource, "externalId"),
      user_name: Map.get(resource, "userName"),
      email: primary_email(resource),
      display_name: display_name(resource),
      active: Map.get(resource, "active", true)
    }
  end

  # The plane's own subjects: a removed person's sessions are owned by `removed:<id>` and a
  # service principal is `svc:<team>/<name>`, and a sign-in under either is refused. A
  # person pushed under one could never sign in, and would be named where those are.
  @reserved ["removed:", "svc:"]

  defp unreserved(subject) do
    if String.starts_with?(subject, @reserved) do
      detail = "#{inspect(subject)} is in a namespace the plane keeps for itself"
      {:error, {"invalidValue", detail <> " (removed: and svc:), and no person's subject"}}
    else
      {:ok, subject}
    end
  end

  @doc """
  Apply a SCIM Group resource, including its membership.

  Members are replaced, not merged: a SCIM push carries the whole list, so a user who
  is absent has been removed, and merging would leave their access behind.
  """
  @spec put_group(map()) :: {:ok, Group.t()} | {:error, term()}
  def put_group(resource) do
    with {:ok, group} <-
           Identity.upsert_group(%{
             external_id: Map.get(resource, "externalId") || Map.fetch!(resource, "id"),
             display_name: Map.get(resource, "displayName") || Map.fetch!(resource, "id")
           }) do
      replace_members(group, Map.get(resource, "members", []))
      maybe_enable_team(group)
      {:ok, group}
    end
  end

  # The connector's switch. A group nobody has made a team of becomes one, named from its
  # display name with the platform's defaults, and the audit trail says `scim` did it. A
  # group that is already a team, or whose name another team holds, is left alone: the
  # first is done, the second is a collision an administrator can see and this cannot.
  defp maybe_enable_team(group) do
    if Connector.teams_from_groups?() do
      attrs = Map.put(Settings.team_defaults(), "enabled_by", "scim")

      case Identity.enable_team_if_new(group, attrs) do
        {:ok, team} ->
          {:ok, _} =
            Audit.record("scim", "team.enable", team.name, %{
              "group" => group.external_id,
              "by" => "scim"
            })

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  # SCIM members reference users by the id this plane gave them.
  defp replace_members(group, members) do
    wanted =
      members
      |> Enum.map(&Map.get(&1, "value"))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Identity.get_user_by_id/1)
      |> Enum.reject(&is_nil/1)

    Identity.set_group_members(group, Enum.map(wanted, & &1.id))
  end

  # The subject a push keys the person on. Somebody nobody is under, who carries an
  # `externalId` a row already has, is that row's person: one a sign-in moved to another
  # claim's value keeps the `externalId` SCIM gave them, and a push that made them again
  # under it was a second row for one person. Only when the row's email or `userName`
  # agrees with the push's, as a sign-in's must (`Identity.adoption/3`); otherwise the
  # push is refused, since a second row cannot hold the same `externalId`, and the pair
  # waits for an administrator.
  defp subject_for(subject, %{external_id: external_id} = attrs) do
    case Identity.adoption(subject, external_id, attrs) do
      :none -> {:ok, subject}
      {:adopt, %User{subject: moved}} -> {:ok, moved}
      {:refused, held} -> refuse_adoption(held, subject)
    end
  end

  defp refuse_adoption(held, subject) do
    Logger.warning(
      "troupe plane: SCIM pushed externalId #{subject}, which the row #{held.id} " <>
        "(under #{held.subject}) holds, and neither the email nor the userName it sent " <>
        "agrees with the row's; refused, and admin.identity.duplicates lists it"
    )

    {:ok, _} =
      Audit.record("scim", "person.adopt_refused", subject, %{
        "subject" => subject,
        "row" => held.id,
        "row_subject" => held.subject,
        "via" => "scim"
      })

    {:error,
     {"uniqueness",
      "externalId #{subject} is held by user #{held.id}, whose email and userName both " <>
        "differ from this push's, so nothing was merged: make one of them agree, or fix " <>
        "the externalId mapping (the pair is in the plane's admin.identity.duplicates)"}}
  end

  @doc """
  Mark a user inactive: what `active: false` does, in a push or a PATCH. The row stays,
  and a later push with `active: true` makes them active again; a `DELETE` is
  `delete_user/1`.
  """
  @spec deactivate_user(String.t()) :: {:ok, User.t()} | {:error, term()}
  def deactivate_user(id) do
    with {:ok, user} <- fetch_user(id), do: update_user(user, %{active: false})
  end

  @doc """
  Remove the user the plane gave this id, which is what a SCIM `DELETE` of one does.

  The row goes, so the id answers `404` from now on, and a tombstone keeps what outlives
  them (`Identity.remove_user/2`): their sessions, read-only under a "removed person"
  marker, and the name the audit trail and every `*_by` already carry. The principals they
  sponsor stop, as a deactivation stops them, and they administer nothing. Somebody the
  provider sends later under the same subject is somebody new.
  """
  @spec delete_user(String.t()) :: {:ok, Identity.Tombstone.t()} | {:error, term()}
  def delete_user(id) do
    with {:ok, user} <- fetch_user(id),
         {:ok, tombstone, effect} <- Identity.remove_user(user, "scim") do
      {:ok, _} = Audit.record("scim", "person.remove", user.subject, effect)
      {:ok, tombstone}
    end
  end

  # Every change SCIM makes to somebody it already has, under the subject they have.
  defp update_user(user, changes), do: save_user(Map.put(changes, :subject, user.subject))

  # Every change SCIM makes to a person, whether a push or a PATCH carried it, so a
  # deactivation is the same however it arrives.
  defp save_user(attrs) do
    if Map.get(attrs, :active) == false do
      # And everything that person was answerable for. A service principal is a
      # credential that starts sessions and spends a budget; one whose sponsor has left
      # the provider has nobody to ask about it, so it stops firing within this push
      # rather than at whatever point somebody notices. One already stopped is left as it
      # is, so the same push again stops nothing more.
      {:ok, _stopped} = Principals.sponsor_left(attrs.subject)
    end

    Identity.upsert_user(attrs)
  end

  # -- filters and PATCH ------------------------------------------------------

  @doc """
  The users a provider's `filter` names, or every user when there is none.

  `userName eq` and `externalId eq` are what a provider matches on, and all this answers;
  anything else is refused as `invalidFilter` (`Troupe.Plane.SCIM.Filter`).
  """
  @spec find_users(String.t() | nil) :: {:ok, [User.t()]} | {:error, error()}
  def find_users(nil), do: {:ok, Identity.list_users()}

  def find_users(filter) do
    with {:ok, attribute, value} <- Filter.parse(filter, @user_filters) do
      {:ok, Identity.find_users(attribute, value)}
    end
  end

  @doc "The groups a provider's `filter` names (`displayName` or `externalId`), or every group."
  @spec find_groups(String.t() | nil) :: {:ok, [Group.t()]} | {:error, error()}
  def find_groups(nil), do: {:ok, Identity.list_groups()}

  def find_groups(filter) do
    with {:ok, attribute, value} <- Filter.parse(filter, @group_filters) do
      {:ok, Identity.find_groups(attribute, value)}
    end
  end

  @doc """
  Apply a SCIM `PatchOp` to the user the plane gave this id.

  It changes what a push of the whole user would, `userName`, `externalId`, `displayName`,
  the address and `active`, and accepts and ignores the attributes the plane does not
  keep, as `put_user/1` does. `active: false` deactivates them as `deactivate_user/1`
  does. A change that would key them on another subject, a different `externalId` or,
  without one, a different `userName`, is refused: a person moves at sign-in, under
  Decision 751, and a push that moved them would leave their sessions behind.
  """
  @spec patch_user(String.t(), map()) :: {:ok, User.t()} | {:error, error()}
  def patch_user(id, body) do
    with {:ok, user} <- fetch_user(id),
         {:ok, operations} <- Patch.operations(body, @user_schema),
         {:ok, changes} <- reduce_ok(operations, %{}, &user_change/2),
         :ok <- same_person(user, changes) do
      update_user(user, changes)
    end
  end

  # One operation, as a change to the row. `add` and `replace` are the same thing on an
  # attribute with one value, which is every one the plane keeps but `emails`, and of
  # those it keeps one: the primary, or the one an operation names.
  defp user_change({:remove, {"username", _filter, _sub}, _value}, _changes),
    do: {:error, {"mutability", "userName is required and cannot be removed"}}

  defp user_change({:remove, {"active", _filter, _sub}, _value}, _changes),
    do: {:error, {"mutability", "active cannot be removed; replace it with false"}}

  defp user_change({:remove, {"externalid", nil, nil}, _value}, changes),
    do: {:ok, Map.put(changes, :external_id, nil)}

  defp user_change({:remove, {"displayname", nil, nil}, _value}, changes),
    do: {:ok, Map.put(changes, :display_name, nil)}

  defp user_change({:remove, {"emails", _filter, sub}, _value}, changes)
       when sub in [nil, "value"],
       do: {:ok, Map.put(changes, :email, nil)}

  defp user_change({:remove, _path, _value}, changes), do: {:ok, changes}

  defp user_change({_set, {"username", nil, nil}, value}, changes),
    do: put_string(changes, :user_name, value, "userName", false)

  defp user_change({_set, {"externalid", nil, nil}, value}, changes),
    do: put_string(changes, :external_id, value, "externalId", true)

  defp user_change({_set, {"displayname", nil, nil}, value}, changes),
    do: put_string(changes, :display_name, value, "displayName", true)

  defp user_change({_set, {"active", nil, nil}, value}, changes) do
    case boolean(value) do
      {:ok, active} -> {:ok, Map.put(changes, :active, active)}
      :error -> {:error, {"invalidValue", "active is true or false, not #{inspect(value)}"}}
    end
  end

  defp user_change({_set, {"emails", nil, nil}, value}, changes) when is_list(value) do
    if Enum.all?(value, &is_map/1),
      do: {:ok, Map.put(changes, :email, primary_email(%{"emails" => value}))},
      else: {:error, {"invalidValue", "an email is an object, in #{inspect(value)}"}}
  end

  defp user_change({_set, {"emails", _filter, nil}, %{} = value}, changes),
    do: put_string(changes, :email, Map.get(value, "value"), "an email's value", true)

  defp user_change({_set, {"emails", _filter, "value"}, value}, changes),
    do: put_string(changes, :email, value, "an email's value", true)

  defp user_change({_set, {"emails", _filter, nil}, value}, _changes),
    do: {:error, {"invalidValue", "emails are objects, not #{inspect(value)}"}}

  defp user_change({_set, _path, _value}, changes), do: {:ok, changes}

  defp put_string(changes, key, value, _name, _nil_allowed) when is_binary(value),
    do: {:ok, Map.put(changes, key, value)}

  defp put_string(changes, key, nil, _name, true), do: {:ok, Map.put(changes, key, nil)}

  defp put_string(_changes, _key, value, name, _nil_allowed),
    do: {:error, {"invalidValue", "#{name} is a string, not #{inspect(value)}"}}

  # Entra sends `"False"` for `false` unless the application opted in to the fix.
  defp boolean(value) when is_boolean(value), do: {:ok, value}

  defp boolean(value) when is_binary(value) do
    case String.downcase(value) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  defp boolean(_value), do: :error

  # The subject a push of this person would key them on (`subject_of/1`), before the
  # change and after it. Different is a second person under the first one's id.
  defp same_person(user, changes) do
    before = user.external_id || user.user_name || user.subject

    after_change =
      Map.get(changes, :external_id, user.external_id) ||
        Map.get(changes, :user_name, user.user_name) || user.subject

    if before == after_change do
      :ok
    else
      detail = "this would key the user on #{inspect(after_change)}, not #{inspect(before)}"
      {:error, {"mutability", detail <> "; a person moves at sign-in, not by a PATCH"}}
    end
  end

  @doc """
  Apply a SCIM `PatchOp` to the group the plane gave this id.

  Membership is what arrives this way: `add` and `remove` on `members`, by the ids this
  plane gave the users, and `remove` on `members[value eq "<id>"]`. Unlike a push of the
  whole group, only the members named change. `displayName` can change; `externalId` is
  what a groups claim names the group by, and cannot.
  """
  @spec patch_group(String.t(), map()) :: {:ok, Group.t()} | {:error, error()}
  def patch_group(id, body) do
    with {:ok, operations} <- Patch.operations(body, @group_schema) do
      Repo.transaction(fn -> id |> lock_group() |> apply_group(operations) |> or_rollback() end)
    end
  end

  defp or_rollback({:ok, result}), do: result
  defp or_rollback({:error, reason}), do: Repo.rollback(reason)

  # A change to the members reads them and writes them back, so two at once for one group
  # would lose one of them: the row is held until the change is written.
  defp lock_group(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.one(from(g in Group, where: g.id == ^uuid, lock: "FOR UPDATE"))
      :error -> nil
    end
  end

  defp apply_group(nil, _operations), do: {:error, :not_found}

  defp apply_group(group, operations) do
    members = MapSet.new(Identity.members_of(group), & &1.id)

    with {:ok, {attrs, wanted}} <-
           reduce_ok(operations, {%{}, members}, &group_change(group, &1, &2)),
         {:ok, group} <- rename_group(group, attrs) do
      if wanted != members, do: :ok = Identity.set_group_members(group, MapSet.to_list(wanted))
      {:ok, group}
    end
  end

  defp group_change(_group, {:add, {"members", nil, nil}, value}, {attrs, members}) do
    with {:ok, ids} <- member_ids(value), do: {:ok, {attrs, MapSet.union(members, known(ids))}}
  end

  defp group_change(_group, {:replace, {"members", nil, nil}, value}, {attrs, _members}) do
    with {:ok, ids} <- member_ids(value), do: {:ok, {attrs, known(ids)}}
  end

  defp group_change(_group, {:remove, {"members", nil, nil}, nil}, {attrs, _members}),
    do: {:ok, {attrs, MapSet.new()}}

  defp group_change(_group, {:remove, {"members", nil, nil}, value}, {attrs, members}) do
    with {:ok, ids} <- member_ids(value),
         do: {:ok, {attrs, MapSet.difference(members, uuids(ids))}}
  end

  defp group_change(_group, {:remove, {"members", filter, nil}, _value}, {attrs, members})
       when is_binary(filter) do
    with {:ok, :value, id} <- Filter.parse(filter, %{"value" => :value}),
         do: {:ok, {attrs, MapSet.difference(members, uuids([id]))}}
  end

  defp group_change(_group, {_op, {"members", _filter, _sub}, _value}, _acc) do
    detail = ~s(members are added by value, and removed by value or by members[value eq "<id>"])
    {:error, {"invalidPath", detail}}
  end

  defp group_change(_group, {set, {"displayname", nil, nil}, value}, {attrs, members})
       when set in [:add, :replace] and is_binary(value) and value != "",
       do: {:ok, {Map.put(attrs, :display_name, value), members}}

  defp group_change(_group, {:remove, {"displayname", _filter, _sub}, _value}, _acc),
    do: {:error, {"mutability", "displayName is required and cannot be removed"}}

  defp group_change(_group, {_set, {"displayname", _filter, _sub}, value}, _acc),
    do: {:error, {"invalidValue", "displayName is a string, not #{inspect(value)}"}}

  defp group_change(%Group{external_id: same}, {set, {"externalid", nil, nil}, same}, acc)
       when set in [:add, :replace],
       do: {:ok, acc}

  defp group_change(_group, {_op, {"externalid", _filter, _sub}, _value}, _acc) do
    detail = "a group's externalId is what a groups claim names it by, and does not change"
    {:error, {"mutability", detail}}
  end

  defp group_change(_group, _operation, acc), do: {:ok, acc}

  defp member_ids(%{} = member), do: member_ids([member])

  defp member_ids(members) when is_list(members) do
    if Enum.all?(members, &match?(%{"value" => id} when is_binary(id), &1)),
      do: {:ok, Enum.map(members, & &1["value"])},
      else: {:error, {"invalidValue", "a member is an object whose value is a user's id"}}
  end

  defp member_ids(value),
    do: {:error, {"invalidValue", "members is a list, not #{inspect(value)}"}}

  # An id nobody has is nobody to add, as in a push of the whole group.
  defp known(ids) do
    ids
    |> Enum.map(&Identity.get_user_by_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(& &1.id)
  end

  defp uuids(ids) do
    for id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], into: MapSet.new(), do: uuid
  end

  defp rename_group(group, %{display_name: name}),
    do: Identity.upsert_group(%{external_id: group.external_id, display_name: name})

  defp rename_group(group, _attrs), do: {:ok, group}

  @doc """
  Remove a group, which is what a SCIM delete of one does.

  The row goes, with its members and its links, and the id answers `404`. A team built on
  it and on no other group is disabled, as an administrator disabling it would: its grants
  are revoked, its sessions go read-only, its triggers go, and the audit trail says `scim`
  did it. A team that draws from other groups too keeps them, and is recorded as enabled
  from one of them instead.
  """
  @spec delete_group(String.t()) :: {:ok, Group.t()} | {:error, :not_found}
  def delete_group(id) do
    case Identity.get_group_by_id(id) do
      nil ->
        {:error, :not_found}

      group ->
        {disabled, kept} =
          group |> Identity.teams_built_on() |> Enum.split_with(&(others(&1, group) == []))

        Enum.each(disabled, &disable_team(&1, group))
        Enum.each(kept, &record_other_group(&1, group))

        {:ok, _} = Repo.delete(group)

        {:ok, _} =
          Audit.record("scim", "group.delete", group.external_id, %{
            "display_name" => group.display_name,
            "teams_disabled" => Enum.map(disabled, & &1.name),
            "teams_kept" => Enum.map(kept, & &1.name)
          })

        {:ok, group}
    end
  end

  defp others(team, group) do
    team |> Identity.links_of() |> Enum.reject(&(&1.group_id == group.id))
  end

  # What `Admin.team_disable/2` does, in its order, with `scim` as the one who did it:
  # every grant revoked and the profile's teams written again, then the triggers, which a
  # principal cannot outlive, then the row.
  defp disable_team(team, group) do
    for grant <- Identity.grants_for_team(team) do
      :ok = Identity.revoke(team, grant.profile)

      case Provision.sync_teams(grant.profile, @scim_actor) do
        {:ok, _state} ->
          :ok

        {:error, reason} ->
          Logger.warning("troupe plane: #{grant.profile}'s teams are stale: #{inspect(reason)}")
      end
    end

    Enum.each(Triggers.list(team), &Triggers.delete/1)
    {:ok, _} = Identity.disable_team(team)

    {:ok, _} =
      Audit.record("scim", "team.disable", team.name, %{
        "group" => group.external_id,
        "by" => "scim"
      })
  end

  # `group_id` records which group a team was enabled from, and the database deletes a team
  # with the group it records.
  defp record_other_group(%{group_id: group_id} = team, %{id: group_id} = group) do
    [link | _] = others(team, group)
    {:ok, _} = Identity.update_team(team, %{group_id: link.group_id})
  end

  defp record_other_group(_team, _group), do: :ok

  defp fetch_user(id) do
    case Identity.get_user_by_id(id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp reduce_ok(items, acc, fun) do
    Enum.reduce_while(items, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # -- rendering --------------------------------------------------------------

  @doc "A user as SCIM describes it."
  @spec render_user(User.t()) :: map()
  def render_user(%User{} = user) do
    %{
      "schemas" => [@user_schema],
      "id" => user.id,
      "externalId" => user.external_id,
      # As the provider last sent it, or the subject for somebody no push has named.
      "userName" => user.user_name || user.subject,
      "displayName" => user.display_name,
      "active" => user.active,
      "emails" => emails(user),
      "meta" => meta("User", user.id, user.updated_at)
    }
  end

  defp emails(%User{email: nil}), do: []
  defp emails(%User{email: email}), do: [%{"value" => email, "primary" => true}]

  @doc "A group as SCIM describes it, with its members."
  @spec render_group(Group.t(), [User.t()]) :: map()
  def render_group(%Group{} = group, members \\ []) do
    %{
      "schemas" => [@group_schema],
      "id" => group.id,
      "externalId" => group.external_id,
      "displayName" => group.display_name,
      "members" =>
        Enum.map(members, &%{"value" => &1.id, "display" => &1.display_name || &1.subject}),
      "meta" => meta("Group", group.id, group.updated_at)
    }
  end

  @doc """
  A group as a request's query asked for it: with its members, unless `excludedAttributes`
  names them, as Entra's lookups do. For a big group they are most of the answer.
  """
  @spec render_group_for(Group.t(), map()) :: map()
  def render_group_for(%Group{} = group, params) do
    excluded =
      case Map.get(params, "excludedAttributes") do
        names when is_binary(names) -> names |> String.downcase() |> String.split(",", trim: true)
        _ -> []
      end

    if "members" in Enum.map(excluded, &String.trim/1),
      do: group |> render_group() |> Map.delete("members"),
      else: render_group(group, Identity.members_of(group))
  end

  @doc "A SCIM list response."
  @spec render_list([map()], non_neg_integer()) :: map()
  def render_list(resources, total \\ nil) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total || length(resources),
      "itemsPerPage" => length(resources),
      "startIndex" => 1,
      "Resources" => resources
    }
  end

  @doc "A SCIM error response (RFC 7644 §3.12): the status, and `scimType` where SCIM has one."
  @spec render_error(pos_integer(), String.t() | nil, String.t()) :: map()
  def render_error(status, scim_type, detail) do
    body = %{
      "schemas" => [@error_schema],
      "status" => Integer.to_string(status),
      "detail" => detail
    }

    if scim_type, do: Map.put(body, "scimType", scim_type), else: body
  end

  defp meta(kind, id, updated_at) do
    %{
      "resourceType" => kind,
      "location" => "/scim/v2/#{kind}s/#{id}",
      "lastModified" => updated_at && DateTime.to_iso8601(updated_at)
    }
  end

  # -- reading a resource -----------------------------------------------------

  # `externalId` is the identity provider's own id for the person and is what shows up in
  # a token as the claim `subject_claim` names — `sub`, or for Entra ID `oid`, once its
  # mapping sends `objectId`; `userName` is the fallback for providers that
  # do not send one. A body with neither, or with one that is not a string of something,
  # names nobody, and is the provider's to fix rather than a crash.
  defp subject_of(resource) do
    case {Map.get(resource, "externalId"), Map.get(resource, "userName")} do
      {external_id, _user_name} when is_binary(external_id) and external_id != "" ->
        {:ok, external_id}

      {nil, user_name} when is_binary(user_name) and user_name != "" ->
        {:ok, user_name}

      _neither ->
        {:error,
         {"invalidValue",
          "a user names who they are by a non-empty externalId, or without one a non-empty userName"}}
    end
  end

  defp primary_email(resource) do
    resource
    |> Map.get("emails", [])
    |> Enum.find(&Map.get(&1, "primary", false))
    |> case do
      %{"value" => value} -> value
      _ -> resource |> Map.get("emails", []) |> List.first() |> then(&(&1 && &1["value"]))
    end
  end

  defp display_name(resource) do
    Map.get(resource, "displayName") ||
      get_in(resource, ["name", "formatted"]) ||
      join_name(resource) ||
      Map.get(resource, "userName")
  end

  defp join_name(resource) do
    given = get_in(resource, ["name", "givenName"])
    family = get_in(resource, ["name", "familyName"])

    case Enum.reject([given, family], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end
end
