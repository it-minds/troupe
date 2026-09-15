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
    case Repo.one(from(s in Session, where: s.id == ^session_id, select: s.worker_id)) do
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

  @doc """
  The sessions a pod is holding, by id.

  What a drain waits on: the pod says it is empty and the plane checks its own record
  before agreeing, because a pod reporting success while the index still shows sessions
  on it is exactly the case where believing the pod would lose them.
  """
  @spec on_worker(Ecto.UUID.t()) :: [String.t()]
  def on_worker(worker_id) do
    Repo.all(
      from(s in Session,
        where: s.worker_id == type(^worker_id, :binary_id) and s.state == "active",
        select: s.id,
        order_by: s.id
      )
    )
  end

  @doc "How many active sessions each pod of a profile is holding, from the database."
  @spec active_counts_by_worker(String.t()) :: %{Ecto.UUID.t() => non_neg_integer()}
  def active_counts_by_worker(profile) do
    Repo.all(
      from(s in Session,
        where: s.profile == ^profile and s.state == "active" and not is_nil(s.worker_id),
        group_by: s.worker_id,
        select: {s.worker_id, count(s.id)}
      )
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
      {1, [session]} ->
        {:ok, session}

      {0, _} ->
        if Repo.get(Session, session_id), do: {:error, :not_dormant}, else: {:error, :not_found}
    end
  end

  @doc """
  Record that a session has gone dormant, with the sequence it sealed at.

  The worker is cleared here rather than being left to whoever calls `Placement.release`
  next. `put_fields/2` drops nils on purpose — a pod reporting three of four lifecycle
  fields must not blank the fourth — so `worker_id: nil` through that path was silently
  discarded, and a dormant session went on naming the pod it was no longer on until a
  release happened to land. Every reader of `worker_id` filters on `state == "active"`,
  which is why it took a test asserting the row directly to see it.
  """
  @spec dormant(String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def dormant(session_id, attrs \\ %{}) do
    put_fields(session_id, Map.merge(attrs, %{state: "dormant"}), clear: [:worker_id])
  end

  @doc "Make a session read-only, because its profile is gone or its team lost the grant."
  @spec read_only(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def read_only(session_id) do
    put_fields(session_id, %{state: "read_only"}, clear: [:worker_id])
  end

  @doc """
  Overwrite a row from a rebuild.

  Unlike `put_fields/2`, a nil here *is* the answer: a rebuild reconstructs the whole
  row from storage, and a field storage does not have is a field the index should not
  claim to know.
  """
  @spec put_rebuilt(String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def put_rebuilt(session_id, attrs) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> session |> Session.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Make every session a team has on a profile read-only, because the grant is gone.

  Reads still work — history is history, and a team losing a grant is not a reason to
  hide what it already did — but nothing activates again. Active sessions are included:
  the grant is what made them allowed, and it is no longer there.
  """
  @spec read_only_for(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def read_only_for(team_id, profile) do
    {count, _} =
      Repo.update_all(
        from(s in Session,
          where:
            s.team_id == ^team_id and s.profile == ^profile and s.state in ["active", "dormant"]
        ),
        set: [state: "read_only", worker_id: nil, updated_at: DateTime.utc_now()]
      )

    count
  end

  @doc "Record which bundle version a session is pinned to."
  @spec pin_bundle(String.t(), integer()) :: {:ok, Session.t()} | {:error, term()}
  def pin_bundle(session_id, version), do: put_fields(session_id, %{bundle_version: version})

  @doc "Set a session's lifecycle state directly. Erasure is the only caller."
  @spec put_state(String.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def put_state(session_id, state), do: put_fields(session_id, %{state: state})

  @doc """
  Pin a session, exempting it from retention, or unpin it.

  Recorded with who did it and when, because a pin is a decision somebody made about
  somebody else's storage bill and a team admin is entitled to see whose.
  """
  @spec pin(String.t(), boolean(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def pin(session_id, pinned?, actor) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        attrs =
          if pinned? do
            %{pinned: true, pinned_by: actor, pinned_at: DateTime.utc_now()}
          else
            %{pinned: false}
          end

        session |> Session.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Remove a session row outright.

  Only for unwinding a `session.create` that did not complete: a row whose placement or
  budget was refused was never a session, and leaving it behind would put a phantom in
  everybody's listing. A session that ever ran is erased, not deleted, because a
  tombstone is the record that it existed.
  """
  @spec delete(String.t()) :: :ok
  def delete(session_id) do
    Repo.delete_all(from(s in Session, where: s.id == ^session_id))
    :ok
  end

  @doc "Record a sealed segment: the index's view of how far a session has got."
  @spec seal(String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def seal(session_id, attrs) do
    put_fields(
      session_id,
      Map.take(attrs, [:last_seq, :head_hash, :object_bytes, :workspace_bytes])
    )
  end

  # -- private sessions -------------------------------------------------------

  @doc """
  Register a session that runs on somebody's own machine.

  The plane learns that it exists and how far it has got. It learns nothing else: the
  bytes are sealed with a key under `troupe/people/<subject>/sessions/<id>` that no pod
  and no operator role can read, and the row carries sizes, sequence numbers and hashes.

  Idempotent on the id, because a daemon that seals, loses its connection and retries
  must not end up with two sessions or a rejected one. A first registration mints epoch
  1; a later one is a progress report, fenced.
  """
  @spec register(String.t(), map()) ::
          {:ok, Session.t()} | {:error, :stale_epoch | :not_yours | Ecto.Changeset.t()}
  def register(subject, %{"session_id" => session_id} = params) when is_binary(subject) do
    case Repo.get(Session, session_id) do
      nil -> insert_private(subject, session_id, params)
      %Session{} = session -> reseal_private(subject, session, params)
    end
  end

  defp insert_private(subject, session_id, params) do
    create(%{
      id: session_id,
      owner_subject: subject,
      kind: "private",
      visibility: "private",
      state: "active",
      device: params["device"],
      title: params["title"],
      origin: %{"kind" => "user", "device" => params["device"]},
      last_seq: params["last_seq"] || 0,
      head_hash: params["head_hash"],
      object_bytes: params["object_bytes"] || 0,
      workspace_bytes: params["workspace_bytes"] || 0
    })
  end

  # A seal carries the epoch the device believes it holds. The device that lost a claim
  # still has a log and still wants to write it; this is where it is told not to, and it
  # is told on the *next seal* rather than at the moment it lost, because nothing reaches
  # a laptop that is not asking.
  defp reseal_private(subject, %Session{kind: "private", owner_subject: subject} = session, p) do
    {count, rows} =
      Repo.update_all(
        from(s in Session,
          where: s.id == ^session.id and s.epoch == ^(p["epoch"] || session.epoch),
          select: s
        ),
        set: seal_fields(session, p)
      )

    case {count, rows} do
      {1, [updated]} -> {:ok, updated}
      {0, _none} -> {:error, :stale_epoch}
    end
  end

  defp reseal_private(_subject, %Session{}, _params), do: {:error, :not_yours}

  # `last_seq` never goes backwards. A retry of an older seal is not a rewind, and a
  # daemon replaying its queue after a restart sends them in whatever order it kept them.
  defp seal_fields(session, params) do
    [
      last_seq: max(params["last_seq"] || 0, session.last_seq),
      last_active_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    ]
    |> put_present(:head_hash, params["head_hash"])
    |> put_present(:device, params["device"])
    |> put_present(:title, params["title"])
    |> put_present(:object_bytes, params["object_bytes"])
    |> put_present(:workspace_bytes, params["workspace_bytes"])
  end

  defp put_present(fields, _key, nil), do: fields
  defp put_present(fields, key, value), do: Keyword.put(fields, key, value)

  @doc """
  Take a private session over on this device.

  The fence between two machines. Both read epoch 3 and both try to move past it; the
  conditional update decides, and the loser learns it lost on its next seal rather than
  by being told — a laptop that is asleep is not listening, and one that is awake is
  about to ask anyway.

  Unlike `activate/1` there is no dormancy condition: a private session has no pod whose
  absence would make it dormant, so "still on the other device" is exactly the case this
  has to resolve rather than refuse.
  """
  @spec claim(String.t(), String.t(), integer(), String.t() | nil) ::
          {:ok, Session.t()} | {:error, :stale_epoch | :not_found | :not_yours}
  def claim(session_id, subject, from_epoch, device \\ nil) do
    {count, rows} =
      Repo.update_all(
        from(s in Session,
          where:
            s.id == ^session_id and s.epoch == ^from_epoch and s.kind == "private" and
              s.owner_subject == ^subject and s.state != "erased",
          select: s
        ),
        inc: [epoch: 1],
        set:
          [state: "active", last_active_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
          |> put_present(:device, device)
      )

    case {count, rows} do
      {1, [session]} -> {:ok, session}
      {0, _none} -> claim_refusal(session_id, subject)
    end
  end

  defp claim_refusal(session_id, subject) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      %Session{kind: "private", owner_subject: ^subject} -> {:error, :stale_epoch}
      %Session{} -> {:error, :not_yours}
    end
  end

  @doc """
  Record what the worker says a session is doing.

  One conditional statement, fenced on the epoch: a report from a pod that was presumed
  lost and is still running an older epoch is dropped, because the session has moved on
  and its status is whatever the new pod says. `done_reason` is the one field where a
  reported nil is the answer — a session that starts a new turn has no done reason any
  more — so it is set whenever the report carries the key, unlike the counters.
  """
  @spec put_status(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, :stale_epoch}
  def put_status(session_id, report) do
    now = DateTime.utc_now()

    fields =
      [updated_at: now]
      |> put_status_field(:status, report["status"])
      |> put_status_field(:pending_approvals, report["pending_approvals"])
      |> put_status_field(:cost_micros, report["cost_micros"])
      |> then(fn set ->
        if Map.has_key?(report, "done_reason"),
          do: Keyword.put(set, :done_reason, report["done_reason"]),
          else: set
      end)

    query = from(s in Session, where: s.id == ^session_id)

    query =
      case report["epoch"] do
        epoch when is_integer(epoch) -> from(s in query, where: s.epoch <= ^epoch)
        _ -> query
      end

    case Repo.update_all(query, set: fields) do
      {0, _} -> if Repo.get(Session, session_id), do: {:error, :stale_epoch}, else: {:ok, 0}
      {count, _} -> {:ok, count}
    end
  end

  defp put_status_field(set, :status, status) when is_binary(status) do
    if status in Session.statuses(), do: Keyword.put(set, :status, status), else: set
  end

  defp put_status_field(set, key, value) when key in [:pending_approvals, :cost_micros] do
    if is_integer(value) and value >= 0, do: Keyword.put(set, key, value), else: set
  end

  defp put_status_field(set, _key, _value), do: set

  @doc """
  Move the ledger's cursor through a session's log, and say where it now is.

  Monotonic by construction: the column takes the greater of what it holds and what is
  offered, so a batch that arrives out of order — a retry of an older one, most often —
  cannot walk the cursor backwards and make a pod resend what is already charged. The
  answer is what the column holds afterwards, which is what the pod deletes up to, so a
  loser of that race is told the truth rather than its own number.

  Not fenced on the epoch, unlike `put_status/2`. A charge is a charge: a pod that has
  since been fenced still made the model calls it is reporting, and refusing them would
  lose money rather than protect anything.
  """
  @spec advance_usage_seq(String.t(), non_neg_integer()) :: non_neg_integer()
  def advance_usage_seq(session_id, seq) when is_integer(seq) and seq >= 0 do
    query =
      from(s in Session,
        where: s.id == ^session_id,
        update: [set: [usage_seq: fragment("greatest(?, ?)", s.usage_seq, ^seq)]],
        select: s.usage_seq
      )

    case Repo.update_all(query, []) do
      {1, [current]} -> current
      _none -> seq
    end
  end

  @doc """
  Mark a session reviewed: a person has read what an unattended run produced.

  Recorded with who and when, because it is the answer to "did anybody look at this",
  and the run it came from is marked by the same call in `Triggers`.
  """
  @spec review(String.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def review(session_id, actor) do
    put_fields(session_id, %{reviewed_by: actor, reviewed_at: DateTime.utc_now()})
  end

  # A field the worker did not report is a field that has not changed. Casting a nil
  # would set the column to NULL instead, which for the counters means a constraint
  # violation and for the rest means losing what was there.
  # Nils are dropped because a pod reporting three of four lifecycle fields must not
  # blank the fourth. `clear:` is how a caller says it means the nil: the fields named
  # there are set to nil after the rejection, which is the difference between "I have
  # nothing to say about the worker" and "there is no worker".
  defp put_fields(session_id, attrs, opts \\ []) do
    cleared = Map.new(Keyword.get(opts, :clear, []), &{&1, nil})

    attrs =
      attrs
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.merge(cleared)

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
           |> Repo.insert(
             on_conflict: :nothing,
             conflict_target: [:session_id, :epoch, :last_seq]
           ) do
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
    Repo.all(
      from(a in Anchor, where: a.session_id == ^session_id, order_by: [a.epoch, a.last_seq])
    )
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
    team_ids = member_team_ids(user)

    query =
      from(s in Session,
        left_join: a in ACL,
        on: a.session_id == s.id and a.subject == ^user.subject,
        where:
          s.state != "erased" and
            (s.owner_subject == ^user.subject or not is_nil(a.id) or
               (s.visibility == "team" and s.team_id in ^team_ids)),
        distinct: s.id,
        order_by: [desc: s.last_active_at]
      )

    query
    |> filter(opts)
    |> Repo.all()
  end

  # The teams whose shared sessions a user may see. A person's come from the identity
  # provider's groups; a service principal's is the one team that owns it, and it has no
  # `users` row to join through.
  defp member_team_ids(%User{kind: "service", principal: %{team_id: team_id}}), do: [team_id]

  defp member_team_ids(%User{id: id}) when is_binary(id) do
    Repo.all(
      from(t in Team,
        join: m in "memberships",
        on: m.group_id == type(t.group_id, :binary_id),
        where: m.user_id == type(^id, :binary_id),
        select: t.id
      )
    )
  end

  defp member_team_ids(_user), do: []

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:profile, profile}, acc ->
        from(s in acc, where: s.profile == ^profile)

      {:kind, kind}, acc ->
        from(s in acc, where: s.kind == ^kind)

      {:state, states}, acc ->
        from(s in acc, where: s.state in ^List.wrap(states))

      {:status, statuses}, acc ->
        from(s in acc, where: s.status in ^List.wrap(statuses))

      # A row written before origins existed has none, and was a person's.
      {:origin, kind}, acc ->
        from(s in acc, where: coalesce(fragment("?->>'kind'", s.origin), "user") == ^kind)

      {:trigger, name}, acc ->
        from(s in acc, where: fragment("?->>'trigger'", s.origin) == ^name)

      {:needs_review, true}, acc ->
        needs_review(acc)

      {:needs_review, "true"}, acc ->
        needs_review(acc)

      {:limit, limit}, acc when is_integer(limit) ->
        from(s in acc, limit: ^limit)

      _other, acc ->
        acc
    end)
  end

  # What a person has not closed the loop on: a session nobody started by hand, that
  # nobody has marked reviewed. A user's own sessions are never in the queue, because
  # the person who asked for it is the review.
  defp needs_review(query) do
    from(s in query,
      where: fragment("?->>'kind'", s.origin) in ["trigger", "a2a"] and is_nil(s.reviewed_at)
    )
  end

  @doc """
  Sessions an administrator may see: metadata, never content.

  A platform admin sees every session; a team admin sees their teams'. Ordered by last
  activity, because the question an admin asks a session list is almost always "what is
  happening now" rather than "what exists".
  """
  @spec for_admin(map(), [Ecto.UUID.t()], keyword()) :: [Session.t()]
  def for_admin(actor, team_ids, opts \\ []) do
    Session
    |> admin_scope(actor, team_ids)
    |> filter(opts)
    |> order_by([s], desc: s.last_active_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  @doc "How many sessions in a state an administrator can see."
  @spec count_for_admin([Ecto.UUID.t()], boolean(), String.t()) :: non_neg_integer()
  def count_for_admin(team_ids, platform_admin?, state) do
    Session
    |> admin_scope(%{role: if(platform_admin?, do: :platform_admin, else: :team_admin)}, team_ids)
    |> where([s], s.state == ^state)
    |> select([s], count(s.id))
    |> Repo.one()
  end

  defp admin_scope(query, %{role: :platform_admin}, _team_ids) do
    from(s in query, where: s.state != "erased")
  end

  defp admin_scope(query, _actor, team_ids) do
    from(s in query, where: s.state != "erased" and s.team_id in ^team_ids)
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

  # A principal is a member of the team that owns it and of no other; a person is a
  # member of whatever the identity provider says.
  defp member?(%User{kind: "service", principal: %{team_id: team_id}}, team),
    do: team_id == team.id

  defp member?(%User{id: id}, team) when is_binary(id) do
    Repo.exists?(
      from(m in "memberships",
        where:
          m.user_id == type(^id, :binary_id) and m.group_id == type(^team.group_id, :binary_id)
      )
    )
  end

  defp member?(_user, _team), do: false

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
    Repo.delete_all(from(a in ACL, where: a.session_id == ^session_id and a.subject == ^subject))
    :ok
  end

  @doc "Everyone explicitly on a session."
  @spec access_list(String.t()) :: [ACL.t()]
  def access_list(session_id) do
    Repo.all(from(a in ACL, where: a.session_id == ^session_id, order_by: a.subject))
  end
end
