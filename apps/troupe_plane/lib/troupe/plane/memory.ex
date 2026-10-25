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
  alias Troupe.Plane.Memory.Document
  alias Troupe.Protocol.Memory, as: Shape

  @type scope :: String.t()

  @typedoc "Whose a document is: the organisation's, a team, a profile by name, or a person."
  @type owner :: :organisation | Team.t() | String.t() | User.t()

  # One entry an agent adds to a person's memory: a sentence or two, on one line.
  @entry_bytes 1_024

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
  it from, which the audit row keeps.
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
        detail = if opts[:session], do: Map.put(changes, "session", opts[:session]), else: changes
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
