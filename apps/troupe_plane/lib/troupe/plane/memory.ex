defmodule Troupe.Plane.Memory do
  @moduledoc """
  The organisation's memory documents (#55): what the organisation, each team and each
  worker profile wrote for every agent in their scope. Edited in the console
  (`Troupe.Plane.Admin`), every version kept with who saved it, and handed to the sessions
  they reach as instructions from the organisation, read-only to every agent.

  - **On a pod** a session gets its organisation's, its team's and its profile's, with
    every activation (`for_session/2`), so a save reaches a session the next time it wakes.
  - **On a laptop** the daemon of a person signed in asks `me.memory`, signed by the
    plane's key, for the organisation's and every team of theirs (`for_person/1`), and
    keeps the copy as it keeps the organisation's document. A laptop's session belongs to
    no team, so it reads the person's teams'.

  A team's document reaches only that team's sessions and its members' machines.

  A document is text, at most `Troupe.Protocol.Memory.max_bytes/0` bytes. Each save is a
  new version, numbered from 1; an empty one clears the document, which then reaches no
  session, and is a version like any other. A save names the version it replaces, so two
  administrators editing one document at once do not overwrite each other: the second is
  told what the first saved.
  """

  import Ecto.Query

  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.{Fleet, Identity, Repo, Sessions}
  alias Troupe.Plane.Fleet.Extends
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Memory.Document
  alias Troupe.Protocol.Memory, as: Shape

  @type scope :: String.t()

  @typedoc "Whose a document is: the organisation's, a team, or a profile by name."
  @type owner :: :organisation | Team.t() | String.t()

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
  bundle are composed from the chain; each that has text. A session of no team reads no
  team's.
  """
  @spec for_session(Team.t() | nil, String.t() | nil) :: [Shape.document()]
  def for_session(team, profile) do
    ([{:organisation, nil}, {team, team && team.name}] ++ Enum.map(chain(profile), &{&1, &1}))
    |> Enum.reject(fn {owner, _name} -> is_nil(owner) end)
    |> Enum.flat_map(fn {owner, name} -> reaching(current(owner), name) end)
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

  The organisation's reaches every running session of a team, a team's that team's, and a
  profile's the sessions of that profile and of every profile that extends it.
  """
  @spec announce(owner()) :: non_neg_integer()
  def announce(owner) do
    sessions = Repo.all(reached(owner))
    teams = sessions |> Enum.map(& &1.team_id) |> Enum.uniq() |> Map.new(&{&1, &1 && Identity.fetch_team(&1)})
    workers = sessions |> Enum.map(& &1.worker_id) |> Enum.uniq() |> Map.new(&{&1, Fleet.get_worker(&1)})

    Enum.count(sessions, fn session ->
      case workers[session.worker_id] do
        nil ->
          false

        worker ->
          Router.notify(worker, "session.memory", %{
            "session_id" => session.id,
            "epoch" => session.epoch,
            "memory" => for_session(teams[session.team_id], session.profile)
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
  then each of their teams', by name. Not a profile's: a laptop's session runs on none.
  """
  @spec for_person(User.t()) :: [Shape.document()]
  def for_person(%User{} = user) do
    teams = user |> Identity.teams_for() |> Enum.sort_by(& &1.name)

    reaching(current(:organisation), nil) ++
      Enum.flat_map(teams, &reaching(current(&1), &1.name))
  end

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

  @doc "The worker profiles a profile's document may be kept for: those the plane has."
  @spec profile?(String.t()) :: boolean()
  def profile?(name) when is_binary(name), do: not is_nil(Fleet.get_profile(name))
  def profile?(_name), do: false

  defp key(:organisation), do: {"organisation", ""}
  defp key(%Team{id: id}), do: {"team", id}
  defp key(profile) when is_binary(profile), do: {"profile", profile}
end
