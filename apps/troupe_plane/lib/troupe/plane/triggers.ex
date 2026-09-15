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

  alias Troupe.Plane.{Harness, Identity, Principals, Repo, Sessions}
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Plane.Triggers.{Revision, Run, Template, Trigger}
  alias Troupe.Protocol.Error

  require Logger

  # An event is what a provider filter let through — an issue key, a title, a URL — and
  # this is the most of one a run will keep. A whole webhook body is not a record; it is
  # a place to hide instructions.
  @max_event_bytes 16_384

  @term_keys ~w(budget_micros max_turns wall_clock_seconds approvals)

  @doc "How large a run's event may be, encoded."
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes, do: @max_event_bytes

  # -- definitions ------------------------------------------------------------

  @doc "A team's triggers, by name."
  @spec list(Team.t()) :: [Trigger.t()]
  def list(%Team{} = team) do
    Repo.all(from(t in Trigger, where: t.team_id == ^team.id, order_by: t.name))
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
      fields =
        ~w(name profile agent enabled source prompt_template terms visibility) ++
          ~w(review notify concurrency)

      (existing || %Trigger{team_id: team.id, created_by: by})
      |> Trigger.changeset(attrs |> Map.take(fields) |> Map.put("principal_id", principal_id))
      |> Repo.insert_or_update()
      |> case do
        {:ok, trigger} ->
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
  @spec fire(Trigger.t(), String.t(), map(), String.t()) :: {:ok, fired()} | {:error, Error.t()}
  def fire(%Trigger{enabled: false} = trigger, _key, _event, _by) do
    {:error, Error.new(:forbidden, %{reason: "trigger is disabled", trigger: trigger.name})}
  end

  def fire(%Trigger{} = trigger, key, event, by) when is_binary(key) and is_map(event) do
    with :ok <- check_event(event) do
      case Repo.get_by(Run, idempotency_key: key) do
        nil ->
          {:ok, revision} = revise(trigger)
          fire_new(trigger, revision, key, event, by)

        %Run{trigger_id: id} = run when id == trigger.id ->
          replay(trigger, run)

        %Run{} ->
          {:error, Error.new(:conflict, %{reason: "that key belongs to another trigger"})}
      end
    end
  end

  defp fire_new(trigger, revision, key, event, by) do
    attrs = %{
      trigger_id: trigger.id,
      revision_id: revision.id,
      idempotency_key: key,
      fired_at: DateTime.utc_now(),
      fired_by: by,
      event: event,
      state: "created"
    }

    case %Run{} |> Run.changeset(attrs) |> Repo.insert() do
      {:ok, run} ->
        if live_runs(trigger, run) >= revision.concurrency,
          do: skip(trigger, revision, run),
          else: create(trigger, revision, run)

      {:error, changeset} ->
        # The unique key said somebody else fired first, between our lookup and our
        # insert. Their run is the run.
        if duplicate_key?(changeset),
          do: replay(trigger, Repo.get_by!(Run, idempotency_key: key)),
          else: {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
    end
  end

  # Live is created, running or waiting: a session still to start, one thinking or
  # acting, or one dormant with an approval pending — that last still counts, because
  # a person has not finished with it and a second one would be a second question.
  defp live_runs(trigger, %Run{id: except}) do
    Repo.one(
      from(r in Run,
        left_join: s in Session,
        on: s.id == r.session_id,
        where:
          r.trigger_id == ^trigger.id and r.id != ^except and r.state == "created" and
            (is_nil(r.session_id) or s.status == "waiting" or
               (s.state == "active" and s.status not in ["done", "interrupted"])),
        select: count(r.id)
      )
    ) || 0
  end

  defp skip(trigger, revision, run) do
    {:ok, run} = run |> Run.changeset(%{state: "skipped"}) |> Repo.update()
    Logger.info("troupe plane: trigger #{trigger.name} fired over its concurrency cap; skipped")
    {:ok, fired(trigger, revision, run, nil, nil)}
  end

  defp create(trigger, revision, run) do
    with {:ok, user} <- principal_user(revision),
         {:ok, endpoint} <-
           Harness.call("session.create", create_params(trigger, revision, run), context(user)) do
      session_id = endpoint["session_id"]
      Enum.each(revision.notify, &let_in(user, session_id, &1))

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

  # The same key again. A skipped run stays skipped; a failed one is retried; a run with
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
    create(trigger, revision, run)
  end

  defp replay(trigger, revision, %Run{session_id: nil} = run) do
    {:ok, fired(trigger, revision, run, nil, nil)}
  end

  defp replay(trigger, revision, %Run{session_id: session_id} = run) do
    with {:ok, user} <- principal_user(revision),
         {:ok, endpoint} <-
           Harness.call("token.mint", %{"session_id" => session_id}, context(user)) do
      {:ok, fired(trigger, revision, run, Sessions.get(session_id), endpoint)}
    end
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

  defp create_params(trigger, revision, run) do
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
      "title" => "#{trigger.name} #{Calendar.strftime(run.fired_at, "%Y-%m-%d %H:%M")}",
      "prompt" => Template.render(revision.prompt_template, values),
      "visibility" => revision.visibility,
      "terms" => revision.terms,
      "origin" => %{
        "kind" => "trigger",
        "trigger" => trigger.name,
        "run" => run.idempotency_key,
        "revision" => revision.hash
      }
    }
    |> then(fn params ->
      if revision.agent, do: Map.put(params, "agent", revision.agent), else: params
    end)
  end

  # Through the public method, as the owner: the same path a person sharing a session
  # takes, so what a `notify` subject may do is exactly what a collaborator may.
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
          user -> {:ok, user}
        end
    end
  end

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
  the session interrupted or ended for any other reason.
  """
  @spec state_of(Run.t(), Session.t() | nil) :: String.t()
  def state_of(%Run{state: "skipped"}, _session), do: "skipped"
  def state_of(%Run{state: "failed"}, _session), do: "failed"
  def state_of(%Run{session_id: nil}, _session), do: "created"
  def state_of(%Run{}, nil), do: "failed"

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
      "event" => run.event,
      "state" => state_of(run, session),
      "status" => session && session.status,
      "done_reason" => session && session.done_reason,
      "pending_approvals" => session && session.pending_approvals,
      "cost_micros" => session && session.cost_micros,
      "reviewed_by" => run.reviewed_by,
      "reviewed_at" => run.reviewed_at && DateTime.to_iso8601(run.reviewed_at)
    }
  end

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
      "concurrency" => trigger.concurrency,
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
