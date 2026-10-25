defmodule Troupe.Plane.Invites do
  @moduledoc """
  A person invites another into their session by name, to follow it or to steer it (#765).

  **A pod session's invitation is its grant made visible.** Inviting writes the ACL row
  `session.grant` writes (`observe` is a viewer, `control` a collaborator) and a row here
  that says who invited whom and when, which is what the invitee's list and the session's
  head read. Taking it back removes both. The pod holding the session is told, so a
  connection already open meets the change at its next command, and the session's log
  gets one line, `session_invited` or `session_uninvited`.

  **A private session's key follows the invitation.** Its log is sealed on its owner's
  machine under a key in their own subtree at the key manager, which the plane cannot read.
  So the owner's daemon puts that key into the invitee's own slot, under
  `troupe/people/<invitee>/invited/<session>/`, where any person's credential may create a
  key and only the invitee's may read one (`Troupe.KMS.Policy.person/2`), and tells the
  plane the path: a row here per key the session has been sealed under. The plane gives the
  paths to the invitee alone, can destroy what is at them (`Troupe.KMS.Policy.invites/1`)
  and cannot read it. Taking an invitation back destroys the invitee's copies and marks the
  session `rekey_due`; the owner's daemon seals what follows under a new key that only the
  people still invited are given (`rekeyed/3`). What the person removed could read before
  stays readable to whoever kept it: an invitation cannot be taken back for what it already
  showed.

  **Who may be invited.** Into a pod session, anybody the session's profile covers: a
  member of a team granted that profile, whose rules are the ones they would act under.
  Into a private session, which has no profile, anybody who shares a team with its owner. A
  platform administrator may be invited into either by anybody. Nobody else, and never a
  service principal.

  **Who is told.** The invitee, over their watch (`Troupe.Plane.Remote.Watch`), as
  `invites.changed` with their whole list, whenever an invitation to them is made, changed
  or taken back.
  """

  import Ecto.Query

  alias Troupe.KMS
  alias Troupe.Plane.{Admin, Audit, Identity, Repo}
  alias Troupe.Plane.Identity.{Membership, Team, TeamGroupLink, User}
  alias Troupe.Plane.Sessions
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Plane.Tokens.Credential
  alias Troupe.Protocol.Error

  require Logger

  defmodule Invite do
    @moduledoc "One invitation: into which session, whom, at which role, by whom and when."

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "session_invites" do
      field :session_id, :string
      field :subject, :string
      field :role, :string
      field :invited_by, :string
      field :invited_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    @type t :: %__MODULE__{}

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(invite, attrs) do
      invite
      |> cast(attrs, [:session_id, :subject, :role, :invited_by, :invited_at])
      |> validate_required([:session_id, :subject, :role, :invited_by, :invited_at])
      |> validate_inclusion(:role, ["observe", "control"])
      |> unique_constraint([:session_id, :subject])
    end
  end

  defmodule Key do
    @moduledoc """
    Where one generation of a private session's key was put for one invitee: a path in
    their own slot at the key manager, which the plane holds and cannot read.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "session_invite_keys" do
      field :session_id, :string
      field :subject, :string
      field :key_version, :integer
      field :slot, :string

      timestamps(type: :utc_datetime_usec)
    end

    @type t :: %__MODULE__{}

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(key, attrs) do
      key
      |> cast(attrs, [:session_id, :subject, :key_version, :slot])
      |> validate_required([:session_id, :subject, :key_version, :slot])
      |> validate_number(:key_version, greater_than: 0)
      |> unique_constraint([:session_id, :subject, :key_version])
    end
  end

  @roles ~w(observe control)
  @topic "invites"
  @search_limit 10
  @search_max 25

  @doc "The roles an invitation carries."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The ACL role an invitation is: a viewer to follow, a collaborator to steer."
  @spec acl_role(String.t()) :: String.t()
  def acl_role("control"), do: "collaborator"
  def acl_role(_observe), do: "viewer"

  # -- who ----------------------------------------------------------------------

  @doc """
  The person a name means: their subject, or their email in any case. Active people only,
  and never a service principal, whose sessions are a team's and who has no one to tell.
  """
  @spec person(String.t() | nil) :: User.t() | nil
  def person(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" or String.starts_with?(name, "svc:") ->
        nil

      user = active(Identity.get_user(name)) ->
        user

      true ->
        Repo.one(
          from(u in User,
            where: fragment("lower(?)", u.email) == ^String.downcase(name) and u.active == true,
            limit: 1
          )
        )
    end
  end

  def person(_name), do: nil

  defp active(%User{active: true, kind: kind} = user) when kind != "service", do: user
  defp active(_other), do: nil

  @doc """
  Whether `invitee` may be invited into `session`: `:ok`, or the refusal that says why.
  The owner is not invited into their own session.
  """
  @spec eligible(Session.t(), User.t() | nil) :: :ok | {:error, Error.t()}
  def eligible(_session, nil) do
    {:error,
     Error.new(:not_found, %{
       kind: "person",
       reason: "nobody of that name has signed in to this plane, so they cannot be invited yet"
     })}
  end

  def eligible(%Session{owner_subject: subject}, %User{subject: subject}) do
    {:error, Error.new(:invalid_params, %{reason: "that is the session's own owner"})}
  end

  def eligible(%Session{} = session, %User{} = invitee) do
    cond do
      platform_admin?(invitee) -> :ok
      covered?(session, invitee) -> :ok
      session.kind == "private" -> refuse(invitee, "shares no team with this session's owner")
      true -> refuse(invitee, "not on this profile's teams", profile: session.profile)
    end
  end

  defp refuse(invitee, reason, extra \\ []) do
    {:error,
     Error.new(:forbidden, Map.merge(%{person: invitee.subject, reason: reason}, Map.new(extra)))}
  end

  defp platform_admin?(user), do: Admin.actor_for(user).role == :platform_admin

  # A pod session's profile's teams, whose rules the invitee would act under; a private
  # session's owner's teams, since it has no profile.
  defp covered?(session, invitee) do
    teams = covering_teams(session)
    Enum.any?(Identity.teams_for(invitee), &(&1.id in teams))
  end

  defp covering_teams(%Session{kind: "private", owner_subject: owner}) do
    case Identity.get_user(owner) do
      %User{} = user -> user |> Identity.teams_for() |> Enum.map(& &1.id)
      nil -> []
    end
  end

  defp covering_teams(%Session{profile: profile}) when is_binary(profile) do
    profile |> Identity.grants_for_profile() |> Enum.map(& &1.team_id)
  end

  defp covering_teams(_session), do: []

  @doc """
  People whose name, email or subject starts with `query`, for a picker: those who share a
  team with `caller`, and, given a session, those its profile covers. Never more than the
  caller could invite into it, or would meet in their own teams.
  """
  @spec search(User.t(), String.t(), Session.t() | nil, pos_integer() | nil) :: [map()]
  def search(%User{} = caller, query, session \\ nil, limit \\ nil) do
    prefix = String.downcase(String.trim(query)) <> "%"
    limit = min(max(limit || @search_limit, 1), @search_max)
    owner = session && session.owner_subject

    teams =
      Enum.uniq(
        Enum.map(Identity.teams_for(caller), & &1.id) ++
          if(session, do: covering_teams(session), else: [])
      )

    from(u in User,
      join: m in Membership,
      on: m.user_id == u.id,
      join: l in TeamGroupLink,
      on: l.group_id == m.group_id,
      join: t in Team,
      on: t.id == l.team_id,
      where: t.id in ^teams and u.active == true and u.subject != ^caller.subject,
      where:
        like(fragment("lower(?)", u.display_name), ^prefix) or
          like(fragment("lower(?)", u.email), ^prefix) or
          like(fragment("lower(?)", u.subject), ^prefix),
      distinct: u.id,
      select: %{"subject" => u.subject, "display_name" => u.display_name, "email" => u.email}
    )
    |> Repo.all()
    |> Enum.reject(&(&1["subject"] == owner))
    |> Enum.sort_by(&String.downcase(&1["display_name"] || &1["subject"]))
    |> Enum.take(limit)
  end

  # -- inviting -----------------------------------------------------------------

  @doc """
  Invite `invitee` into `session` at `role`, by `by`. A pod session's ACL row is written; a
  private session's `keys`, where its owner's daemon put each generation of its key in the
  invitee's slot, `[%{"key_version", "slot"}]`, are kept. Inviting again changes the role.
  """
  @spec invite(Session.t(), User.t(), String.t(), String.t(), term()) ::
          {:ok, Invite.t()} | {:error, Error.t()}
  def invite(%Session{} = session, %User{} = invitee, role, by, keys \\ []) do
    with :ok <- known_role(role),
         :ok <- eligible(session, invitee),
         {:ok, keys} <- invite_keys(session, invitee, keys) do
      attrs = %{
        session_id: session.id,
        subject: invitee.subject,
        role: role,
        invited_by: by,
        invited_at: DateTime.utc_now()
      }

      Repo.transaction(fn ->
        existing = Repo.get_by(Invite, session_id: session.id, subject: invitee.subject)

        invite =
          case (existing || %Invite{}) |> Invite.changeset(attrs) |> Repo.insert_or_update() do
            {:ok, invite} -> invite
            {:error, changeset} -> Repo.rollback(invalid(changeset))
          end

        Enum.each(keys, &put_key(session, invitee.subject, &1))

        if session.kind != "private" do
          {:ok, _acl} = Sessions.grant_access(session.id, invitee.subject, acl_role(role), by)
        end

        invite
      end)
      |> case do
        {:ok, invite} ->
          {:ok, _} =
            Audit.record(by, "session.invite", session.id, %{
              "invitee" => invitee.subject,
              "role" => role
            })

          changed([invitee.subject])
          {:ok, invite}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp known_role(role) when role in @roles, do: :ok

  defp known_role(_role),
    do: {:error, Error.new(:invalid_params, %{field: "role", reason: "role is observe or control"})}

  # A private session's invitation carries where its key was put for the invitee, once for
  # every generation it has been sealed under: one missing would leave part of the log
  # unreadable to them, and the plane cannot put one there itself. A pod session's carries
  # none.
  defp invite_keys(%Session{kind: "private"} = session, invitee, keys) do
    prefix = KMS.invited_prefix(User.kms_name(invitee), session.id)
    keys = for %{} = entry <- List.wrap(keys), do: %{key_version: entry["key_version"], slot: entry["slot"]}
    versions = keys |> Enum.map(& &1.key_version) |> Enum.sort()

    cond do
      versions != Enum.to_list(1..session.key_version) ->
        {:error,
         Error.new(:invalid_params, %{
           field: "keys",
           reason:
             "a private session's invitation carries its key, put in the invitee's slot once " <>
               "for each of its #{session.key_version} key(s), from the machine that seals it",
           key_version: session.key_version
         })}

      not Enum.all?(keys, &in_slot?(&1.slot, prefix)) ->
        {:error, Error.new(:invalid_params, %{field: "keys", reason: "each key is in the invitee's own slot", prefix: prefix})}

      true ->
        {:ok, keys}
    end
  end

  defp invite_keys(_session, _invitee, _keys), do: {:ok, []}

  # Under the invitee's prefix and one segment below it, so a path cannot name the
  # invitee's other secrets, which the plane would then destroy at a removal.
  defp in_slot?(slot, prefix) when is_binary(slot) do
    case String.split_at(slot, String.length(prefix)) do
      {^prefix, rest} -> rest =~ ~r/\Ak\d+-[A-Za-z0-9_-]{8,64}\z/
      _other -> false
    end
  end

  defp in_slot?(_slot, _prefix), do: false

  defp put_key(session, subject, key) do
    attrs = Map.merge(key, %{session_id: session.id, subject: subject})

    existing =
      Repo.get_by(Key, session_id: session.id, subject: subject, key_version: key.key_version)

    case (existing || %Key{}) |> Key.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, _row} -> :ok
      {:error, changeset} -> Repo.rollback(invalid(changeset))
    end
  end

  defp invalid(changeset), do: Error.new(:invalid_params, %{reason: inspect(changeset.errors)})

  @doc """
  Take back `subject`'s invitation into `session`, by `by`. A pod session's ACL row goes
  with it; a private session's copies of its key in their slot are destroyed, and the
  session is `rekey_due` until its owner's daemon has sealed under a key they do not have.
  `not_found` for a person not invited.
  """
  @spec uninvite(Session.t(), String.t(), String.t()) :: {:ok, Invite.t()} | {:error, Error.t()}
  def uninvite(%Session{} = session, subject, by) do
    case Repo.get_by(Invite, session_id: session.id, subject: subject) do
      nil ->
        {:error, Error.new(:not_found, %{kind: "invitation", person: subject})}

      %Invite{} = invite ->
        kept = destroy_slots(from(k in Key, where: k.session_id == ^session.id and k.subject == ^subject))

        {:ok, _} =
          Repo.transaction(fn ->
            Repo.delete!(invite)

            if session.kind == "private" do
              Repo.update_all(from(s in Session, where: s.id == ^session.id), set: [rekey_due: true])
            else
              Sessions.revoke_access(session.id, subject)
            end
          end)

        {:ok, _} =
          Audit.record(by, "session.uninvite", session.id, %{
            "invitee" => subject,
            "copies_kept" => kept
          })

        changed([subject])
        {:ok, invite}
    end
  end

  @doc """
  A private session sealed from now on under key `version`, put for each person still
  invited: `[%{"subject", "slot"}]`. Answers the session, no longer `rekey_due`. Refused
  where the version is not this one or the next, or a person still invited has no key in
  it: they would lose what follows. The same version again is a retry.
  """
  @spec rekeyed(Session.t(), term(), term()) :: {:ok, Session.t()} | {:error, Error.t()}
  def rekeyed(%Session{kind: "private"} = session, version, keys)
      when is_integer(version) and is_list(keys) do
    invited = session.id |> of_session() |> Map.new(&{&1.subject, &1})

    given =
      for %{"subject" => s, "slot" => slot} <- keys, is_map_key(invited, s), into: %{}, do: {s, slot}

    missing = invited |> Map.keys() |> Enum.reject(&Map.has_key?(given, &1)) |> Enum.sort()

    misplaced =
      Enum.reject(given, fn {subject, slot} ->
        in_slot?(slot, KMS.invited_prefix(Identity.kms_name_of(subject), session.id))
      end)

    cond do
      version not in [session.key_version, session.key_version + 1] ->
        {:error,
         Error.new(:conflict, %{
           reason: "the session is at key #{session.key_version}",
           key_version: session.key_version
         })}

      missing != [] ->
        {:error,
         Error.new(:invalid_params, %{
           field: "keys",
           reason: "every person still invited is given the new key",
           missing: missing
         })}

      misplaced != [] ->
        {:error, Error.new(:invalid_params, %{field: "keys", reason: "each key is in its invitee's own slot"})}

      true ->
        Repo.transaction(fn ->
          Enum.each(given, fn {subject, slot} ->
            put_key(session, subject, %{key_version: version, slot: slot})
          end)

          {1, [updated]} =
            Repo.update_all(
              from(s in Session, where: s.id == ^session.id, select: s),
              set: [key_version: version, rekey_due: false, updated_at: DateTime.utc_now()]
            )

          updated
        end)
        |> case do
          {:ok, updated} ->
            {:ok, _} =
              Audit.record(session.owner_subject, "session.rekeyed", session.id, %{
                "key_version" => version
              })

            {:ok, updated}

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  def rekeyed(%Session{kind: "private"}, _version, _keys),
    do: {:error, Error.new(:invalid_params, %{field: "key_version", reason: "a key version and the keys"})}

  def rekeyed(_session, _version, _keys),
    do: {:error, Error.new(:invalid_params, %{reason: "only a private session is sealed under keys of its own"})}

  # -- at an erasure ------------------------------------------------------------------

  @doc """
  Destroy every copy of a session's key in its invitees' slots, with the plane's
  credential, which may destroy one and read none. `:ok` once none is left; otherwise the
  rows are kept, so the erasure that asked is still pending and tries again.
  """
  @spec destroy_copies(String.t()) :: :ok | {:error, term()}
  def destroy_copies(session_id) do
    case destroy_slots(from(k in Key, where: k.session_id == ^session_id)) do
      0 -> :ok
      kept -> {:error, {:copies_kept, kept}}
    end
  end

  @doc """
  Everything about a session's invitations, once its key and every copy are gone: the rows,
  and every invitee told it is no longer theirs to see.
  """
  @spec forget(String.t()) :: :ok
  def forget(session_id) do
    subjects = Repo.all(from(i in Invite, where: i.session_id == ^session_id, select: i.subject))
    Repo.delete_all(from(k in Key, where: k.session_id == ^session_id))
    Repo.delete_all(from(i in Invite, where: i.session_id == ^session_id))
    changed(subjects)
  end

  # Each row's copy destroyed, and the row deleted once it is. Answers how many are left.
  defp destroy_slots(query) do
    query
    |> Repo.all()
    |> Enum.count(fn key ->
      case destroy_slot(key.slot) do
        :ok ->
          Repo.delete!(key)
          false

        {:error, reason} ->
          Logger.warning(
            "troupe plane: the copy of #{key.session_id}'s key for #{key.subject} was not destroyed: " <>
              inspect(reason)
          )

          true
      end
    end)
  end

  defp destroy_slot(path) do
    config = Application.get_env(:troupe_plane, :transit, [])

    with {:ok, token} <- Credential.fetch(config) do
      options = [
        token: token,
        address: config[:address],
        mount: Application.get_env(:troupe_plane, :kms_mount, "secret")
      ]

      case KMS.adapter().destroy_at(path, options) do
        {:error, {:unexpected_status, 403}} = refused ->
          Credential.forget(config, token)
          refused

        result ->
          result
      end
    end
  end

  # -- reading ------------------------------------------------------------------

  @doc "Every invitation into a session, the oldest first."
  @spec of_session(String.t()) :: [Invite.t()]
  def of_session(session_id) do
    Repo.all(from(i in Invite, where: i.session_id == ^session_id, order_by: [asc: i.invited_at]))
  end

  @doc "The invitation `subject` holds into a session, or `nil`."
  @spec invitation(String.t(), String.t()) :: Invite.t() | nil
  def invitation(session_id, subject),
    do: Repo.get_by(Invite, session_id: session_id, subject: subject)

  @doc "Where a session's keys were put for `subject`, by generation."
  @spec keys_for(String.t(), String.t()) :: [Key.t()]
  def keys_for(session_id, subject) do
    Repo.all(
      from(k in Key,
        where: k.session_id == ^session_id and k.subject == ^subject,
        order_by: [asc: k.key_version]
      )
    )
  end

  @doc "A session's invitations as its head lists them: whom, at which role, by whom, when."
  @spec rows_of(String.t()) :: [map()]
  def rows_of(session_id), do: session_id |> of_session() |> Enum.map(&invitee_json/1)

  defp invitee_json(%Invite{} = invite) do
    person = Identity.get_user(invite.subject)

    %{
      "subject" => invite.subject,
      "display_name" => person && person.display_name,
      "email" => person && person.email,
      "role" => invite.role,
      "invited_by" => invite.invited_by,
      "invited_at" => DateTime.to_iso8601(invite.invited_at)
    }
  end

  @doc """
  The invitations to `user`, as their list shows them: the session, whose it is, at which
  role, by whom and when. A session erased, or being erased, is not listed.
  """
  @spec to(User.t()) :: [map()]
  def to(%User{subject: subject}) do
    from(i in Invite,
      join: s in Session,
      on: s.id == i.session_id,
      where: i.subject == ^subject and s.state not in ["erased", "erasure_pending"],
      order_by: [desc: i.invited_at],
      select: {i, s}
    )
    |> Repo.all()
    |> Enum.map(fn {invite, session} -> invitation_json(invite, session) end)
  end

  defp invitation_json(%Invite{} = invite, %Session{} = session) do
    owner = Identity.get_user(session.owner_subject)
    by = Identity.get_user(invite.invited_by)

    %{
      "session_id" => session.id,
      "kind" => session.kind,
      "title" => session.title,
      "profile" => session.profile,
      "state" => session.state,
      "owner" => session.owner_subject,
      "owner_name" => owner && owner.display_name,
      "role" => invite.role,
      "invited_by" => invite.invited_by,
      "invited_by_name" => by && by.display_name,
      "invited_at" => DateTime.to_iso8601(invite.invited_at)
    }
  end

  # -- telling the people it concerns -----------------------------------------------

  @doc """
  Hear which people's invitations changed: a person's watch subscribes, and is sent
  `{:invites_changed, subjects}`, on every replica.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Troupe.Plane.PubSub, @topic)

  @doc "Tell every watch that these people's invitations changed, once the rows say so."
  @spec changed([String.t()]) :: :ok
  def changed([]), do: :ok

  def changed(subjects) when is_list(subjects) do
    Phoenix.PubSub.broadcast(Troupe.Plane.PubSub, @topic, {:invites_changed, Enum.uniq(subjects)})
  end
end
