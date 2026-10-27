defmodule Troupe.Client.OwnMemory do
  @moduledoc """
  The person's own memory on the plane (root #55's user level), for the terminal's
  `/memory` screen: the calls `troupe memory` makes, through this machine's daemon and its
  sign-in (`me.memory`, `me.memory.put`, `me.memory.status`), so the screen and the command
  line read and save the same document the same way.

  A save names the version it was edited from; one made elsewhere since is a `conflict`,
  answered with the version in force, never an overwrite. Rolling back is saving an old
  version's text over the one in force, a version of its own.
  """

  alias Troupe.CLI.Memory
  alias Troupe.Client.Artifacts
  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol
  alias Troupe.Protocol.Memory.Entries

  @doc """
  The document as the plane has it now: `version` (`0` for none), `text`, `bytes`, `limit`,
  who saved it and `plane_url`, and the levels above it (`documents`); `blame: true` adds `lines`.
  """
  @spec own(keyword()) :: {:ok, map()} | {:error, String.t()}
  def own(opts \\ []) do
    params =
      %{}
      |> then(&if(opts[:blame], do: Map.put(&1, "blame", true), else: &1))

    case Link.call("me.memory", params) do
      {:ok, own} -> {:ok, own}
      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc """
  The levels the person reads, lowest first: the organisation's, each of their teams' by name
  (a team with no document among them, as the daemon answers it), and their own (`user`),
  each with its entries as the plane answered them, one per `## Topic`, with who last changed
  it and when. `documents` is `me.memory`'s, the person's own among them (or the copy's).
  """
  @spec levels([map()]) :: [map()]
  def levels(documents) do
    docs = List.wrap(documents)
    org = Enum.find(docs, &(&1["scope"] == "organisation"))
    teams = docs |> Enum.filter(&(&1["scope"] in ["team", "profile"])) |> Enum.sort_by(& &1["name"])
    own = Enum.find(docs, &(&1["scope"] == "user"))

    [level(org || %{"scope" => "organisation"}, 0)] ++
      Enum.map(teams, &level(&1, 1)) ++ [level(own || %{"scope" => "user"}, 2)]
  end

  defp level(doc, rank) do
    %{
      id: level_id(doc),
      scope: doc["scope"],
      name: doc["name"],
      rank: rank,
      version: doc["version"] || 0,
      text: doc["text"] || "",
      changed_by: doc["changed_by"],
      changed_at: doc["changed_at"],
      entries: Enum.map(List.wrap(doc["entries"]), &entry/1)
    }
  end

  defp level_id(%{"scope" => "organisation"}), do: "organisation"
  defp level_id(%{"scope" => "user"}), do: "user"
  defp level_id(%{"scope" => scope, "name" => name}), do: "#{scope}:#{name}"

  # An entry as the page reads it: `topic` nil for the text before the first heading.
  defp entry(e) do
    general? = e["heading"] == false
    topic = if general?, do: nil, else: e["topic"]

    %{
      topic: topic,
      key: if(general?, do: "", else: Entries.key(topic || "")),
      body: e["body"] || "",
      by: e["agent"] || e["by"],
      at: e["at"],
      used: e["used"]
    }
  end

  @doc """
  What a new session in `team` (a level of `levels/1`, by id) starts knowing, as the plane
  works it out (`memory.in_effect`): per topic the closest level's entry, `from` that level,
  with the lower levels' entries it `replaces`.
  """
  @spec in_effect([map()], String.t() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def in_effect(levels, team) do
    params =
      case Enum.find(levels, &(&1.id == team)) do
        %{scope: "team", name: name} -> %{"team" => name}
        _none -> %{}
      end

    case Link.call("memory.in_effect", params) do
      {:ok, %{"entries" => entries}} -> {:ok, effect_rows(entries, levels)}
      {:ok, _answer} -> {:ok, []}
      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc "In-effect entries as an answer carries them, as rows of the page: `entry`, `from`, `replaces`."
  @spec effect_rows([map()], [map()]) :: [map()]
  def effect_rows(entries, levels) do
    Enum.map(List.wrap(entries), fn e ->
      %{
        entry: entry(e),
        from: level_of(e["level"], levels),
        replaces:
          Enum.map(List.wrap(e["replaces"]), fn r ->
            %{entry: entry(Map.put(r, "heading", true)), from: level_of(r["level"], levels)}
          end)
      }
    end)
  end

  defp level_of(%{} = named, levels) do
    id = level_id(named)
    Enum.find(levels, &(&1.id == id)) || level(named, if(named["scope"] == "profile", do: 1, else: 2))
  end

  defp level_of(_none, levels), do: List.last(levels)

  @doc """
  Whether a new entry on `topic` at `level` clashes: `{:here, level}` where that level has one
  already, `{:lower, level}` where it would replace a lower level's, or `nil`. Topics compare
  by their words, case and spacing aside, as the plane compares them.
  """
  @spec clash([map()], map(), String.t()) :: {:here | :lower, map()} | nil
  def clash(levels, level, topic) do
    k = Entries.key(topic)
    has = fn l -> Enum.any?(l.entries, &(&1.key == k)) end

    cond do
      k == "" -> nil
      has.(level) -> {:here, level}
      lower = Enum.find(levels, &(&1.rank < level.rank and has.(&1))) -> {:lower, lower}
      true -> nil
    end
  end

  @doc "A level's entries with the one on `topic` (or on `was`, renamed) written as `body`: in its place, or last."
  @spec put_entry([map()], String.t(), String.t(), String.t() | nil) :: [map()]
  def put_entry(entries, topic, body, was \\ nil) do
    old = Entries.key(was || topic)
    new = %{topic: String.trim(topic), key: Entries.key(topic), body: String.trim(body)}

    if Enum.any?(entries, &(&1.key == old and &1.key != "")),
      do: Enum.map(entries, &if(&1.key == old, do: new, else: &1)),
      else: entries ++ [new]
  end

  @doc "A level's entries without the one on `topic`."
  @spec forget_entry([map()], String.t()) :: [map()]
  def forget_entry(entries, topic), do: Enum.reject(entries, &(&1.key == Entries.key(topic)))

  @doc "Entries as a save sends them, `{topic, body}`, the text before the first heading without a topic."
  @spec wire([map()]) :: [map()]
  def wire(entries) do
    Enum.map(entries, fn
      %{topic: nil, body: body} -> %{"body" => body, "heading" => false}
      %{topic: topic, body: body} -> %{"topic" => topic, "body" => body}
    end)
  end

  @doc "The text the plane writes for these entries, for the screen to show beside another version."
  @spec text_of([map()]) :: String.t()
  def text_of(entries), do: entries |> wire() |> Entries.render()

  @doc """
  Save the person's own as `entries` over `version`, the one they were read at: the plane
  writes them as `## Topic` sections in their order. Answered as `save/2` is.
  """
  @spec save_entries([map()], non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def save_entries(entries, version) do
    params = %{"command_id" => Protocol.command_id(), "entries" => wire(entries), "version" => version}
    saved(Link.call("me.memory.put", params))
  end

  @doc """
  Save `text` over `version`, the one it was edited from: `{:ok, document}` as it now stands
  (`changed: false` where it was the same text), `{:conflict, newest}` where another save
  came first, with the document in force, or the sentence that refused it.
  """
  @spec save(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def save(text, version) do
    params = %{"command_id" => Protocol.command_id(), "text" => text, "version" => version}
    saved(Link.call("me.memory.put", params))
  end

  defp saved(answer) do
    case answer do
      {:ok, %{"user" => now} = saved} ->
        {:ok, Map.put(now, "changed", saved["changed"] != false)}

      {:ok, saved} ->
        {:ok, Map.put(saved, "changed", saved["changed"] != false)}

      {:error, "conflict" <> _} ->
        case own() do
          {:ok, newest} -> {:conflict, newest}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Artifacts.reason(reason)}
    end
  end

  @doc """
  The document's history (`me.memory.history`): every version, newest first, each `{version,
  hash, bytes, changed_by, changed_at}`, and `version`'s text beside `against`'s (`text`,
  `against_text`), the one in force and the one before it where none is named.
  """
  @spec history(keyword()) :: {:ok, map()} | {:error, String.t()}
  def history(opts \\ []) do
    params =
      for {key, value} <- [{"version", opts[:version]}, {"against", opts[:against]}],
          value != nil,
          into: %{},
          do: {key, value}

    case Link.call("me.memory.history", params) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc """
  Roll back to version `to`, over `version`, the one in force as the person saw it: its text
  saved as the next version. Answered as `save/2` is.
  """
  @spec rollback(pos_integer(), non_neg_integer()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def rollback(to, version) do
    params = %{"command_id" => Protocol.command_id(), "to" => to, "version" => version}
    saved(Link.call("me.memory.rollback", params))
  end

  @doc """
  Where this machine's copy stands (`me.memory.status`), with the lines `troupe memory
  --status` prints of it, and each document as the copy holds it (`held`), which is all the
  screen shows where the plane is not asked.
  """
  @spec status() :: {:ok, %{lines: [String.t()], held: [map()], in_effect: [map()]}} | {:error, String.t()}
  def status do
    case Link.call("me.memory.status", %{}) do
      {:ok, status} ->
        {:ok,
         %{
           lines: Memory.status_lines(status),
           held: List.wrap(status["held"]),
           in_effect: List.wrap(status["in_effect"])
         }}

      {:error, reason} -> {:error, Artifacts.reason(reason)}
    end
  end

  @doc "Who wrote a line, as `troupe memory --blame` says it."
  @spec written_by(map()) :: String.t()
  defdelegate written_by(line), to: Memory

  @doc """
  Whether the person has an editor of their own (`VISUAL` or `EDITOR`), which the screen's
  `e` opens; without one it edits in a box of its own, rather than in Notepad or `vi`.
  """
  @spec editor?() :: boolean()
  def editor? do
    is_function(Application.get_env(:troupe, :edit_file), 1) or
      Enum.any?(["VISUAL", "EDITOR"], &((System.get_env(&1) || "") |> String.trim() != ""))
  end
end
