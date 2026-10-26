defmodule Troupe.Plane.Memory do
  @moduledoc """
  The memory documents (#55): what the organisation, each team and each worker profile
  wrote for every agent in their scope, and each person's own. The organisation's levels are
  edited in the console (`Troupe.Plane.Admin`) and handed to the sessions they reach as
  instructions from the organisation, read-only to every agent. A person's own is theirs:
  edited by them alone (`save_own/4`), added to by an agent of theirs one entry at a time
  (`append_own/3`), read by every session they run and by nobody else, every version kept
  with who saved it as the others are.

  - **On a pod** a session gets its organisation's, its team's and its profile's, with
    every activation (`for_session/2`), so a save reaches a session the next time it wakes.
  - **On a laptop** the daemon of a person signed in asks `me.memory`, signed by the
    plane's key, for the organisation's and every team of theirs (`for_person/1`), and
    keeps the copy as it keeps the organisation's document. A laptop's session belongs to
    no team, so it reads the person's teams'.

  What each running session's last turn read is kept as well (`Troupe.Plane.Memory.Read`):
  a pod's session says it as each turn begins and is answered with the documents in force
  where it is behind (`turn/2`), and a laptop's daemon says it of its sessions with its poll
  (`machine/2`). `readers/1` is who is behind, what the console shows.

  A team's document reaches only that team's sessions and its members' machines; a person's
  own, every session they own, on a pod and on their machines, after the organisation's
  levels, which come first.

  A document is text, at most `Troupe.Protocol.Memory.max_bytes/0` bytes. Each save is a
  new version, numbered from 1; an empty one clears the document, which then reaches no
  session, and is a version like any other. A save names the version it replaces, so two
  administrators editing one document at once do not overwrite each other: the second is
  told what the first saved.
  """

  import Ecto.Query

  alias Troupe.Plane.{Audit, Fleet, Identity, Repo, Sessions}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Fleet.Extends
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Memory.{Document, Read}
  alias Troupe.Protocol.Memory, as: Shape

  @type scope :: String.t()

  @typedoc "Whose a document is: the organisation's, a team, a profile by name, or a person."
  @type owner :: :organisation | Team.t() | String.t() | User.t()

  # One entry an agent adds to a person's memory: a sentence or two, on one line.
  @entry_bytes 1_024

  # How many sessions one machine's poll may say it runs, and how long one it named counts
  # as running: three polls of five minutes.
  @machine_sessions 64
  @running_seconds 900

  @machine_nudge "a session on a person's machine is not told: its daemon asks for the memory " <>
                   "at its next poll, within five minutes, and the session reads it at its next turn"

  # -- reading ----------------------------------------------------------------

  @doc "The version in force of one document, or `nil` for one never saved."
  @spec current(owner()) :: Document.t() | nil
  def current(owner) do
    {scope, key} = key(owner)

    Document
    |> where([d], d.scope == ^scope and d.owner == ^key)
    |> order_by([d], desc: d.version)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Every version of one document, newest first."
  @spec versions(owner()) :: [Document.t()]
  def versions(owner) do
    {scope, key} = key(owner)

    Document
    |> where([d], d.scope == ^scope and d.owner == ^key)
    |> order_by([d], desc: d.version)
    |> Repo.all()
  end

  @doc "One version of one document, or `nil`."
  @spec version(owner(), pos_integer()) :: Document.t() | nil
  def version(owner, number) when is_integer(number) do
    {scope, key} = key(owner)
    Repo.get_by(Document, scope: scope, owner: key, version: number)
  end

  # -- saving -----------------------------------------------------------------

  @doc """
  Save a new version of a document, as `subject`, over `base`: the version the editor
  started from, `0` for a document never saved, or `nil` for whatever is in force.

  `{:ok, %{before: version or nil, now: version}}`; `{:ok, :unchanged}` for the text in
  force already, which makes no version; `{:error, {:conflict, current}}` where somebody
  saved over `base` first; `{:error, reason}` for a text that cannot be a document.
  """
  @spec put(owner(), String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, %{before: Document.t() | nil, now: Document.t()}}
          | {:ok, :unchanged}
          | {:error, {:conflict, non_neg_integer()} | String.t()}
  def put(owner, text, subject, base \\ nil) do
    {scope, key} = key(owner)

    with :ok <- Shape.check(text),
         text = Shape.normalise(text),
         before = current(owner),
         :ok <- based_on(before, base) do
      if before && before.text == text,
        do: {:ok, :unchanged},
        else: insert(owner, {scope, key}, before, text, subject)
    end
  end

  defp insert(owner, {scope, key}, before, text, subject) do
    %Document{}
    |> Document.changeset(%{
      scope: scope,
      owner: key,
      version: number(before) + 1,
      text: text,
      hash: Shape.hash(text),
      changed_by: subject
    })
    |> Repo.insert()
    |> case do
      {:ok, now} -> {:ok, %{before: before, now: now}}
      # Two saves over the same version at once: the unique index lets one through.
      {:error, _changeset} -> {:error, {:conflict, number(current(owner))}}
    end
  end

  defp based_on(_before, nil), do: :ok
  defp based_on(before, base) when is_integer(base) and base == 0 and is_nil(before), do: :ok
  defp based_on(%Document{version: version}, version), do: :ok
  defp based_on(before, base) when is_integer(base), do: {:error, {:conflict, number(before)}}
  defp based_on(_before, _base), do: {:error, "version is the number of the version edited"}

  defp number(nil), do: 0
  defp number(%Document{version: version}), do: version

  # -- comparing --------------------------------------------------------------

  @doc """
  What changes between two texts, line by line: each line once, as it stays (`same`),
  goes (`del`) or comes (`add`), in order. What a preview shows before a save, and what a
  version shows against the one before it.
  """
  @spec diff(String.t() | nil, String.t() | nil) :: [%{String.t() => String.t()}]
  def diff(before, now) do
    List.myers_difference(lines(before), lines(now))
    |> Enum.flat_map(fn {op, lines} ->
      Enum.map(lines, &%{"op" => op_name(op), "text" => &1})
    end)
  end

  defp lines(nil), do: []
  defp lines(""), do: []
  defp lines(text), do: String.split(text, "\n")

  defp op_name(:eq), do: "same"
  defp op_name(:del), do: "del"
  defp op_name(:ins), do: "add"

  @doc """
  Who wrote each line of a document as it stands at version `upto` (the version in force
  where `nil`): blame, not history. Each line is `text`, `version`, the version it came in,
  `by`, who saved that version, and `at`; an agent's entry adds `session` and `agent`, the
  session and the agent it came from. A rollback's lines keep who wrote them in the version
  rolled back to.

  Derived and kept nowhere: each version's lines against the one before it, by the same line
  diff a preview shows, and the session and agent from the version's audit row.
  """
  @spec blame(owner(), pos_integer() | nil) :: [map()]
  def blame(owner, upto \\ nil) do
    written = written(owner)

    {lines, _by_version} =
      owner
      |> versions()
      |> Enum.reverse()
      |> Enum.filter(&(is_nil(upto) or &1.version <= upto))
      |> Enum.reduce({[], %{}}, fn document, {lines, by_version} ->
        from = Map.get(written, document.version, %{})

        now =
          case by_version[from["rolled_back_to"]] do
            nil -> attributed(lines, document, from)
            restored -> restored
          end

        {now, Map.put(by_version, document.version, now)}
      end)

    lines
  end

  # Each version's line diff against the lines before it, as they were attributed: a line
  # that stays keeps who wrote it, a line that comes is this version's.
  defp attributed(before, document, from) do
    {kept, _rest} =
      before
      |> Enum.map(& &1["text"])
      |> List.myers_difference(lines(document.text))
      |> Enum.reduce({[], before}, fn
        {:eq, texts}, {acc, old} ->
          {same, old} = Enum.split(old, length(texts))
          {Enum.reverse(same, acc), old}

        {:del, texts}, {acc, old} ->
          {acc, Enum.drop(old, length(texts))}

        {:ins, texts}, {acc, old} ->
          {Enum.reverse(Enum.map(texts, &line(&1, document, from)), acc), old}
      end)

    Enum.reverse(kept)
  end

  defp line(text, document, from) do
    %{
      "text" => text,
      "version" => document.version,
      "by" => document.changed_by,
      "at" => DateTime.to_iso8601(document.inserted_at)
    }
    |> Map.merge(Map.take(from, ["session", "agent"]))
  end

  # What each version's audit row says of where it came from: the session and the agent of
  # an agent's entry, and the version a rollback restored.
  defp written(owner) do
    [kind: "memory", subject_id: subject(owner), limit: 10_000]
    |> Audit.list()
    |> Enum.filter(&(&1.action == "memory.put"))
    |> Enum.flat_map(fn event ->
      case event.detail do
        %{"version" => %{"to" => version}} = detail when is_integer(version) ->
          [{version, Map.take(detail, ["session", "agent", "rolled_back_to"])}]

        _other ->
          []
      end
    end)
    |> Map.new()
  end

  # -- what reaches a session -------------------------------------------------

  @doc """
  The documents a session on a pod reads: the organisation's, its team's, then its worker
  profile's chain, the profile it extends before its own, as the profile's rules and
  bundle are composed from the chain, then its owner's own; each that has text. A session
  of no team reads no team's, and one whose owner the plane has no person for, nobody's.
  """
  @spec for_session(Team.t() | nil, String.t() | nil, User.t() | nil) :: [Shape.document()]
  def for_session(team, profile, owner \\ nil) do
    ([{:organisation, nil}, {team, team && team.name}] ++ Enum.map(chain(profile), &{&1, &1}))
    |> Enum.reject(fn {owner, _name} -> is_nil(owner) end)
    |> Enum.flat_map(fn {owner, name} -> reaching(current(owner), name) end)
    |> Kernel.++(own_reaching(owner))
  end

  @doc """
  The profiles whose documents a session on `profile` reads, the one that extends nothing
  first and `profile` last. A chain that cannot be read (a profile in it gone) is the
  profile alone, as its rules are then.
  """
  @spec chain(String.t() | nil) :: [String.t()]
  def chain(nil), do: []

  def chain(profile) when is_binary(profile) do
    case Extends.chain(profile) do
      {:ok, chain} -> Enum.map(chain, &elem(&1, 0))
      {:error, _reason} -> [profile]
    end
  end

  @doc """
  The documents a profile has from the profiles it extends, nearest last: each with the
  version in force, for the console to show above the profile's own.
  """
  @spec inherited(String.t()) :: [{String.t(), Document.t()}]
  def inherited(profile) do
    profile
    |> chain()
    |> Enum.reject(&(&1 == profile))
    |> Enum.flat_map(fn parent ->
      case current(parent) do
        %Document{text: text} = document when text != "" -> [{parent, document}]
        _none -> []
      end
    end)
  end

  @doc """
  Tell the pods holding a running session a document reaches that it was saved again, each
  session with every document it now reads (`session.memory`), so the session reads the
  new version from its next turn rather than its next activation. A notification, as a
  bundle's is: a pod that does not hear it has the documents with the session's next
  activation anyway, and a save never waits on the slowest pod. Answers how many sessions
  were told.

  The organisation's reaches every running session of a team, a team's that team's, a
  profile's the sessions of that profile and of every profile that extends it, and a
  person's own the sessions they own.
  """
  @spec announce(owner()) :: non_neg_integer()
  def announce(owner) do
    sessions = Repo.all(reached(owner))
    teams = sessions |> Enum.map(& &1.team_id) |> Enum.uniq() |> Map.new(&{&1, &1 && Identity.fetch_team(&1)})
    workers = sessions |> Enum.map(& &1.worker_id) |> Enum.uniq() |> Map.new(&{&1, Fleet.get_worker(&1)})
    owners = sessions |> Enum.map(& &1.owner_subject) |> Enum.uniq() |> Map.new(&{&1, Identity.get_user(&1)})

    Enum.count(sessions, fn session ->
      case workers[session.worker_id] do
        nil ->
          false

        worker ->
          Router.notify(worker, "session.memory", %{
            "session_id" => session.id,
            "epoch" => session.epoch,
            "memory" => for_session(teams[session.team_id], session.profile, owners[session.owner_subject])
          })

          true
      end
    end)
  end

  defp reached(owner) do
    running =
      from(s in Sessions.Session,
        where: s.state == "active" and not is_nil(s.worker_id) and s.kind == "team",
        order_by: s.id
      )

    case owner do
      :organisation -> running
      %Team{id: id} -> where(running, [s], s.team_id == ^id)
      %User{subject: subject} -> where(running, [s], s.owner_subject == ^subject)
      profile when is_binary(profile) -> where(running, [s], s.profile in ^[profile | Extends.descendants(profile)])
    end
  end

  @doc """
  Take a profile's document away with the profile: every version, so a profile made again
  under the name starts with none. What the audit has of it stays, as the record of each
  save does: its version, size and hash, who and when, never the text. Answers how many
  versions went.
  """
  @spec forget(String.t()) :: non_neg_integer()
  def forget(profile) when is_binary(profile) do
    {count, _} = Repo.delete_all(from(d in Document, where: d.scope == "profile" and d.owner == ^profile))
    count
  end

  @doc """
  The documents a person's own machine reads, for every session on it: the organisation's,
  then each of their teams', by name, then their own. Not a profile's: a laptop's session
  runs on none.
  """
  @spec for_person(User.t()) :: [Shape.document()]
  def for_person(%User{} = user) do
    teams = user |> Identity.teams_for() |> Enum.sort_by(& &1.name)

    reaching(current(:organisation), nil) ++
      Enum.flat_map(teams, &reaching(current(&1), &1.name)) ++ own_reaching(user)
  end

  # A person's own, for a person the plane keeps a row for; a service principal has none.
  defp own_reaching(%User{id: id} = user) when is_binary(id), do: reaching(current(user), nil)
  defp own_reaching(_nobody), do: []

  # -- what each running session read -----------------------------------------

  @doc """
  A pod's session's turn is beginning, and it holds `reported`, the documents' stamps
  (`Troupe.Protocol.Memory.stamp/1`). Kept as what the turn reads, and answered with the
  documents in force: `{:current, documents}`
  where it holds them already, `{:behind, documents}` where it does not, for the pod to give
  the session before the turn starts. So a `session.memory` lost between two turns leaves no
  turn on the versions before it, and what is kept is what the turn reads: the versions in
  force, where it was behind.
  """
  @spec turn(Sessions.Session.t(), term()) :: {:current | :behind, [Shape.document()]}
  def turn(%Sessions.Session{} = session, reported) do
    in_force = session_documents(session)
    stamps = Enum.map(in_force, &Shape.stamp/1)
    now = DateTime.utc_now()
    standing = if same?(stamps(reported), stamps), do: :current, else: :behind

    :ok =
      keep(%{
        session_id: session.id,
        owner_id: session.owner_id,
        owner_subject: session.owner_subject,
        where: "pod",
        documents: stamps,
        turn_at: now,
        seen_at: now
      })

    {standing, in_force}
  end

  @doc """
  What a person's machine says of the sessions running on it, with its poll of `me.memory`:
  each one's `session_id`, the stamps its last turn read (`documents`) and when that turn
  began (`turn_at`). At most #{@machine_sessions} a poll, and only for the person who sent
  them: a row of a pod's session, or of another person's, is left as it is. Rows nothing has
  said anything of for a week go.
  """
  @spec machine(User.t(), term()) :: :ok
  def machine(%User{id: user_id} = user, sessions) when is_binary(user_id) and is_list(sessions) do
    now = DateTime.utc_now()

    sessions
    |> Enum.flat_map(&machine_row(&1, user, now))
    |> Enum.take(@machine_sessions)
    |> Enum.each(fn row ->
      Repo.insert(Read.changeset(%Read{}, row),
        on_conflict:
          from(r in Read,
            where: r.where == "machine" and r.owner_id == ^user_id,
            update: [set: [documents: ^row.documents, turn_at: ^row.turn_at, seen_at: ^now]]
          ),
        conflict_target: :session_id
      )
    end)

    _pruned = Repo.delete_all(from(r in Read, where: r.seen_at < ^DateTime.add(now, -7, :day)))
    :ok
  end

  def machine(_user, _sessions), do: :ok

  defp machine_row(%{"session_id" => id} = reported, user, now)
       when is_binary(id) and byte_size(id) in 1..128 do
    [
      %{
        session_id: id,
        owner_id: user.id,
        owner_subject: user.subject,
        where: "machine",
        documents: stamps(reported["documents"]),
        turn_at: time(reported["turn_at"]) || now,
        seen_at: now
      }
    ]
  end

  defp machine_row(_other, _user, _now), do: []

  @doc "What the plane keeps of one session's last turn, or `nil` for none."
  @spec read_of(String.t()) :: Read.t() | nil
  def read_of(session_id) when is_binary(session_id), do: Repo.get(Read, session_id)

  @doc """
  The running sessions one document reaches that said what they read: each with the version
  of it their last turn ran under (`0` for none) and whether that is behind the version in
  force; and how many are behind. A pod's session is running while the plane has it active
  on a pod, a machine's while its daemon named it at a poll in the last fifteen minutes,
  three polls. A session that has had no turn yet is not listed: it reads the version in
  force at its first.
  """
  @spec readers(owner()) :: %{version: non_neg_integer(), behind: non_neg_integer(), sessions: [map()]}
  def readers(owner) do
    current = current(owner)
    in_force = if current && current.text != "", do: current.version
    key = {elem(key(owner), 0), name_of(owner)}

    sessions =
      (pod_readers(owner) ++ machine_readers(owner))
      |> Enum.map(fn row ->
        read = Enum.find(row.documents, &({&1["scope"], &1["name"]} == key))
        version = read && read["version"]

        row
        |> Map.delete(:documents)
        |> Map.merge(%{version: version || 0, behind: version != in_force})
      end)
      |> Enum.sort_by(& &1.session_id)

    %{version: number(current), behind: Enum.count(sessions, & &1.behind), sessions: sessions}
  end

  defp pod_readers(%User{}), do: []

  defp pod_readers(owner) do
    from([s] in reached(owner),
      join: r in Read,
      on: r.session_id == s.id,
      left_join: t in Team,
      on: t.id == s.team_id,
      select: %{
        session_id: s.id,
        where: "pod",
        owner: s.owner_subject,
        profile: s.profile,
        team: t.name,
        documents: r.documents,
        turn_at: r.turn_at
      }
    )
    |> Repo.all()
  end

  defp machine_readers(owner) do
    since = DateTime.add(DateTime.utc_now(), -@running_seconds, :second)
    machines = from(r in Read, where: r.where == "machine" and r.seen_at >= ^since)

    machines =
      case owner do
        :organisation -> machines
        %Team{} = team -> where(machines, [r], r.owner_id in ^Enum.map(Identity.members_of_team(team), & &1.id))
        _profile_or_person -> where(machines, [_r], false)
      end

    machines
    |> select([r], %{
      session_id: r.session_id,
      where: "machine",
      owner: r.owner_subject,
      profile: nil,
      team: nil,
      documents: r.documents,
      turn_at: r.turn_at
    })
    |> Repo.all()
  end

  @doc """
  Whether each of these sessions' last turn ran under the memory in force for it now:
  `"current"` or `"behind"`, by id, and absent for one not running on a pod or that has had
  no turn. What the session listing marks.
  """
  @spec standing([Sessions.Session.t()]) :: %{String.t() => String.t()}
  def standing(sessions) do
    running = Enum.filter(sessions, &(&1.state == "active" and not is_nil(&1.worker_id)))
    ids = Enum.map(running, & &1.id)
    reads = Map.new(Repo.all(from(r in Read, where: r.where == "pod" and r.session_id in ^ids)), &{&1.session_id, &1})

    {standings, _cache} =
      running
      |> Enum.filter(&Map.has_key?(reads, &1.id))
      |> Enum.reduce({%{}, %{}}, fn session, {acc, cache} ->
        # The documents in force are the same for every session of one team, profile and owner.
        whose = {session.team_id, session.profile, session.owner_subject}
        cache = Map.put_new_lazy(cache, whose, fn -> session |> session_documents() |> Enum.map(&Shape.stamp/1) end)
        word = if same?(stamps(reads[session.id].documents), cache[whose]), do: "current", else: "behind"
        {Map.put(acc, session.id, word), cache}
      end)

    standings
  end

  @doc """
  Tell one running session a document reaches what it reads now, again: on a pod,
  `session.memory` as a save sends it, which the session reads at its next turn. A machine's
  session is not told: its daemon asks at its next poll, and the answer says so.
  `{:error, :not_found}` for a session the document does not reach or that is not running.
  """
  @spec nudge(owner(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def nudge(owner, session_id) do
    case Enum.find(readers(owner).sessions, &(&1.session_id == session_id)) do
      %{where: "pod"} -> nudge_pod(Sessions.get(session_id))
      %{where: "machine"} -> {:ok, %{session_id: session_id, where: "machine", told: false, reason: @machine_nudge}}
      nil -> {:error, :not_found}
    end
  end

  defp nudge_pod(%Sessions.Session{worker_id: worker_id} = session) when not is_nil(worker_id) do
    case Fleet.get_worker(worker_id) do
      nil ->
        {:error, :not_found}

      worker ->
        Router.notify(worker, "session.memory", %{
          "session_id" => session.id,
          "epoch" => session.epoch,
          "memory" => session_documents(session)
        })

        {:ok, %{session_id: session.id, where: "pod", told: true}}
    end
  end

  defp nudge_pod(_gone), do: {:error, :not_found}

  defp session_documents(%Sessions.Session{} = session) do
    team = session.team_id && Identity.fetch_team(session.team_id)
    for_session(team, session.profile, Identity.get_user(session.owner_subject))
  end

  defp keep(row) do
    {:ok, _} =
      Repo.insert(Read.changeset(%Read{}, row),
        on_conflict: {:replace, [:owner_id, :owner_subject, :where, :documents, :turn_at, :seen_at]},
        conflict_target: :session_id
      )

    :ok
  end

  # Stamps as they were sent: documents, each with its scope, name, version and hash.
  defp stamps(documents) when is_list(documents) do
    documents
    |> Enum.filter(&(is_map(&1) and is_binary(&1["scope"]) and is_integer(&1["version"])))
    |> Enum.take(32)
    |> Enum.map(&Shape.stamp/1)
  end

  defp stamps(_other), do: []

  defp same?(read, in_force), do: MapSet.new(read, &identity/1) == MapSet.new(in_force, &identity/1)

  defp identity(stamp), do: {stamp["scope"], stamp["name"], stamp["version"], stamp["hash"]}

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _other -> nil
    end
  end

  defp time(_other), do: nil

  defp name_of(:organisation), do: nil
  defp name_of(%Team{name: name}), do: name
  defp name_of(%User{}), do: nil
  defp name_of(profile) when is_binary(profile), do: profile

  # -- a person's own ---------------------------------------------------------

  @doc """
  A person's own document as they edit it: the version in force (`0` for none), its text,
  its size and the limit, and who saved it and when. Asked only for the person themselves:
  no administrator's method reads it.
  """
  @spec own(User.t()) :: map()
  def own(%User{} = user) do
    current = if is_binary(user.id), do: current(user)
    text = (current && current.text) || ""

    %{
      "version" => number(current),
      "text" => text,
      "hash" => current && current.hash,
      "bytes" => byte_size(text),
      "limit" => Shape.max_bytes(),
      "changed_by" => current && current.changed_by,
      "changed_at" => current && DateTime.to_iso8601(current.inserted_at)
    }
  end

  @doc """
  Save a person's own document as they wrote it, over `base` (the version they edited, `0`
  for none), as `put/4` saves any. Audited as `memory.put` on `user/<subject>`, with the
  version, size and hash and never the text, as every level's save is; the sessions they run
  read it from their next turn. `opts[:session]` names the session an agent of theirs wrote
  it from and `opts[:agent]` the agent, which the audit row keeps and `blame/2` reads.
  """
  @spec save_own(User.t(), String.t(), non_neg_integer() | nil, keyword()) ::
          {:ok, %{document: map() | nil, changes: map()}}
          | {:error, {:conflict, non_neg_integer()} | :no_person | String.t()}
  def save_own(user, text, base, opts \\ [])

  def save_own(%User{id: id} = user, text, base, opts) when is_binary(id) do
    case put(user, text, user.subject, base) do
      {:ok, :unchanged} ->
        current = current(user)
        {:ok, %{document: current && summary(current), changes: %{}}}

      {:ok, %{before: before, now: now}} ->
        changes = Audit.diff(fields(before), fields(now))

        detail =
          for {key, opt} <- [
                {"session", :session},
                {"agent", :agent},
                {"rolled_back_to", :rolled_back_to},
                {"note", :note}
              ],
              opts[opt],
              into: changes,
              do: {key, opts[opt]}

        {:ok, _} = Audit.record(user.subject, "memory.put", subject(user), detail)
        _told = announce(user)
        {:ok, %{document: summary(now), changes: changes}}

      {:error, _reason} = error ->
        error
    end
  end

  def save_own(_user, _text, _base, _opts), do: {:error, :no_person}

  @doc """
  Add one entry to a person's own document, as an agent of theirs does with `remember`:
  under a heading of the day, `## 2026-10-25`, below whatever is there and never in place of
  it. The entry is one line, white space folded, at most 1024 bytes. One that would take the
  document past the limit is refused as `{:full, bytes}`, and nothing is written. Saved as
  `save_own/4` saves, over the version just read, and read again when somebody saved in
  between.
  """
  @spec append_own(User.t(), String.t(), keyword()) ::
          {:ok, %{document: map() | nil, changes: map(), entry: String.t()}}
          | {:error, {:full, non_neg_integer()} | :no_person | String.t()}
  def append_own(user, entry, opts \\ []) do
    with {:ok, entry} <- entry(entry), do: append(user, entry, opts, 3)
  end

  defp append(%User{id: id} = user, entry, opts, attempts) when is_binary(id) do
    current = current(user)
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    text = appended((current && current.text) || "", entry, today)

    with :ok <- room(text),
         {:ok, saved} <- save_own(user, text, number(current), opts) do
      {:ok, Map.put(saved, :entry, entry)}
    else
      {:error, {:conflict, _}} when attempts > 1 -> append(user, entry, opts, attempts - 1)
      error -> error
    end
  end

  defp append(_user, _entry, _opts, _attempts), do: {:error, :no_person}

  defp entry(entry) when is_binary(entry) do
    folded = entry |> String.split() |> Enum.join(" ")

    cond do
      folded == "" -> {:error, "nothing to remember: the entry is empty"}
      not String.valid?(folded) -> {:error, "an entry is UTF-8 text"}
      byte_size(folded) > @entry_bytes -> {:error, "an entry holds at most #{@entry_bytes} bytes; this one is #{byte_size(folded)}"}
      true -> {:ok, folded}
    end
  end

  defp entry(_other), do: {:error, "an entry is text"}

  # Below the last heading where it is the day's, under a new one where it is not.
  defp appended("", entry, day), do: "## #{Date.to_iso8601(day)}\n\n- #{entry}"

  defp appended(text, entry, day) do
    heading = "## #{Date.to_iso8601(day)}"

    last =
      text
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "## "))
      |> List.last()

    if last == heading,
      do: text <> "\n- " <> entry,
      else: text <> "\n\n" <> heading <> "\n\n- " <> entry
  end

  defp room(text) do
    if byte_size(text) > Shape.max_bytes(), do: {:error, {:full, byte_size(text)}}, else: :ok
  end

  defp fields(nil), do: %{version: 0, bytes: 0, hash: nil}
  defp fields(document), do: %{version: document.version, bytes: byte_size(document.text), hash: document.hash}

  defp reaching(nil, _name), do: []
  defp reaching(%Document{text: ""}, _name), do: []
  defp reaching(%Document{} = document, name), do: [json(document, name)]

  @doc "A version as it travels to a session (`Troupe.Protocol.Memory`)."
  @spec json(Document.t(), String.t() | nil) :: Shape.document()
  def json(%Document{} = document, name) do
    %{
      "scope" => document.scope,
      "name" => name,
      "version" => document.version,
      "hash" => document.hash,
      "updated_at" => DateTime.to_iso8601(document.inserted_at),
      "text" => document.text
    }
  end

  @doc "A version as a listing shows it: its number, who saved it and when, and its size."
  @spec summary(Document.t()) :: map()
  def summary(%Document{} = document) do
    %{
      "version" => document.version,
      "hash" => document.hash,
      "bytes" => byte_size(document.text),
      "changed_by" => document.changed_by,
      "changed_at" => DateTime.to_iso8601(document.inserted_at)
    }
  end

  @doc "Where a document is said to be, in the audit and in the console: its subject."
  @spec subject(owner()) :: String.t()
  def subject(:organisation), do: "organisation"
  def subject(%Team{name: name}), do: "team/#{name}"
  def subject(profile) when is_binary(profile), do: "profile/#{profile}"
  def subject(%User{subject: subject}), do: "user/#{subject}"

  @doc "The worker profiles a profile's document may be kept for: those the plane has."
  @spec profile?(String.t()) :: boolean()
  def profile?(name) when is_binary(name), do: not is_nil(Fleet.get_profile(name))
  def profile?(_name), do: false

  defp key(:organisation), do: {"organisation", ""}
  defp key(%Team{id: id}), do: {"team", id}
  defp key(profile) when is_binary(profile), do: {"profile", profile}
  # By the person's id, so a re-key keeps it and their removal finds it.
  defp key(%User{id: id}) when is_binary(id), do: {"user", id}
end
