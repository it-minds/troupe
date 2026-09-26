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
  alias Troupe.Plane.Sessions.{ACL, Anchor, Session, Share}
  alias Troupe.Plane.Settings.Ladder

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

  @doc """
  What a profile is being asked to run: sessions active now, and sessions waiting.

  Both, because the scaler has to bring up room for the ones waiting as well as keep it
  for the ones running — a count of the active alone would settle at exactly the capacity
  that is already full.
  """
  @spec demand_for(String.t()) :: %{active: non_neg_integer(), pending: non_neg_integer()}
  def demand_for(profile) do
    counts =
      Repo.all(
        from(s in Session,
          where: s.profile == ^profile and s.state in ["active", "pending"],
          group_by: s.state,
          select: {s.state, count(s.id)}
        )
      )
      |> Map.new()

    %{active: Map.get(counts, "active", 0), pending: Map.get(counts, "pending", 0)}
  end

  @doc """
  Sessions waiting for a worker on this profile, oldest first.

  Oldest first is the whole of the fairness here: a session that has been waiting two
  minutes should be placed before one created a moment ago, and a controller that took
  them in any other order would make the wait unbounded for somebody.
  """
  @spec pending_for(String.t(), non_neg_integer()) :: [Session.t()]
  def pending_for(profile, limit \\ 50) do
    Repo.all(
      from(s in Session,
        where: s.profile == ^profile and s.state == "pending",
        order_by: [asc: s.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc """
  Mark a session as waiting for a worker, keeping the prompt until there is one.

  The prompt is the only piece of session *content* the plane ever holds, and it holds
  it here for the same reason it carries it in `session.activate`: a session with nobody
  attached has to do its first turn alone, and a wait that dropped the prompt would
  produce a session that started and then sat there. It is cleared the moment the
  session is placed.
  """
  @spec wait(String.t(), String.t() | nil) :: {:ok, Session.t()} | {:error, term()}
  def wait(session_id, prompt) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Session.changeset(%{state: "pending", pending_prompt: prompt})
        |> Repo.update()
    end
  end

  @doc "The session is placed: it is no longer waiting and its prompt has been sent."
  @spec admitted(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def admitted(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Session.changeset(%{state: "active", pending_prompt: nil})
        |> Repo.update()
    end
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
  Park a session whose tree a pod could not put back (Decision 661): read-only, off its
  worker. History stays readable and nothing activates it again, which is better than
  every client that opens it meeting the same failure.

  Fenced on the epoch like `put_status/2` when the pod names one, so a pod still running
  an older epoch cannot park a session a newer one is serving. Saying it about a session
  already parked, or erased, or unknown, changes nothing and is not an error.
  """
  @spec unrestorable(String.t(), integer() | nil) :: {:ok, non_neg_integer()} | {:error, :stale_epoch}
  def unrestorable(session_id, epoch) do
    now = DateTime.utc_now()

    query =
      from(s in Session,
        where: s.id == ^session_id and s.state in ["pending", "active", "dormant"]
      )

    query = if is_integer(epoch), do: from(s in query, where: s.epoch <= ^epoch), else: query

    case Repo.update_all(query, set: [state: "read_only", worker_id: nil, updated_at: now]) do
      {0, _} ->
        case Repo.get(Session, session_id) do
          %Session{state: state} when state in ["pending", "active", "dormant"] -> {:error, :stale_epoch}
          _parked_erased_or_unknown -> {:ok, 0}
        end

      {count, _} ->
        {:ok, count}
    end
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
      |> put_status_field(:pending_questions, report["pending_questions"])
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

  defp put_status_field(set, key, value)
       when key in [:pending_approvals, :pending_questions, :cost_micros] do
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

  # Through the team's links, because a team is a union of groups rather than one. The
  # raw table names are deliberate — `Sessions` may not reach into `Identity`'s schemas
  # any more than a LiveView may reach into `Admin`'s — and `distinct` is load-bearing: a
  # person in two of a team's groups would otherwise put the team in this list twice, and
  # every listing would show their sessions twice.
  defp member_team_ids(%User{id: id}) when is_binary(id) do
    Repo.all(
      from(t in Team,
        join: l in "team_group_links",
        on: l.team_id == type(t.id, :binary_id),
        join: m in "memberships",
        on: m.group_id == type(l.group_id, :binary_id),
        where: m.user_id == type(^id, :binary_id),
        distinct: t.id,
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

      # One filter for all seven ways a session is started by something other than a
      # person: `source: "any"` is every one of them, and a named source is one. This is
      # what makes "show me everything automated" a single question rather than a union
      # of origin kinds a reader has to know to enumerate.
      {:source, "any"}, acc ->
        from(s in acc, where: not is_nil(fragment("?->>'source'", s.origin)))

      {:source, source}, acc when is_binary(source) ->
        from(s in acc, where: fragment("?->>'source'", s.origin) == ^source)

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

  @doc """
  The sessions forked from this one, which an erasure does *not* take with it.

  A fork is a separate session with its own key, sealed under it from the moment it was
  opened — so erasing a parent destroys the parent's key and leaves every child readable.
  That is the consequence people get wrong, and the count is what the dialog quotes.

  An erased child is left out: it is already gone, and listing it as a survivor would be
  the count saying something is still readable when it is not.
  """
  @spec children_of(String.t()) :: [Session.t()]
  def children_of(session_id) do
    Session
    |> where([s], s.parent_session_id == ^session_id and s.state != "erased")
    |> order_by([s], asc: s.inserted_at)
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
  How many sessions these people can currently open.

  What an unlink dialog quotes. Counted rather than listed, because the question is *how
  much am I about to take away* and a list of twenty-three session ids is not an answer to
  it. Sessions they own, sessions they are on the ACL of, and their teams' shared ones —
  the same three roads `visible_to/2` takes, because a number that did not match what they
  can actually open would be worse than no number.
  """
  @spec count_visible_to([String.t()]) :: non_neg_integer()
  def count_visible_to([]), do: 0

  def count_visible_to(subjects) do
    Repo.one(
      from(s in Session,
        left_join: a in ACL,
        on: a.session_id == s.id and a.subject in ^subjects,
        left_join: t in Team,
        on: t.id == s.team_id,
        left_join: l in "team_group_links",
        on: l.team_id == type(t.id, :binary_id),
        left_join: m in "memberships",
        on: m.group_id == type(l.group_id, :binary_id),
        left_join: u in User,
        on: u.id == type(m.user_id, :binary_id) and u.subject in ^subjects,
        where:
          s.state != "erased" and
            (s.owner_subject in ^subjects or not is_nil(a.id) or
               (s.visibility == "team" and not is_nil(u.id))),
        distinct: s.id,
        select: s.id
      )
      |> subquery()
      |> select([s], count(s.id))
    )
  end

  @doc """
  How many sessions a team has that are not erased.

  What `Admin.team_disable_preview/2` reports as *kept*: a session's team is recorded at
  create and the column is nulled when the team goes, so these outlive it as sessions
  with no team rather than going with it.
  """
  @spec count_for_team(Team.t()) :: non_neg_integer()
  def count_for_team(%Team{id: team_id}) do
    Repo.aggregate(
      from(s in Session, where: s.team_id == ^team_id and s.state != "erased"),
      :count
    )
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
      # Through the ladder, not off the column: a platform that has turned this off
      # turns it off for every team, and a team that has it on in its own row stops
      # being able to steer at the next request rather than at the next edit.
      if Ladder.resolve(team).members_may_control, do: :control, else: :observe
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
        join: l in "team_group_links",
        on: l.group_id == m.group_id,
        where: m.user_id == type(^id, :binary_id) and l.team_id == type(^team.id, :binary_id)
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

  # -- shares -----------------------------------------------------------------

  @doc """
  Mint a capability over a session, and hand back the secret once.

  Once, because the plane keeps a salted digest and not the secret — the same shape a
  trigger key has, and for the same reason: a dump of this table is not a set of working
  links. Somebody who loses a share mints another and revokes the first, which is the
  behaviour to want anyway.

  The caller has already decided this is allowed. Everything here is the record of that
  decision and none of it is the decision itself.
  """
  @spec mint_share(String.t(), map()) :: {:ok, Share.t(), String.t()} | {:error, term()}
  def mint_share(session_id, attrs) do
    {id, secret, hash, salt} = mint_secret()

    %Share{}
    |> Share.changeset(
      Map.merge(attrs, %{
        id: id,
        session_id: session_id,
        secret_hash: hash,
        secret_salt: salt
      })
    )
    |> Repo.insert()
    |> case do
      {:ok, share} -> {:ok, share, secret}
      error -> error
    end
  end

  @doc """
  End one capability, leaving every other route to the session alone.

  The difference from `revoke_access/2` is the point of having both. Removing somebody
  from the ACL ends every way they had in; revoking a share ends this link and not their
  membership, not their team's visibility, and not another link they were sent.

  Idempotent: revoking a revoked share keeps the first revocation, because *when* it
  stopped working is a fact and the second attempt is somebody making sure.
  """
  @spec revoke_share(Share.t(), String.t(), String.t() | nil) :: {:ok, Share.t()}
  def revoke_share(%Share{revoked_at: at} = share, _by, _reason) when not is_nil(at),
    do: {:ok, share}

  def revoke_share(%Share{} = share, by, reason) do
    share
    |> Share.revoke_changeset(%{
      revoked_at: DateTime.utc_now(),
      revoked_by: by,
      revoked_reason: reason
    })
    |> Repo.update()
  end

  @doc "One share, by its public id."
  @spec get_share(String.t()) :: Share.t() | nil
  def get_share(id) when is_binary(id), do: Repo.get(Share, id)
  def get_share(_other), do: nil

  @doc "Every capability over a session, newest first, revoked and expired ones included."
  @spec shares_of(String.t()) :: [Share.t()]
  def shares_of(session_id) do
    Repo.all(
      from(s in Share, where: s.session_id == ^session_id, order_by: [desc: s.inserted_at])
    )
  end

  @doc """
  The share a secret opens, if it still opens one.

  What is asked of the share is only what is true of the share: unexpired, unrevoked, and
  — where it named somebody — presented by them. Nothing here re-derives the sharer's
  authority. That was settled at mint, and a link that quietly stopped working because
  somebody changed teams is not what anybody means by sending somebody a link.
  """
  @spec redeem_share(String.t(), String.t() | nil) ::
          {:ok, Share.t()} | {:error, :no_such_share | :expired | :revoked | :not_for_you}
  def redeem_share(secret, subject \\ nil)

  def redeem_share(secret, subject) when is_binary(secret) do
    now = DateTime.utc_now()

    with {:ok, share} <- share_for_secret(secret),
         :ok <- share_usable(share, now),
         :ok <- share_audience(share, subject) do
      {:ok, mark_redeemed(share, now)}
    end
  end

  def redeem_share(_secret, _subject), do: {:error, :no_such_share}

  # The secret names its own share, so this is one indexed lookup rather than a scan of
  # every share in the deployment. The id is public — it is in `share_created` — and the
  # half after the dot is the part that has to be right; it is compared against a salted
  # digest, in constant time, and the id on its own opens nothing.
  defp share_for_secret(secret) do
    with ["tsh_" <> id, _presented] <- String.split(secret, ".", parts: 2),
         %Share{} = share <- Repo.get(Share, "shr_" <> id),
         true <- secret_matches?(share, secret) do
      {:ok, share}
    else
      _no -> {:error, :no_such_share}
    end
  end

  defp share_usable(%Share{revoked_at: at}, _now) when not is_nil(at), do: {:error, :revoked}

  defp share_usable(%Share{} = share, now) do
    if Share.live?(share, now), do: :ok, else: {:error, :expired}
  end

  # A share made out to somebody is theirs. One with no audience is a link, and was minted
  # by somebody who chose that.
  defp share_audience(%Share{audience: nil}, _subject), do: :ok
  defp share_audience(%Share{audience: subject}, subject), do: :ok
  defp share_audience(%Share{}, _other), do: {:error, :not_for_you}

  # What it has actually been used for, which is the question somebody asks before revoking
  # one: has anybody opened this, and when did they last.
  defp mark_redeemed(%Share{} = share, now) do
    {1, _updated} =
      Repo.update_all(
        from(s in Share, where: s.id == ^share.id),
        inc: [redeemed_count: 1],
        set: [last_redeemed_at: now, updated_at: now]
      )

    %{share | redeemed_count: share.redeemed_count + 1, last_redeemed_at: now}
  end

  # 256 bits after the id, URL-safe so it survives a chat window, a mail client and a
  # shell. Prefixed so a secret found in a log says what it is and what to revoke.
  defp mint_secret do
    id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    # A dot between the two halves, because base64url uses `-` and `_` and a separator that
    # can appear inside an id is a separator that splits the wrong id in half.
    secret =
      "tsh_" <>
        id <> "." <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    {"shr_" <> id, secret, secret_hash(salt, secret), salt}
  end

  defp secret_hash(salt, secret),
    do: :sha256 |> :crypto.hash(salt <> secret) |> Base.encode16(case: :lower)

  defp secret_matches?(%Share{secret_hash: hash, secret_salt: salt}, secret) do
    presented = secret_hash(salt, secret)
    byte_size(presented) == byte_size(hash) and :crypto.hash_equals(presented, hash)
  end

  @doc "Everyone explicitly on a session."
  @spec access_list(String.t()) :: [ACL.t()]
  def access_list(session_id) do
    Repo.all(from(a in ACL, where: a.session_id == ^session_id, order_by: a.subject))
  end
end
