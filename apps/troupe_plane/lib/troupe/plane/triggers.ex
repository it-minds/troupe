defmodule Troupe.Plane.Triggers do
  @moduledoc """
  Sessions nobody starts by hand.

  A trigger is a caller, not a feature: firing one creates a session through
  `Harness.call("session.create", …)` *as the trigger's principal*, so every check a
  principal's own create would meet — the grant, the budget, the agent, the terms — is
  met, and the log's actor on the first input names the principal. This module adds
  the parts that are about the trigger rather than the session: rendering the prompt
  from the event, the idempotency key, the concurrency cap, letting the `notify`
  subjects in, and the run row a person reads afterwards.

  The plane stores the definition and the record. What decides *when* to fire is
  outside — Hatchet where it is deployed, `Triggers.Scheduler` for cron where it is
  not — and both reach the same `fire/4`.

  Every firing names a `Revision`: the trigger's document, frozen and content-addressed
  at the moment it fired. The row an admin edits is what the *next* firing will resolve;
  what a run says it ran is immutable. Resolution happens once, at the top of `fire/4`,
  which is what makes a firing that overlaps an edit use one document or the other and
  never a mixture — and is why it is not the scheduler's business: a webhook, an API
  call and a person's hand reach the same line.
  """

  import Ecto.Query

  alias Troupe.Plane.Audit
  alias Troupe.Plane.GitHub.Issue
  alias Troupe.Plane.GitHub.Policy, as: GitHubPolicy
  alias Troupe.Plane.{Harness, Identity, Principals, Repo, Sessions}
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Plane.Triggers.{Notify, Revision, Run, Template, Trigger}
  alias Troupe.Protocol.{Canonical, Error, Origin, Principal}

  require Logger

  # An event is what a provider filter let through — an issue key, a title, a URL — and
  # this is the most of one a run will keep. A whole webhook body is not a record; it is
  # a place to hide instructions.
  @max_event_bytes 16_384

  @term_keys ~w(budget_micros max_turns wall_clock_seconds approvals)

  # What `put/3` reads of what it is given: the document's fields, and the principal by
  # subject. `admin.trigger.put`'s schema declares these and the team, and a test holds
  # the two together, because a schema that named other things (it once said `kind`,
  # `schedule` and `prompt`) is a tool a model follows into a trigger that does nothing.
  @put_keys ~w(name principal profile agent enabled source prompt_template terms) ++
              ~w(visibility review notify notify_url concurrency)

  @doc "How large a run's event may be, encoded."
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes, do: @max_event_bytes

  @doc "The keys a trigger's `terms` may have, which `session.create` will check again."
  @spec term_keys() :: [String.t()]
  def term_keys, do: @term_keys

  @doc "The attributes `put/3` reads."
  @spec put_keys() :: [String.t()]
  def put_keys, do: @put_keys

  # -- definitions ------------------------------------------------------------

  @doc "A team's triggers, by name."
  @spec list(Team.t()) :: [Trigger.t()]
  def list(%Team{} = team) do
    Repo.all(from(t in Trigger, where: t.team_id == ^team.id, order_by: t.name))
  end

  @doc """
  Every team's triggers, each with its team, by team and name: what the GitOps pass
  compares the cluster against, and what bootstrapping a repository exports.
  """
  @spec list_all() :: [Trigger.t()]
  def list_all do
    Repo.all(
      from(t in Trigger,
        join: team in assoc(t, :team),
        order_by: [team.name, t.name],
        preload: [team: team]
      )
    )
  end

  @doc "One trigger of a team, by name."
  @spec get(Team.t(), String.t()) :: Trigger.t() | nil
  def get(%Team{} = team, name), do: Repo.get_by(Trigger, team_id: team.id, name: name)

  @doc "One trigger by id, or `nil`."
  @spec fetch(String.t()) :: Trigger.t() | nil
  def fetch(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Trigger, uuid)
      :error -> nil
    end
  end

  @doc """
  Create or update a trigger by team and name.

  Partial: an existing trigger keeps every field the attributes leave out, which is how
  the panel's enable and disable buttons are the same call as the CLI's `put` of a whole
  file. The principal is named by subject and must belong to the team; the terms are
  checked with the same rules `session.create` will apply, so a bad one is refused when
  it is written rather than at three in the morning.
  """
  @spec put(Team.t(), map(), String.t()) :: {:ok, Trigger.t()} | {:error, Error.t()}
  def put(%Team{} = team, attrs, by) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    existing = attrs["name"] && get(team, attrs["name"])

    with {:ok, principal_id} <- principal_id(team, attrs, existing),
         :ok <- check_terms(attrs["terms"]) do
      fields = @put_keys -- ["principal"]

      (existing || %Trigger{team_id: team.id, created_by: by})
      |> Trigger.changeset(attrs |> Map.take(fields) |> Map.put("principal_id", principal_id))
      |> Repo.insert_or_update()
      |> case do
        {:ok, trigger} ->
          trigger = drop_dead_key(trigger)
          # A revision is made here rather than at the next firing, so that the diff an
          # admin is shown and the audit row that records it can both name the hash
          # somebody will later see on a run. `revise/2` makes nothing when the document
          # did not move, which is what makes a partial put of `enabled` free.
          {:ok, _revision} = revise(trigger, by)
          {:ok, trigger}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc """
  Make a team's trigger say what its `Trigger` resource says, in GitOps mode (Decision
  737), and revise it as `put/3` does, so its runs, its history and the audit trail work
  as they did when an administrator wrote it.

  Whole rather than partial: a resource is the whole document, so `attrs` carry every
  field, with the principal already resolved to its id. The row is updated in place, which
  is what keeps its id, and so its URL and its key, through every change the repository
  makes; the key, the last firing and who first made the row are the plane's and are left
  alone. Checked by the caller first: this only writes.
  """
  @spec follow(Team.t(), map(), String.t()) ::
          {:ok, Trigger.t(), Revision.t()} | {:error, Ecto.Changeset.t()}
  def follow(%Team{} = team, attrs, by) do
    {generation, attrs} = Map.pop(attrs, :resource_generation)

    (get(team, attrs.name) || %Trigger{team_id: team.id, created_by: by})
    |> Trigger.changeset(attrs)
    |> Trigger.generation_changeset(generation)
    |> Repo.insert_or_update()
    |> case do
      {:ok, trigger} ->
        trigger = drop_dead_key(trigger)
        {:ok, revision} = revise(trigger, by)
        {:ok, trigger, revision}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # -- revisions --------------------------------------------------------------

  @doc """
  The revision of a trigger's document as it stands, made if it does not exist yet.

  Idempotent by content: a document that hashes to a revision this trigger already has
  returns that revision, so editing a template and editing it back lands on revision 1
  rather than making a third. Two callers racing produce one row, because the
  `(trigger_id, hash)` index decides it and the loser reads the winner's.
  """
  @spec revise(Trigger.t(), String.t() | nil) :: {:ok, Revision.t()}
  def revise(%Trigger{} = trigger, by \\ nil) do
    hash = Revision.hash(trigger)

    case Repo.get_by(Revision, trigger_id: trigger.id, hash: hash) do
      %Revision{} = revision ->
        {:ok, revision}

      nil ->
        insert_revision(trigger, hash, by)
    end
  end

  # Retried rather than locked: the two ways this collides are two callers with the same
  # document (the hash index, and the winner's row is the answer) and two callers with
  # different documents landing on the same number (the revision index, and the next
  # number is the answer). Both are settled by reading what is there, and neither is
  # worth an advisory lock on a table an admin writes to by hand a few times a week.
  defp insert_revision(trigger, hash, by, attempts \\ 5) do
    attrs =
      trigger
      |> Revision.document()
      |> Map.merge(%{
        "trigger_id" => trigger.id,
        "revision" => next_revision(trigger),
        "hash" => hash,
        "created_by" => by
      })

    case %Revision{} |> Revision.changeset(attrs) |> Repo.insert() do
      {:ok, revision} ->
        {:ok, revision}

      {:error, _changeset} when attempts > 1 ->
        case Repo.get_by(Revision, trigger_id: trigger.id, hash: hash) do
          %Revision{} = revision -> {:ok, revision}
          nil -> insert_revision(trigger, hash, by, attempts - 1)
        end

      {:error, changeset} ->
        raise "troupe plane: could not revise trigger #{trigger.name}: " <>
                inspect(changeset.errors)
    end
  end

  defp next_revision(trigger) do
    highest =
      Repo.one(
        from(r in Revision, where: r.trigger_id == ^trigger.id, select: max(r.revision))
      )

    (highest || 0) + 1
  end

  @doc "A trigger's revisions, newest first."
  @spec revisions(Trigger.t()) :: [Revision.t()]
  def revisions(%Trigger{} = trigger) do
    Repo.all(
      from(r in Revision, where: r.trigger_id == ^trigger.id, order_by: [desc: r.revision])
    )
  end

  @doc "One revision by id, or `nil`."
  @spec revision(String.t() | nil) :: Revision.t() | nil
  def revision(nil), do: nil

  def revision(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Revision, uuid)
      :error -> nil
    end
  end

  @doc "Remove a trigger. Its runs go with it; the sessions they made do not."
  @spec delete(Trigger.t()) :: :ok
  def delete(%Trigger{} = trigger) do
    Repo.delete_all(from(t in Trigger, where: t.id == ^trigger.id))
    :ok
  end

  @doc "Every enabled trigger with a schedule, for the scheduler's tick."
  @spec scheduled() :: [Trigger.t()]
  def scheduled do
    Repo.all(
      from(t in Trigger,
        where: t.enabled and fragment("?->>'kind'", t.source) == "schedule",
        order_by: t.name
      )
    )
  end

  @doc """
  Every enabled trigger on a GitHub repository that sweeps the repository's open issues on
  a schedule (`source.sweep`), for the scheduler's tick.
  """
  @spec sweeping() :: [Trigger.t()]
  def sweeping do
    Repo.all(
      from(t in Trigger,
        where:
          t.enabled and fragment("?->>'kind'", t.source) == "webhook" and
            fragment("(?->>'repository') IS NOT NULL", t.source) and
            fragment("(?->>'sweep') IS NOT NULL", t.source),
        order_by: t.name
      )
    )
  end

  @doc """
  Every run on one issue of a GitHub repository, by any trigger, newest first, each with
  its session: what says whether the issue is being fixed, and how often it was tried.
  """
  @spec issue_runs(String.t(), integer()) :: [{Run.t(), Session.t() | nil}]
  def issue_runs(full_name, number) when is_binary(full_name) and is_integer(number) do
    Repo.all(
      from(r in Run,
        left_join: s in Session,
        on: s.id == r.session_id,
        where:
          fragment("lower(?->>'repository')", r.event) == ^String.downcase(full_name) and
            fragment("?->'issue'->>'number'", r.event) == ^Integer.to_string(number),
        order_by: [desc: r.fired_at],
        select: {r, s}
      )
    )
  end

  @doc """
  Whether a run holds a place against a cap: a session still to start, one thinking or
  acting, or one dormant with an approval pending. What the queries behind `fire/5` count.
  """
  @spec live?(Run.t(), Session.t() | nil) :: boolean()
  def live?(%Run{state: "created", session_id: nil}, _session), do: true
  def live?(%Run{state: "created"}, %Session{status: "waiting"}), do: true

  def live?(%Run{state: "created"}, %Session{state: "active", failed_reason: nil} = session),
    do: session.status not in ["done", "interrupted"]

  def live?(%Run{}, _session), do: false

  @doc """
  Record that the scheduler fired a trigger for a minute, if nobody has since.

  Conditional, so two schedulers — a replica that thinks it is the singleton and one that
  actually is — advance the mark once between them; the idempotency key is the second
  line, and the reason a double tick is a wasted query rather than a second session.
  """
  @spec mark_fired(Trigger.t(), DateTime.t()) :: boolean()
  def mark_fired(%Trigger{} = trigger, at) do
    {count, _} =
      Repo.update_all(
        from(t in Trigger,
          where: t.id == ^trigger.id and (is_nil(t.last_fired_at) or t.last_fired_at < ^at)
        ),
        set: [last_fired_at: at]
      )

    count == 1
  end

  # -- the trigger's own key --------------------------------------------------

  @doc """
  Mint a key for a trigger, replacing whatever it had.

  Returned once, in the clear, and never again: the row holds a salted hash and a salt,
  and neither reconstructs it. Rotation is the same call as creation — there is no
  "create key" beside a "rotate key", because the two differ only in whether a previous
  key existed, and a caller should not have to know that to do the right thing.

  The old key stops working the moment this returns. That is deliberate and is the point
  of a rotation: an overlap window would mean a key somebody rotated *because it leaked*
  goes on working for as long as the window lasts.
  """
  @spec rotate_key(Trigger.t(), String.t()) :: {:ok, Trigger.t(), String.t()}
  def rotate_key(%Trigger{} = trigger, by) do
    {key, hash, salt} = mint_key()

    {:ok, trigger} =
      trigger
      |> Trigger.key_changeset(%{
        key_hash: hash,
        key_salt: salt,
        key_rotated_at: DateTime.utc_now(),
        key_rotated_by: by
      })
      |> Repo.update()

    {:ok, trigger, key}
  end

  # A trigger that stops taking a key loses the one it had: it opened nothing any more, and
  # kept, a listing said the trigger had a key. One changed back to a webhook is given a new
  # key by a rotation, as any webhook made another way is.
  defp drop_dead_key(%Trigger{key_hash: hash} = trigger) when is_binary(hash) do
    if keyed?(trigger) do
      trigger
    else
      trigger
      |> Trigger.key_changeset(%{
        key_hash: nil,
        key_salt: nil,
        key_rotated_at: nil,
        key_rotated_by: nil
      })
      |> Repo.update!()
    end
  end

  defp drop_dead_key(trigger), do: trigger

  @doc """
  The trigger this id and key name, or `nil`.

  One trigger, by id, and the key is checked against that row alone — there is no
  lookup by key, because a key that could find its own trigger would be a key an
  attacker could enumerate the table with. A trigger with no key is not reachable
  through this door at all: a `nil` hash matches nothing, rather than matching a caller
  who presents nothing.
  """
  @spec by_key(String.t(), String.t()) :: Trigger.t() | nil
  def by_key(id, key) when is_binary(id) and is_binary(key) do
    case fetch(id) do
      %Trigger{key_hash: hash, key_salt: salt} = trigger when is_binary(hash) and is_binary(salt) ->
        if keyed?(trigger) and key_matches?(trigger, key), do: trigger

      _none ->
        nil
    end
  end

  def by_key(_id, _key), do: nil

  @doc """
  Whether a trigger is one its own key fires: a webhook that names no GitHub repository.

  A schedule is fired by the plane's clock, a repository's trigger by the App's signed
  deliveries, and a manual one by a person or a principal who signed in. A key on any of
  those would be a second door, through which whoever held it fired the trigger with any
  event body they liked. So none is minted for them, and one they still carry from before
  their source changed opens nothing.
  """
  @spec keyed?(Trigger.t()) :: boolean()
  def keyed?(%Trigger{source: %{"kind" => "webhook"} = source}), do: not Issue.repository?(source)
  def keyed?(%Trigger{}), do: false

  # 256 bits, URL-safe so it survives a shell, a YAML file and a CI secret store. Prefixed
  # so that a key found in a log or a repository says what it is and what to rotate — the
  # thing a scanner looks for and a person needs to be told.
  defp mint_key do
    key = "twk_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    {key, key_hash(salt, key), salt}
  end

  defp key_hash(salt, key),
    do: :sha256 |> :crypto.hash(salt <> key) |> Base.encode16(case: :lower)

  defp key_matches?(%Trigger{key_hash: hash, key_salt: salt}, key) do
    presented = key_hash(salt, key)
    byte_size(presented) == byte_size(hash) and :crypto.hash_equals(presented, hash)
  end

  @doc """
  The trigger a caller names, if the caller may fire it.

  A principal may fire the triggers that run as it, and nothing else; a person may fire
  the triggers of the teams they administer. Named by id, by `name`, or by `team/name`
  when a person administers several teams with a trigger of that name.
  """
  @spec for_caller(term(), User.t()) :: {:ok, Trigger.t()} | {:error, Error.t()}
  def for_caller(nil, _user), do: {:error, Error.new(:invalid_params, %{missing: "trigger"})}

  def for_caller(ref, %User{kind: "service", principal: principal}) when is_binary(ref) do
    case find(ref, [principal.team_id]) do
      {:ok, %Trigger{principal_id: id} = trigger} when id == principal.id -> {:ok, trigger}
      {:ok, _other} -> {:error, Error.new(:not_found, %{trigger: ref})}
      error -> error
    end
  end

  def for_caller(ref, %User{} = user) when is_binary(ref) do
    find(ref, user |> Identity.teams_administered_by() |> Enum.map(& &1.id))
  end

  def for_caller(other, _user), do: {:error, Error.new(:invalid_params, %{trigger: other})}

  defp find(ref, team_ids) do
    case candidates(ref, team_ids) do
      [trigger] ->
        {:ok, trigger}

      [] ->
        {:error, Error.new(:not_found, %{trigger: ref})}

      several ->
        names = Enum.map(several, &"#{team_name(&1)}/#{&1.name}")
        {:error, Error.new(:invalid_params, %{reason: "name the team too", triggers: names})}
    end
  end

  # By id, by `team/name`, or by `name` alone, and only within the teams given.
  defp candidates(ref, team_ids) do
    case {Ecto.UUID.cast(ref), String.split(ref, "/", parts: 2)} do
      {{:ok, uuid}, _} ->
        Repo.all(from(t in Trigger, where: t.id == ^uuid and t.team_id in ^team_ids))

      {:error, [team_name, name]} ->
        Repo.all(
          from(t in Trigger,
            join: team in Team,
            on: team.id == t.team_id,
            where: team.name == ^team_name and t.name == ^name and t.team_id in ^team_ids
          )
        )

      {:error, [name]} ->
        Repo.all(from(t in Trigger, where: t.name == ^name and t.team_id in ^team_ids))
    end
  end

  # -- firing -----------------------------------------------------------------

  # How long after a firing a POST without a key of its own is a retry of it.
  @window_seconds 60

  # How long a repeat waits for the session of a firing still making it. A create is a few
  # writes and a placement, so one still going after five seconds is stuck.
  @making_ms 5_000
  @making_poll_ms 50

  # The transaction lock every decision on a run on a GitHub repository is counted under:
  # its profile's and its team's caps are across triggers, which no one trigger's row
  # covers. An arbitrary constant, named rather than inlined.
  @repository_runs_lock 7_461_933_012

  # How long a run may sit with no session before the plane ends it (`end_unmade/1`). A
  # create is a few writes and a placement, seconds; a run with none after ten minutes is
  # one whose request ended between its row and its session.
  @unmade_seconds 600

  @type fired :: %{
          trigger: Trigger.t(),
          revision: Revision.t(),
          run: Run.t(),
          session: Session.t() | nil,
          endpoint: map() | nil
        }

  @doc """
  Fire a trigger: one run per idempotency key, one session per run, at most
  `concurrency` live at once.

  The run row is written *first*, so two callers racing on one key are decided by the
  unique index rather than by luck: the loser reads the winner's run and is handed the
  same session with a fresh token. A run the cap refused is recorded as `skipped` with
  no session, so the record shows the cron fired and says why nothing happened. A run
  whose create failed is retried by the next call with the same key, which is what lets
  an executor retry blindly.

  The revision is resolved **once**, here, before anything is written. A firing that
  overlaps an edit therefore uses the document as it was or as it became, and never a
  mixture — and a run that is retried re-reads the revision it recorded rather than
  picking up whatever the row says today, so a run names exactly one revision for as
  long as it exists.
  """
  @spec fire(Trigger.t(), String.t(), String.t(), map(), String.t()) ::
          {:ok, fired()} | {:error, Error.t()}
  def fire(%Trigger{enabled: false} = trigger, _source, _key, _event, _by),
    do: {:error, disabled(trigger)}

  def fire(%Trigger{} = trigger, source, key, event, by)
      when is_binary(source) and is_binary(key) and is_map(event) do
    with :ok <- check_source(source),
         :ok <- check_event(event) do
      case Repo.get_by(Run, idempotency_key: key) do
        nil ->
          {:ok, revision} = revise(trigger)
          fire_new(trigger, revision, source, key, event, by)

        %Run{trigger_id: id} = run when id == trigger.id ->
          replay(trigger, run)

        %Run{} ->
          {:error, Error.new(:conflict, %{reason: "that key belongs to another trigger"})}
      end
    end
  end

  @doc """
  Fire a trigger for a caller that sent no idempotency key: a firing within a minute of
  one before it, against the same revision, is that one's run, as `fire/5` with its key.

  A minute from the firing it repeats, not the clock's minute, which split a POST at :59
  from its retry a second later into two runs, the second skipped under the cap the
  first held. An executor that retries a failed POST blindly gets the run it already
  made; one that means two firings sends its own key and gets two. The revision is in
  it so that a firing which overlaps an edit is a new run: the second POST is asking for
  something different from the first, whatever the clock says.

  Which run a firing is is decided under the trigger's row lock, so two that race, on
  either side of a minute's turn or not, are one run. `now` is the firing's moment.
  """
  @spec fire_in_window(Trigger.t(), String.t(), map(), String.t(), DateTime.t()) ::
          {:ok, fired()} | {:error, Error.t()}
  def fire_in_window(trigger, source, event, by, now \\ DateTime.utc_now()),
    do: windowed(trigger, source, nil, event, by, now)

  @doc """
  Fire a trigger by a person's hand: a firing within a minute of one before it under the
  same `window` is that one's run, as for a webhook's retry in `fire_in_window/5`.

  `window` names the person and what they asked for: the trigger for a run by hand
  (`manual:<trigger>:<subject>:`), the trigger and the issue for the console's "fix this"
  (`fix:<trigger>:<issue>:<subject>:`). A new run's key is the window and the instant it
  fired. A second click, or a retry of a call whose answer was lost, is the run the first
  made on either side of the clock's minute, and a click a minute on is a run of its own.
  """
  @spec fire_by_hand(Trigger.t(), String.t(), map(), String.t(), DateTime.t()) ::
          {:ok, fired()} | {:error, Error.t()}
  def fire_by_hand(trigger, window, event, by, now \\ DateTime.utc_now()) when is_binary(window),
    do: windowed(trigger, "manual", window, event, by, now)

  defp windowed(%Trigger{enabled: false} = trigger, _source, _window, _event, _by, _now),
    do: {:error, disabled(trigger)}

  defp windowed(%Trigger{} = trigger, source, window, event, by, %DateTime{} = now)
       when is_binary(source) and is_map(event) do
    with :ok <- check_source(source),
         :ok <- check_event(event) do
      {:ok, revision} = revise(trigger)
      window = window || "#{source}:#{trigger.id}:#{revision.hash}:"

      case window_run(trigger, revision, source, window, event, by, now) do
        {:ok, {:repeat, run}} ->
          replay(trigger, run)

        {:ok, {:new, run}} ->
          start(trigger, revision, run)

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  # Under the trigger's row, so the firing that comes second, by a moment or across a
  # minute's turn, reads the run the first wrote.
  defp window_run(trigger, revision, source, window, event, by, now) do
    Repo.transaction(fn ->
      lock(trigger)

      with nil <- in_window(trigger, window, now),
           key = window <> DateTime.to_iso8601(now),
           {:ok, run} <- insert_run(trigger, revision, source, key, event, by, now) do
        {:new, run}
      else
        %Run{} = run -> {:repeat, run}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp lock(trigger) do
    _locked =
      Repo.one(from(t in Trigger, where: t.id == ^trigger.id, select: t.id, lock: "FOR UPDATE"))

    :ok
  end

  # The latest firing of this trigger under the window, within a minute before `now` or
  # after it: one that took the lock first may have read the clock after this one did. The
  # window keys before these were the minute's, under the same prefix, so a firing from just
  # before an upgrade is found as well. What follows the prefix is an instant, so a person
  # whose subject is another's and more (`ab` and `ab:c`) has a window of their own.
  defp in_window(trigger, window, now) do
    since = DateTime.add(now, -@window_seconds, :second)

    from(r in Run,
      where:
        r.trigger_id == ^trigger.id and r.fired_at > ^since and
          like(r.idempotency_key, ^(like_escaped(window) <> "%")),
      order_by: [desc: r.fired_at]
    )
    |> Repo.all()
    |> Enum.find(&instant?(String.replace_prefix(&1.idempotency_key, window, "")))
  end

  defp like_escaped(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))

  defp instant?(text), do: match?({:ok, _at, _offset}, DateTime.from_iso8601(text))

  defp disabled(trigger),
    do: Error.new(:forbidden, %{reason: "trigger is disabled", trigger: trigger.name})

  defp fire_new(trigger, revision, source, key, event, by) do
    case insert_run(trigger, revision, source, key, event, by, DateTime.utc_now()) do
      {:ok, run} ->
        start(trigger, revision, run)

      {:error, changeset} ->
        # The unique key said somebody else fired first, between our lookup and our
        # insert. Their run is the run.
        if duplicate_key?(changeset),
          do: replay(trigger, Repo.get_by!(Run, idempotency_key: key)),
          else: {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
    end
  end

  defp insert_run(trigger, revision, source, key, event, by, fired_at) do
    attrs = %{
      trigger_id: trigger.id,
      revision_id: revision.id,
      idempotency_key: key,
      fired_at: fired_at,
      fired_by: by,
      source: source,
      event: event,
      # Over the payload as it arrived, not over what the run kept. `event` is capped at
      # 16 KiB on purpose; a digest taken after the cap would answer "same" for two
      # firings that differed only past the cut.
      payload_digest: Canonical.hash(event),
      state: "created"
    }

    %Run{} |> Run.changeset(attrs) |> Repo.insert()
  end

  defp start(trigger, revision, run) do
    case admit(trigger, revision, run) do
      {:ok, %Run{} = run} -> create(trigger, revision, run)
      {:ok, {:skipped, run, why}} -> skipped(trigger, revision, run, why)
    end
  end

  # Counted under the trigger's row, and a run on a repository under the lock its caps are
  # counted under across triggers as well, so firings that race are decided one after the
  # other: each counts the runs of the others still deciding as live, and one decided
  # skipped as not. Counted apart, each could count the others and none would start. A run
  # admitted is live from here until its session is made or its create fails, the retry
  # of a failed one included.
  defp admit(trigger, revision, run) do
    Repo.transaction(fn ->
      lock(trigger)

      if Issue.repository?(trigger.source),
        do: Repo.query!("SELECT pg_advisory_xact_lock($1)", [@repository_runs_lock])

      cond do
        live_runs(trigger, run) >= revision.concurrency ->
          skip(run, concurrency_reason(trigger, revision.concurrency))

        over = over_repository_cap(trigger, revision, run) ->
          skip(run, over)

        run.state == "created" ->
          run

        true ->
          run |> Run.changeset(%{state: "created"}) |> Repo.update!()
      end
    end)
  end

  # Live is created, running or waiting: a session still to start, one thinking or
  # acting, or one dormant with an approval pending — that last still counts, because
  # a person has not finished with it and a second one would be a second question. A
  # turn the harness stopped is a run that failed, and holds no place.
  defp live_runs(trigger, %Run{id: except}) do
    Repo.one(
      from(r in Run,
        left_join: s in Session,
        on: s.id == r.session_id,
        where:
          r.trigger_id == ^trigger.id and r.id != ^except and r.state == "created" and
            (is_nil(r.session_id) or s.status == "waiting" or
               (s.state == "active" and s.status not in ["done", "interrupted"] and
                  is_nil(s.failed_reason))),
        select: count(r.id)
      )
    ) || 0
  end

  # A run on a GitHub repository counts against the fix loop's caps as well as its
  # trigger's own: the runs on a repository its profile (`spec.github.maxRuns`) and its
  # team (`github.max_runs`) allow at once, across every trigger of theirs. Live as above.
  defp over_repository_cap(trigger, revision, run) do
    if Issue.repository?(trigger.source) do
      GitHubPolicy.over_runs_cap(revision.profile, trigger.team_id, fn narrow ->
        live_repository_runs(run, narrow)
      end)
    end
  end

  defp live_repository_runs(%Run{id: except}, narrow) do
    query =
      from(r in Run,
        join: t in Trigger,
        on: t.id == r.trigger_id,
        join: v in Revision,
        on: v.id == r.revision_id,
        left_join: s in Session,
        on: s.id == r.session_id,
        where:
          r.id != ^except and r.state == "created" and
            fragment("(?->>'repository') IS NOT NULL", t.source) and
            (is_nil(r.session_id) or s.status == "waiting" or
               (s.state == "active" and s.status not in ["done", "interrupted"] and
                  is_nil(s.failed_reason))),
        select: count(r.id)
      )

    Repo.one(narrow_runs(query, narrow)) || 0
  end

  defp narrow_runs(query, profile: profile),
    do: from([_r, _t, v, _s] in query, where: v.profile == ^profile)

  defp narrow_runs(query, team_id: team_id),
    do: from([_r, t, _v, _s] in query, where: t.team_id == ^team_id)

  # The run keeps why it started nothing, so the Runs screen and a delivery's outcome can
  # say it, and not only the plane's log.
  defp skip(run, why) do
    {:skipped, run |> Run.changeset(%{state: "skipped", reason: why}) |> Repo.update!(), why}
  end

  defp skipped(trigger, revision, run, why) do
    Logger.info("troupe plane: trigger #{trigger.name} fired over a cap (#{why}); skipped")
    {:ok, fired(trigger, revision, run, nil, nil)}
  end

  defp concurrency_reason(trigger, 1),
    do: "#{trigger.name} allows 1 run at once (concurrency), and one is going"

  defp concurrency_reason(trigger, cap),
    do: "#{trigger.name} allows #{cap} runs at once (concurrency), and that many are going"

  defp create(trigger, revision, run) do
    with {:ok, user, principal} <- principal_user(revision),
         {:ok, endpoint} <-
           Harness.call(
             "session.create",
             create_params(trigger, revision, run, principal),
             context(user)
           ) do
      session_id = endpoint["session_id"]

      revision.notify
      |> Enum.reject(&Identity.removed_owner(&1, revision.inserted_at))
      |> Enum.each(&let_in(user, session_id, &1))

      {:ok, run} =
        run |> Run.changeset(%{session_id: session_id, state: "created"}) |> Repo.update()

      {:ok, fired(trigger, revision, run, Sessions.get(session_id), endpoint)}
    else
      {:error, %Error{} = error} ->
        # Recorded, so the run shows what happened and the next call with the same key
        # tries again rather than being told this is the run.
        {:ok, _} = run |> Run.changeset(%{state: "failed"}) |> Repo.update()
        Logger.warning("troupe plane: trigger #{trigger.name} could not create: #{error.message}")
        {:error, error}
    end
  end

  # The same key again. A skipped run stays skipped; a failed one is retried, counted
  # against the caps as a firing is, so its session is not one past them; a run with
  # a session is handed that session and a token minted now, because the one minted the
  # first time has almost certainly expired.
  #
  # Every branch reads the run's own revision rather than resolving the trigger's
  # current one: a retry of a failed create is the same run, and a run that named two
  # documents would be exactly the provenance this table exists to prevent.
  defp replay(trigger, %Run{} = run), do: replay(trigger, revision_of(run), run)

  defp replay(trigger, revision, %Run{state: "skipped"} = run) do
    {:ok, fired(trigger, revision, run, nil, nil)}
  end

  defp replay(trigger, revision, %Run{state: "failed", session_id: nil} = run) do
    start(trigger, revision, run)
  end

  # Neither skipped nor failed and no session yet: the firing that wrote it is making its
  # session, in another request, and this one overtook it. It is waited for, so a retry
  # is answered with the session the first one gets; one still being made after that is
  # a duplicate, and the answer names the run.
  defp replay(trigger, revision, %Run{session_id: nil} = run) do
    case made(run, @making_ms) do
      %Run{state: "created", session_id: nil} ->
        {:error,
         Error.new(:conflict, %{
           reason: "the run this firing repeats is still starting its session",
           run: run.id
         })}

      settled ->
        replay(trigger, revision, settled)
    end
  end

  defp replay(trigger, revision, %Run{session_id: session_id} = run) do
    with {:ok, user, _principal} <- principal_user(revision),
         {:ok, endpoint} <-
           Harness.call("token.mint", %{"session_id" => session_id}, context(user)) do
      {:ok, fired(trigger, revision, run, Sessions.get(session_id), endpoint)}
    end
  end

  defp made(run, left) do
    case Repo.get(Run, run.id) do
      %Run{state: "created", session_id: nil} when left > 0 ->
        Process.sleep(@making_poll_ms)
        made(run, left - @making_poll_ms)

      %Run{} = now ->
        now

      nil ->
        run
    end
  end

  @doc """
  End every run that has had no session for ten minutes. Its request ended between the
  run's row and its session, a crash or a replica going down, and nothing else would end
  it: it held a place against its trigger's cap for good, and a repeat of it was told it
  was still starting its session. Ended `failed`, the reason on the row, and audited; the
  next call with its key makes its session, as after any create that failed. The
  scheduler's tick runs this. Answers the runs it ended.
  """
  @spec end_unmade(DateTime.t()) :: [Run.t()]
  def end_unmade(now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@unmade_seconds, :second)

    reason =
      "no session was made for it in #{div(@unmade_seconds, 60)} minutes: the request that " <>
        "fired it ended first, and the plane ended the run"

    from(r in Run,
      where: r.state == "created" and is_nil(r.session_id) and r.updated_at < ^since,
      preload: [trigger: :team]
    )
    |> Repo.all()
    # Only where it is still so: a create that finished late has made its session.
    |> Enum.filter(fn run ->
      {ended, _} =
        Repo.update_all(
          from(r in Run,
            where: r.id == ^run.id and r.state == "created" and is_nil(r.session_id)
          ),
          set: [state: "failed", reason: reason, updated_at: now]
        )

      ended == 1
    end)
    |> Enum.map(fn %Run{trigger: trigger} = run ->
      {:ok, _} =
        Audit.record("scheduler", "trigger.run.end", "#{trigger.team.name}/#{trigger.name}", %{
          "run" => run.id,
          "reason" => reason
        })

      Logger.warning("troupe plane: trigger #{trigger.name}'s run #{run.id} ended: #{reason}")
      %{run | state: "failed", reason: reason}
    end)
  end

  defp fired(trigger, revision, run, session, endpoint) do
    %{trigger: trigger, revision: revision, run: run, session: session, endpoint: endpoint}
  end

  # A run always has one — the column is not null and the migration backfilled every row
  # that predates it — but a `Repo.get` that answered `nil` here would be a silent fall
  # back to the mutable row, so it raises instead.
  defp revision_of(%Run{revision_id: id, id: run_id}) do
    case Repo.get(Revision, id) do
      %Revision{} = revision -> revision
      nil -> raise "troupe plane: run #{run_id} names revision #{id}, which is gone"
    end
  end

  defp create_params(trigger, revision, run, principal) do
    values = %{
      "event" => run.event,
      "trigger" => %{"name" => trigger.name, "profile" => revision.profile},
      "run" => %{
        "idempotency_key" => run.idempotency_key,
        "fired_at" => DateTime.to_iso8601(run.fired_at),
        "revision" => revision.revision,
        "revision_hash" => revision.hash
      }
    }

    %{
      "profile" => revision.profile,
      "team" => team_name(trigger),
      "title" => title(trigger, run),
      "prompt" => prompt(revision, run, values),
      "visibility" => revision.visibility,
      "terms" => revision.terms,
      "origin" =>
        Origin.trigger(
          trigger.name,
          source: run.source,
          idempotency_key: run.idempotency_key,
          revision: revision.hash,
          payload_digest: run.payload_digest,
          # Who fired it, and on whose authority. The principal is the actor; its sponsor
          # is the person answerable for what it does, and a run with no sponsor is a run
          # nobody is — which is why a principal cannot exist without one.
          principal: principal_pair(principal)
        )
    }
    |> then(fn params ->
      if revision.agent, do: Map.put(params, "agent", revision.agent), else: params
    end)
    |> then(fn params ->
      case repository_of(revision.source) do
        nil -> params
        repository -> Map.put(params, "repository", repository)
      end
    end)
  end

  # The trigger and when it fired; a run GitHub started names its issue instead, which is
  # what somebody scanning a list of sessions is looking for.
  defp title(trigger, %Run{event: %{"github" => %{}, "repository" => repo, "issue" => issue}})
       when is_binary(repo) and is_map(issue),
       do: "#{trigger.name} #{repo}##{issue["number"]}"

  defp title(trigger, run),
    do: "#{trigger.name} #{Calendar.strftime(run.fired_at, "%Y-%m-%d %H:%M")}"

  # A run that GitHub's webhook started is given its issue fenced as data, after the
  # template rendered without the issue's text (`GitHub.Issue.prompt/2`). Any other run,
  # a repository trigger's run by hand included, renders the template as it always has.
  defp prompt(revision, run, values) do
    if Issue.repository?(revision.source) and is_map(run.event["github"]),
      do: Issue.prompt(revision.prompt_template, values),
      else: Template.render(revision.prompt_template, values)
  end

  # The repository a trigger's source names is the one its sessions are created with, so
  # `session.create` checks it as it checks anybody's, and the session's pod clones it.
  defp repository_of(source) do
    case Issue.repository(source) do
      {owner, name} ->
        %{"owner" => owner, "name" => name}
        |> then(&if(source["ref"], do: Map.put(&1, "ref", source["ref"]), else: &1))

      nil ->
        nil
    end
  end

  # Through the public method, as the owner: the same path a person sharing a session
  # takes, so what a `notify` subject may do is exactly what a collaborator may.
  #
  # Not a subject whose person was removed after the revision was recorded: a removal
  # takes them off the trigger's list, but a run retried from a revision older than that
  # still names them, and the grant would go to whoever holds the subject next.
  defp let_in(user, session_id, subject) do
    params = %{"session_id" => session_id, "subject" => subject, "role" => "collaborator"}

    case Harness.call("session.grant", params, context(user)) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "troupe plane: could not let #{subject} in to #{session_id}: #{error.message}"
        )
    end
  end

  defp principal_user(%{principal_id: principal_id}) do
    case Principals.fetch(principal_id) do
      nil ->
        {:error, Error.new(:forbidden, %{reason: "the trigger's principal is gone"})}

      principal ->
        case Principals.user_for(principal) do
          nil -> {:error, Error.new(:forbidden, %{reason: "the trigger's principal is disabled"})}
          user -> {:ok, user, principal}
        end
    end
  end

  # A principal acts on its sponsor's authority. Where the sponsor is gone the principal
  # is already disabled and never reaches here; where a row predates sponsors the
  # principal stands for itself, which is what it did before there was anybody else to
  # name.
  defp principal_pair(%{subject: subject, sponsor_subject: sponsor}) when is_binary(sponsor),
    do: Principal.of(sponsor, subject)

  defp principal_pair(%{subject: subject}), do: Principal.of(subject)

  defp context(user), do: %{user: user, platform_admin?: false}

  # -- runs -------------------------------------------------------------------

  @doc "A team's runs, newest first, optionally one trigger's."
  @spec runs(Team.t(), keyword()) :: [{Run.t(), Trigger.t(), Session.t() | nil}]
  def runs(%Team{} = team, opts \\ []) do
    query =
      from(r in Run,
        join: t in Trigger,
        on: t.id == r.trigger_id,
        left_join: s in Session,
        on: s.id == r.session_id,
        where: t.team_id == ^team.id,
        order_by: [desc: r.fired_at],
        limit: ^Keyword.get(opts, :limit, 50),
        preload: [:revision],
        select: {r, t, s}
      )

    query =
      case Keyword.get(opts, :trigger) do
        nil -> query
        name -> from([r, t] in query, where: t.name == ^name)
      end

    Repo.all(query)
  end

  @doc """
  What a run is doing now, from its session.

  The row records only what the plane decided at firing; everything after is the
  session's status, which the worker keeps current. A session that finished by budget is
  `done` — a trigger with `max_turns: 3` is *meant* to end that way — and `failed` is
  the session interrupted or ended for any other reason, or a turn the harness stopped:
  the failure guard's (Decision 687) or a root that kept crashing (727), whose root is at
  rest and would otherwise read as running, or as never started once it is asleep.
  """
  @spec state_of(Run.t(), Session.t() | nil) :: String.t()
  def state_of(%Run{state: "skipped"}, _session), do: "skipped"
  def state_of(%Run{state: "failed"}, _session), do: "failed"
  def state_of(%Run{session_id: nil}, _session), do: "created"
  def state_of(%Run{}, nil), do: "failed"
  def state_of(%Run{}, %Session{failed_reason: reason}) when is_binary(reason), do: "failed"

  def state_of(%Run{}, %Session{} = session) do
    case session.status do
      "waiting" ->
        "waiting"

      "interrupted" ->
        "failed"

      "done" ->
        if session.done_reason in [nil, "finished", "budget_exhausted"],
          do: "done",
          else: "failed"

      "idle" ->
        if session.state == "active", do: "running", else: "created"

      _busy ->
        "running"
    end
  end

  @doc """
  Tell a run's trigger's target that the run ended, if it named one.

  Synchronous, and the caller decides whether to wait: the control connection does not,
  because a pod reporting that a session finished should not be held up by somebody
  else's HTTP server.

  The target is read from the trigger **now**, not from the revision the run froze. Every
  other question about a run is answered by its revision on purpose — what it ran, as
  whom, under which terms — but a notification target is not a fact about the run. It is
  where somebody wants to be told today, and an administrator who moved their receiver
  because the old one is gone means the runs in flight too.

  How it ended is read from the session's row, which the report that ended it has just
  written: the run's state as a listing gives it (`done` or `failed`), and the reasons
  the worker gave — why the session finished, or why the harness stopped its last turn.
  """
  @spec announce(String.t()) :: :ok | {:error, String.t()}
  def announce(session_id) when is_binary(session_id) do
    with %Run{} = run <- Repo.get_by(Run, session_id: session_id),
         %Trigger{} = trigger <- Repo.get(Trigger, run.trigger_id) do
      session = Sessions.get(session_id)

      Notify.deliver(trigger, run, %{
        "state" => state_of(run, session),
        "done_reason" => session && session.done_reason,
        "failed_reason" => session && session.failed_reason,
        "pull_request" => pull_request_url(session)
      })
    else
      nil -> :ok
    end
  end

  # The draft pull request the run's session opened, which is where a person reviews what
  # it did. A link, as the session's record keeps it: metadata, never its text.
  defp pull_request_url(%Session{github: %{"pull_request" => %{"url" => url}}})
       when is_binary(url),
       do: url

  defp pull_request_url(_session), do: nil

  @doc """
  Every enabled trigger on a GitHub repository, named `owner/name` as GitHub does, in any
  case: the ones a delivery from that repository may start.
  """
  @spec on_repository(String.t()) :: [Trigger.t()]
  def on_repository(full_name) when is_binary(full_name) do
    Repo.all(
      from(t in Trigger,
        where:
          t.enabled and fragment("?->>'kind'", t.source) == "webhook" and
            fragment("lower(?->>'repository')", t.source) == ^String.downcase(full_name),
        order_by: [t.team_id, t.name]
      )
    )
  end

  @doc """
  The run whose session this is, with its trigger, or `nil` for a session no trigger
  started.
  """
  @spec run_of(String.t()) :: {Run.t(), Trigger.t()} | nil
  def run_of(session_id) do
    Repo.one(
      from(r in Run,
        join: t in Trigger,
        on: t.id == r.trigger_id,
        where: r.session_id == ^session_id,
        preload: [:revision],
        limit: 1,
        select: {r, t}
      )
    )
  end

  @doc """
  The user a run acts as: its revision's principal, or why it cannot act. What a review
  that resumes a run's session acts as, as its first firing did.
  """
  @spec acting_user(Run.t()) :: {:ok, User.t()} | {:error, Error.t()}
  def acting_user(%Run{} = run) do
    with {:ok, user, _principal} <- principal_user(revision_of(run)), do: {:ok, user}
  end

  @doc "Mark the run behind a session reviewed, if there is one."
  @spec reviewed(String.t(), String.t()) :: :ok
  def reviewed(session_id, by) do
    Repo.update_all(
      from(r in Run, where: r.session_id == ^session_id and is_nil(r.reviewed_at)),
      set: [reviewed_by: by, reviewed_at: DateTime.utc_now()]
    )

    :ok
  end

  # -- rendering --------------------------------------------------------------

  @doc "What `trigger.fire` answers: the run, and where the session is."
  @spec fired_json(fired()) :: map()
  def fired_json(%{run: run, revision: revision, session: session, endpoint: endpoint}) do
    %{"run" => run_json(%{run | revision: revision}, session)}
    |> Map.merge(endpoint || %{})
    |> Map.put("session_id", session && session.id)
    |> Map.put("state", state_of(run, session))
  end

  @doc """
  A run as a listing shows it.

  `revision` and `revision_hash` are the question a person reviewing a bad run actually
  has — *which wording produced this* — and they answer it without a join the caller has
  to remember, which is why `runs/2` preloads rather than leaving it to each caller.
  """
  @spec run_json(Run.t(), Session.t() | nil) :: map()
  def run_json(%Run{} = run, session) do
    %{
      "id" => run.id,
      "trigger_id" => run.trigger_id,
      "revision_id" => run.revision_id,
      "revision" => revision_number(run),
      "revision_hash" => revision_hash(run),
      "idempotency_key" => run.idempotency_key,
      "session_id" => run.session_id,
      "fired_at" => DateTime.to_iso8601(run.fired_at),
      "fired_by" => run.fired_by,
      "source" => run.source,
      "event" => run.event,
      "payload_digest" => run.payload_digest,
      "state" => state_of(run, session),
      # Why a skipped run started nothing: the cap that said no.
      "reason" => run.reason,
      "status" => session && session.status,
      "done_reason" => session && session.done_reason,
      "failed_reason" => session && session.failed_reason,
      "pending_approvals" => session && session.pending_approvals,
      "pending_questions" => session && session.pending_questions,
      "cost_micros" => session && session.cost_micros,
      # The repository a run on one worked in, and the issue that started it, where GitHub
      # did: what the Runs screen lists a run by.
      "repository" => run_repository(run),
      "issue" => run_issue(run.event),
      # The branch, last commit and draft pull request the run's session left on GitHub.
      "github" => session && session.github,
      "reviewed_by" => run.reviewed_by,
      "reviewed_at" => run.reviewed_at && DateTime.to_iso8601(run.reviewed_at)
    }
  end

  defp run_repository(%Run{event: %{"github" => %{}, "repository" => repository}})
       when is_binary(repository),
       do: repository

  defp run_repository(%Run{revision: %Revision{source: source}}) do
    case Issue.repository(source) do
      {owner, name} -> "#{owner}/#{name}"
      nil -> nil
    end
  end

  defp run_repository(%Run{}), do: nil

  defp run_issue(%{"github" => %{}, "issue" => %{} = issue}),
    do: Map.take(issue, ["number", "url", "title"])

  defp run_issue(_event), do: nil

  defp revision_number(%Run{revision: %Revision{revision: number}}), do: number
  defp revision_number(%Run{}), do: nil

  defp revision_hash(%Run{revision: %Revision{hash: hash}}), do: hash
  defp revision_hash(%Run{}), do: nil

  @doc """
  A trigger as a listing shows it, with the revision its next firing would use.

  `revision` is resolved rather than stored on the row: it is a function of the document
  and making it a column would be a second copy of a fact the hash already decides.
  """
  @spec trigger_json(Trigger.t()) :: map()
  def trigger_json(%Trigger{} = trigger) do
    principal = Principals.fetch(trigger.principal_id)
    {:ok, revision} = revise(trigger)

    %{
      "revision" => Revision.json(revision),
      "id" => trigger.id,
      "team" => team_name(trigger),
      "name" => trigger.name,
      "principal" => principal && principal.subject,
      "profile" => trigger.profile,
      "agent" => trigger.agent,
      "enabled" => trigger.enabled,
      "source" => trigger.source,
      "prompt_template" => trigger.prompt_template,
      "terms" => trigger.terms,
      "visibility" => trigger.visibility,
      "review" => trigger.review,
      "notify" => trigger.notify,
      "notify_url" => trigger.notify_url,
      "concurrency" => trigger.concurrency,
      # Whether there is a key and when it was last minted, never the key. A listing that
      # carried it would put a credential in every console, every audit row that quotes a
      # listing, and every log line that logged a response. A key a trigger that takes none
      # still holds opens nothing, and is no key.
      "has_key" => keyed?(trigger) and is_binary(trigger.key_hash),
      "key_rotated_at" => trigger.key_rotated_at && DateTime.to_iso8601(trigger.key_rotated_at),
      "key_rotated_by" => trigger.key_rotated_by,
      "last_fired_at" => trigger.last_fired_at && DateTime.to_iso8601(trigger.last_fired_at),
      "created_by" => trigger.created_by,
      "updated_at" => trigger.updated_at && DateTime.to_iso8601(trigger.updated_at)
    }
  end

  # -- checks -----------------------------------------------------------------

  defp principal_id(team, attrs, existing) do
    case attrs["principal"] || attrs["principal_id"] do
      nil when not is_nil(existing) ->
        {:ok, existing.principal_id}

      nil ->
        {:error, Error.new(:invalid_params, %{missing: "principal"})}

      subject when is_binary(subject) ->
        case Principals.get(subject) || Principals.fetch(subject) do
          %{team_id: team_id, id: id} when team_id == team.id -> {:ok, id}
          _ -> {:error, Error.new(:not_found, %{principal: subject, team: team.name})}
        end

      other ->
        {:error, Error.new(:invalid_params, %{principal: other})}
    end
  end

  defp check_terms(nil), do: :ok

  defp check_terms(%{} = terms) do
    case Map.keys(terms) -- @term_keys do
      [] ->
        :ok

      unknown ->
        reason = "terms takes #{Enum.join(@term_keys, ", ")}"
        {:error, Error.new(:invalid_params, %{reason: reason, unknown: unknown})}
    end
  end

  defp check_terms(_other) do
    {:error, Error.new(:invalid_params, %{reason: "terms is an object"})}
  end

  defp check_source(source) do
    if source in Run.sources(),
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_params, %{field: "source", source: source, one_of: Run.sources()})}
  end

  defp check_event(event) do
    if byte_size(Jason.encode!(event)) <= @max_event_bytes,
      do: :ok,
      else: {:error, Error.new(:payload_too_large, %{field: "event", limit: @max_event_bytes})}
  end

  defp duplicate_key?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
      field == :idempotency_key and opts[:constraint] == :unique
    end)
  end

  defp team_name(%{team_id: team_id}) do
    case Identity.fetch_team(team_id) do
      nil -> nil
      team -> team.name
    end
  end
end
