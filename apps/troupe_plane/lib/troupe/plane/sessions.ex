defmodule Troupe.Plane.Sessions do
  @moduledoc """
  The session index, and who may see what.

  Metadata only. The interesting operations are the ones that must not be decided
  twice: placing a session on a pod, and bumping its epoch when it is activated
  somewhere else. Both are conditional writes here rather than read-then-write, so two
  replicas racing produce one winner and one clear refusal.
  """

  import Ecto.Query

  alias Troupe.Plane.Fleet.Worker
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Repo
  alias Troupe.Plane.Sessions.{ACL, Anchor, Session}

  # -- creating and placing ---------------------------------------------------

  @doc "Record a session the plane has agreed to create."
  @spec create(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    attrs = Map.put_new(attrs, :last_active_at, DateTime.utc_now())

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Put a session on a pod, and count it as active.

  Written in the same call that grants the reservation, so a placement that existed
  only in a process cannot be lost with the replica that made it.
  """
  @spec place(String.t(), Worker.t()) :: {:ok, Session.t()} | {:error, term()}
  def place(session_id, %Worker{} = worker) do
    now = DateTime.utc_now()

    # One statement rather than a read and a write: this is on the path of every
    # create, behind a single actor, and two round trips there is two round trips every
    # session pays for.
    {count, sessions} =
      Repo.update_all(
        from(s in Session, where: s.id == ^session_id, select: s),
        set: [worker_id: worker.id, state: "active", last_active_at: now, updated_at: now]
      )

    case {count, sessions} do
      {1, [session]} -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Take a session off its pod, returning which pod that was.

  Which pod it *was* on has to be read before it is cleared, so this is two statements
  where `place/2` is one. Releasing is not on the path of every create, so that is the
  right way round.
  """
  @spec unplace(String.t()) :: {:ok, Ecto.UUID.t() | nil} | :ok
  def unplace(session_id) do
    case Repo.one(from s in Session, where: s.id == ^session_id, select: s.worker_id) do
      nil ->
        :ok

      worker_id ->
        Repo.update_all(
          from(s in Session, where: s.id == ^session_id),
          set: [worker_id: nil, updated_at: DateTime.utc_now()]
        )

        {:ok, worker_id}
    end
  end

  @doc "How many active sessions each pod of a profile is holding, from the database."
  @spec active_counts_by_worker(String.t()) :: %{Ecto.UUID.t() => non_neg_integer()}
  def active_counts_by_worker(profile) do
    Repo.all(
      from s in Session,
        where: s.profile == ^profile and s.state == "active" and not is_nil(s.worker_id),
        group_by: s.worker_id,
        select: {s.worker_id, count(s.id)}
    )
    |> Map.new()
  end

  # -- lifecycle --------------------------------------------------------------

  @doc """
  Bump a session's epoch, but only if it is still dormant.

  The condition is the whole point. Two activations racing both read "dormant"; the
  update is what decides between them, and the loser is told the session is no longer
  dormant rather than being handed a second epoch.
  """
  @spec activate(String.t()) :: {:ok, Session.t()} | {:error, :not_dormant | :not_found}
  def activate(session_id) do
    {count, sessions} =
      Repo.update_all(
        from(s in Session,
          where: s.id == ^session_id and s.state == "dormant",
          select: s
        ),
        inc: [epoch: 1],
        set: [state: "active", last_active_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
      )

    case {count, sessions} do
      {1, [session]} -> {:ok, session}
      {0, _} -> if Repo.get(Session, session_id), do: {:error, :not_dormant}, else: {:error, :not_found}
    end
  end

  @doc "Record that a session has gone dormant, with the sequence it sealed at."
  @spec dormant(String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def dormant(session_id, attrs \\ %{}) do
    put_fields(session_id, Map.merge(attrs, %{state: "dormant", worker_id: nil}))
  end

  @doc "Make a session read-only, because its profile is gone or its team lost the grant."
  @spec read_only(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def read_only(session_id), do: put_fields(session_id, %{state: "read_only", worker_id: nil})

  @doc "Record a sealed segment: the index's view of how far a session has got."
  @spec seal(String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def seal(session_id, attrs) do
    put_fields(session_id, Map.take(attrs, [:last_seq, :head_hash, :object_bytes, :workspace_bytes]))
  end

  # A field the worker did not report is a field that has not changed. Casting a nil
  # would set the column to NULL instead, which for the counters means a constraint
  # violation and for the rest means losing what was there.
  defp put_fields(session_id, attrs) do
    attrs = Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> session |> Session.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Record a sealed segment, refusing one from an epoch the session has moved past.

  This is the fence. Epochs are minted by the plane alone and every segment's object key
  carries the epoch it was written under, so a pod that was presumed lost and comes back
  cannot append to a session that has been activated elsewhere — its report is refused
  and the index never sees its events.
  """
  @spec record_anchor(map(), Troupe.Plane.Fleet.Worker.t() | nil) ::
          {:ok, Anchor.t()} | {:error, :stale_epoch | term()}
  def record_anchor(params, _worker \\ nil) do
    session_id = params["session_id"]
    epoch = params["epoch"]

    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      %Session{epoch: current} when is_integer(epoch) and epoch < current ->
        {:error, :stale_epoch}

      session ->
        insert_anchor(session, params)
    end
  end

  defp insert_anchor(session, params) do
    attrs = %{
      session_id: session.id,
      epoch: params["epoch"] || session.epoch,
      first_seq: params["first_seq"],
      last_seq: params["last_seq"],
      head_hash: params["head_hash"],
      object_key: params["object_key"],
      bytes: params["bytes"] || 0,
      sealed_at: DateTime.utc_now()
    }

    with {:ok, anchor} <-
           %Anchor{}
           |> Anchor.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:session_id, :epoch, :last_seq]) do
      seal(session.id, %{
        last_seq: max(params["last_seq"] || 0, session.last_seq),
        head_hash: params["head_hash"] || session.head_hash,
        object_bytes: params["object_bytes"] || session.object_bytes
      })

      {:ok, anchor}
    end
  end

  @doc "Every sealed segment head the plane holds for a session, oldest first."
  @spec anchors(String.t()) :: [Anchor.t()]
  def anchors(session_id) do
    Repo.all(from a in Anchor, where: a.session_id == ^session_id, order_by: [a.epoch, a.last_seq])
  end

  @doc "One session, or `nil`."
  @spec get(String.t()) :: Session.t() | nil
  def get(session_id), do: Repo.get(Session, session_id)

  # -- visibility -------------------------------------------------------------

  @doc """
  The sessions a user can see: the ones they own, the ones they are on the ACL of, and
  the ones their teams share.

  One query, because it is asked on every listing and a three-pass version would drift
  the first time one of them grew a condition the others did not.
  """
  @spec visible_to(User.t(), keyword()) :: [Session.t()]
  def visible_to(%User{} = user, opts \\ []) do
    team_ids = Repo.all(from t in Team, join: m in "memberships", on: m.group_id == type(t.group_id, :binary_id), where: m.user_id == type(^user.id, :binary_id), select: t.id)

    query =
      from s in Session,
        left_join: a in ACL,
        on: a.session_id == s.id and a.subject == ^user.subject,
        where:
          s.state != "erased" and
            (s.owner_subject == ^user.subject or not is_nil(a.id) or
               (s.visibility == "team" and s.team_id in ^team_ids)),
        distinct: s.id,
        order_by: [desc: s.last_active_at]

    query
    |> filter(opts)
    |> Repo.all()
  end

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:profile, profile}, acc -> from s in acc, where: s.profile == ^profile
      {:state, states}, acc -> from s in acc, where: s.state in ^List.wrap(states)
      {:limit, limit}, acc -> from s in acc, limit: ^limit
      _other, acc -> acc
    end)
  end

  @doc """
  What a user may do with one session, or `nil` when they may not see it.

  Owner administers, collaborator steers, viewer watches. Team visibility gives observe,
  and control too when the team allows it — which is a team setting rather than a
  session one, because it is a statement about how a team works.
  """
  @spec role_for(User.t(), Session.t()) :: :admin | :control | :observe | nil
  def role_for(%User{} = user, %Session{} = session) do
    cond do
      session.owner_subject == user.subject -> :admin
      acl = Repo.get_by(ACL, session_id: session.id, subject: user.subject) -> ACL.scope(acl.role)
      session.visibility == "team" -> team_role(user, session)
      true -> nil
    end
  end

  defp team_role(user, session) do
    with team_id when not is_nil(team_id) <- session.team_id,
         %Team{} = team <- Repo.get(Team, team_id),
         true <- member?(user, team) do
      if team.members_may_control, do: :control, else: :observe
    else
      _ -> nil
    end
  end

  defp member?(user, team) do
    Repo.exists?(
      from m in "memberships",
        where: m.user_id == type(^user.id, :binary_id) and m.group_id == type(^team.group_id, :binary_id)
    )
  end

  # -- the ACL ----------------------------------------------------------------

  @doc "Mirror an `acl_granted` event from the session log."
  @spec grant_access(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, ACL.t()} | {:error, Ecto.Changeset.t()}
  def grant_access(session_id, subject, role, granted_by \\ nil) do
    attrs = %{
      session_id: session_id,
      subject: subject,
      role: role,
      granted_by: granted_by,
      granted_at: DateTime.utc_now()
    }

    (Repo.get_by(ACL, session_id: session_id, subject: subject) || %ACL{})
    |> ACL.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Mirror an `acl_revoked` event. A revoked collaborator's next command is refused."
  @spec revoke_access(String.t(), String.t()) :: :ok
  def revoke_access(session_id, subject) do
    Repo.delete_all(from a in ACL, where: a.session_id == ^session_id and a.subject == ^subject)
    :ok
  end

  @doc "Everyone explicitly on a session."
  @spec access_list(String.t()) :: [ACL.t()]
  def access_list(session_id) do
    Repo.all(from a in ACL, where: a.session_id == ^session_id, order_by: a.subject)
  end
end
