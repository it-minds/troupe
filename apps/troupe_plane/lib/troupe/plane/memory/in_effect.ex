defmodule Troupe.Plane.Memory.InEffect do
  @moduledoc """
  The memory documents as entries (#55): each `## Topic` section of a document is one entry
  (`Troupe.Protocol.Memory.Entries`), with who wrote it and when, read off the document's
  blame (`Troupe.Plane.Memory.blame/2`), and in how many sessions it was used, read off
  what each session's last turn read (`Troupe.Plane.Memory.Read`). And what is in effect
  for a person in one of their teams: the organisation's, the team's, a worker profile's
  chain where one is named, and their own, as one list of topics, the closest level's entry
  on each with what it replaces.

  The text stays what is kept: nothing here is stored.
  """

  import Ecto.Query

  alias Troupe.Plane.{Identity, Memory, Repo}
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Memory.Read
  alias Troupe.Protocol.Memory.Entries

  # The person's own is the closest level, whatever the length of the profile chain.
  @own_rank 1_000

  @doc """
  A document's entries as it stands at version `upto` (the version in force where `nil`),
  each `topic`, `body`, `heading` (false for General, the text before the first heading),
  and `version`, `by` and `at`, those of its newest line: the version it last changed in and
  who saved that version; an agent's entry adds `session` and `agent`. And `used`: how many
  sessions read a version holding it since (`used/1`).
  """
  @spec entries(Memory.owner(), pos_integer() | nil) :: [map()]
  def entries(owner, upto \\ nil) do
    reads = reads_of(owner)

    owner
    |> Memory.blame(upto)
    |> Entries.split(& &1["text"])
    |> Enum.map(fn {topic, heading?, lines} ->
      body = if heading?, do: tl(lines), else: lines
      newest = lines |> Enum.reject(&(String.trim(&1["text"]) == "")) |> Enum.max_by(& &1["version"], fn -> %{} end)

      %{
        "topic" => topic,
        "body" => body |> Enum.map(& &1["text"]) |> Entries.body_text(),
        "heading" => heading?,
        "version" => newest["version"],
        "by" => newest["by"],
        "at" => newest["at"]
      }
      |> Map.merge(Map.take(newest, ["session", "agent"]))
      |> Map.put("used", used(reads, newest["version"]))
    end)
  end

  @doc """
  How many sessions read a version of a document holding an entry that came in `version`:
  of the sessions the plane keeps a last turn for, those whose turn read this document at
  `version` or later. Approximate, as the plane keeps one row a session, the version its
  last turn read, and a week of a machine's: a session whose turns all came before the
  entry, or that has not spoken for a week, is not counted.
  """
  @spec used([non_neg_integer()], non_neg_integer() | nil) :: non_neg_integer()
  def used(_reads, nil), do: 0
  def used(reads, version), do: Enum.count(reads, &(&1 >= version))

  # The version of this document each session's last turn read, where it read one.
  defp reads_of(owner) do
    {scope, name} = stamp_of(owner)

    owner
    |> rows()
    |> Repo.all()
    |> Enum.flat_map(fn documents ->
      for %{"scope" => ^scope, "version" => version} = stamp <- documents,
          stamp["name"] == name,
          is_integer(version),
          do: version
    end)
  end

  defp rows(%User{id: id}), do: from(r in Read, where: r.owner_id == ^id, select: r.documents)
  defp rows(_owner), do: from(r in Read, select: r.documents)

  defp stamp_of(:organisation), do: {"organisation", nil}
  defp stamp_of(%Team{name: name}), do: {"team", name}
  defp stamp_of(%User{}), do: {"user", nil}
  defp stamp_of(profile) when is_binary(profile), do: {"profile", profile}

  @doc """
  What a new session of `user`'s in `team` reads, as one list: the levels (the
  organisation's, the team's, `profile`'s chain where one is named, the one that extends
  nothing first, and the person's own, lowest first) and every entry in effect among them,
  each with its `level` (`scope` and `name`) and `replaces`, the lower levels' entries on
  its topic it replaces, closest first, each with its `level` and `body`.
  """
  @spec in_effect(User.t(), Team.t() | nil, String.t() | nil) :: map()
  def in_effect(%User{} = user, team, profile) do
    levels =
      ([{:organisation, 0}] ++
         if(team, do: [{team, 1}], else: []) ++
         (profile |> Memory.chain() |> Enum.with_index(2)) ++
         if(is_binary(user.id), do: [{user, @own_rank}], else: []))
      |> Enum.map(fn {owner, rank} ->
        current = Memory.current(owner)
        entries = if current && current.text != "", do: entries(owner), else: []
        %{level: level(owner), rank: rank, entries: entries, version: (current && current.version) || 0}
      end)

    %{
      "team" => team && team.name,
      "profile" => profile,
      "levels" => Enum.map(levels, &Map.merge(&1.level, %{"version" => &1.version, "entries" => length(&1.entries)})),
      "entries" => levels |> Entries.in_effect() |> Entries.effect_json()
    }
  end

  @doc "A level as an answer names it: its `scope` and its team's or profile's `name`."
  @spec level(Memory.owner()) :: map()
  def level(owner) do
    {scope, name} = stamp_of(owner)
    %{"scope" => scope, "name" => name}
  end

  @doc """
  The team a person's in-effect list is for: the one named, which must be one of theirs, or
  their first by name; `nil` for a person in none.
  """
  @spec team_of(User.t(), String.t() | nil) :: {:ok, Team.t() | nil} | {:error, :not_found}
  def team_of(user, name) do
    teams = user |> Identity.teams_for() |> Enum.sort_by(& &1.name)

    case name do
      nil -> {:ok, List.first(teams)}
      name -> teams |> Enum.find(&(&1.name == name)) |> then(&if(&1, do: {:ok, &1}, else: {:error, :not_found}))
    end
  end
end
