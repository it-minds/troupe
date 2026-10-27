defmodule Troupe.Tools.Remember do
  @moduledoc """
  Writes a fact about the repository to its memory, through `Troupe.Memory.Facts`
  (Decision 839): a claim of one kind, anchored on the files it was read from. What makes
  it evidence is Troupe's, never the model's: the hash of each anchor, the session, the
  seq of this call, HEAD, who wrote it, and for a command the session ran, how it exited.

  `:auto` although it writes: what it writes is the repository's memory and nothing else.
  The paths a model names are only read, to hash them, and only inside the workspace; and
  asking for approval on every learned fact would mean memory never gets written
  (Decision 649).

  `replaces` corrects a fact (a re-anchored or corrected claim takes its place) or, with no
  claim, drops it: how the librarian re-verifies a fact whose anchor moved. A person's
  fact is theirs, and only `memory.forget` removes it.

  The arguments from before facts, `section` and `text`, kept working for one release
  (Decision 839) and are refused now (Decision 854): an older prompt or a bundle's agent
  that still calls the old way is told the form that replaced them, and writes nothing.

  `level: "me"` writes to the person's own memory on the plane instead (#55): the one level
  above the repository an agent may write, and only by adding one entry, which the plane
  puts at the end of its `topic`'s `## <topic>` section, `Notes` where none is named, below
  what is there (`Troupe.UserMemory`). The model names no
  path and no document there either, only the sentence; the organisation's, a team's and a
  profile's memory have no level here at all. Signed out, or with no plane, it is refused
  with a sentence that offers the repository's memory.
  """

  @behaviour Troupe.Tool

  alias Troupe.Memory.Facts
  alias Troupe.Session.Log
  alias Troupe.{Tool, UserMemory, Workspace}

  @kinds ~w(command convention overview layout negative note)
  @levels ~w(repository me)
  @old_form "remember no longer takes section and text: it writes one fact, with kind " <>
              "(command, convention, overview, layout, negative or note), claim (one or two " <>
              "sentences) and anchors (the files you read it in), as " <>
              ~s({"kind": "command", "claim": "`mix test` runs the tests", ) <>
              ~s("anchors": ["mix.exs"]}; nothing was written)
  # The tools whose call shows the agent a file's contents, or puts them there.
  @readers ~w(read_file edit_file write_file)

  @impl Troupe.Tool
  def name, do: "remember"

  @impl Troupe.Tool
  def description do
    """
    Record a fact about this repository so later agents start knowing it. Only what stays true beyond your task and what you verified, and not what `recall` already has.

    `kind`: `command` (build, test, format or lint, exactly as written down), `convention` (a rule a newcomer would break), `overview`, `layout`, `negative` (what does not work here, and why) or `note`. `claim`: one or two sentences.

    `anchors`: the files you read it in, from the workspace (the manifest for a command). Troupe records what they hold; once one changes, the fact shows as "may no longer be true". A fact with no anchor ages out.

    `replaces`: the id of a fact this one corrects or re-anchors; alone, it drops that fact.
    """
    |> String.trim()
  end

  # Said only where an entry has somewhere to go (`Troupe.UserMemory`): a session with no
  # plane is not offered a level it cannot use, and its tool list stays as it was.
  @impl Troupe.Tool
  def describe(_ctx) do
    if UserMemory.reachable?(),
      do:
        description() <>
          "\n\n`level`: `repository` (the default), or `me` for the person's own memory, which every session of theirs reads on every machine: how they like to work, not facts about this code. With `me`, give only `claim` and a `topic` (a short heading such as `Tone`; `Notes` if none); it is added as one entry under it.",
      else: description()
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => @kinds},
        "claim" => %{"type" => "string"},
        "anchors" => %{"type" => "array", "items" => %{"type" => "string"}},
        "scope" => %{"type" => "string", "description" => "A glob; none is the whole repository."},
        "replaces" => %{"type" => "string"},
        "level" => %{"enum" => @levels},
        "topic" => %{"type" => "string"}
      }
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  # The form before facts, refused with the one that replaced it.
  @impl Troupe.Tool
  def run(args, _ctx)
      when (is_map_key(args, "section") or is_map_key(args, "text")) and
             not is_map_key(args, "claim"),
      do: {:error, @old_form}

  def run(%{"level" => "me"} = args, ctx), do: remember_for_person(args, ctx)

  def run(%{"level" => level}, _ctx) when level not in [nil | @levels],
    do: {:error, "level is repository (the default) or me, not #{inspect(level)}; nothing was written"}

  def run(%{"replaces" => id} = args, ctx) when not is_map_key(args, "claim") do
    with {:ok, id} <- Tool.fetch_string(args, "replaces"),
         {:ok, fact} <- replaceable(ctx, id),
         :ok <- Facts.delete(root(ctx), fact["id"]) do
      {:ok, "dropped #{id}: #{fact["claim"]}"}
    else
      {:error, :not_found} -> {:error, "no fact #{id} to drop"}
      other -> other
    end
  end

  def run(args, ctx) do
    with {:ok, kind} <- kind(args),
         {:ok, claim} <- claim(args),
         {:ok, scope} <- scope(args),
         :ok <- allowed(ctx, kind),
         {:ok, anchors} <- anchors(ctx, Map.get(args, "anchors", [])),
         {:ok, replaced} <- replaced(ctx, Map.get(args, "replaces")),
         events = events(ctx),
         attrs = %{kind: kind, claim: claim, anchors: anchors, scope: scope},
         {:ok, fact} <- put(ctx, attrs, evidence(ctx, events, kind, claim)) do
      _ = drop(ctx, replaced, fact)
      {:ok, answer(fact, replaced, unread(anchors, ctx, events))}
    end
  end

  # The fact a new one replaces goes once the new one is written, not before; the same
  # claim written again is the same fact, re-anchored (Decision 838), and stays.
  defp drop(_ctx, nil, _written), do: :ok
  defp drop(_ctx, %{"id" => id}, %{"id" => id}), do: :ok
  defp drop(ctx, replaced, _written), do: Facts.delete(root(ctx), replaced["id"])

  defp put(ctx, attrs, evidence) do
    case Facts.put(root(ctx), attrs, evidence) do
      {:ok, fact} -> {:ok, fact}
      {:error, reason} -> {:error, "not remembered: #{reason_text(reason)}"}
    end
  end

  ## The person's own memory

  defp remember_for_person(args, ctx) do
    with :ok <- only_claim(args),
         :ok <- not_the_librarian(ctx),
         {:ok, claim} <- claim(args),
         {:ok, topic} <- topic(args) do
      case UserMemory.append(claim, ctx, topic) do
        {:ok, saved} ->
          {:ok,
           "remembered in the person's own memory on the plane, version #{saved["version"]}, " <>
             "under #{saved["topic"] || topic || "Notes"}: \"#{saved["entry"] || claim}\". " <>
             "Every session of theirs reads it from its next turn"}

        {:error, :signed_out} ->
          {:error,
           "not remembered: this session's person is not signed in to a Troupe plane here, so " <>
             "there is no memory of theirs to add to. Remember it for this repository instead " <>
             "(level repository, the default), or ask them to sign in"}

        {:error, reason} ->
          {:error, "not remembered in the person's own memory: #{reason_text(reason)}"}
      end
    end
  end

  # The `## <topic>` section of theirs the entry goes under; none is the plane's `Notes`.
  defp topic(args) do
    case Map.get(args, "topic") do
      nil -> {:ok, nil}
      topic when is_binary(topic) -> {:ok, if(String.trim(topic) == "", do: nil, else: String.trim(topic))}
      _other -> {:error, "topic is the heading the entry goes under, as text; nothing was written"}
    end
  end

  defp only_claim(args) do
    case Enum.filter(~w(anchors scope replaces), &Map.has_key?(args, &1)) do
      [] -> :ok
      named -> {:error, "#{Enum.join(named, " and ")} are for the repository's facts; with level me give only claim"}
    end
  end

  # The librarian surveys repositories; what it learns is theirs, never a person's.
  defp not_the_librarian(ctx) do
    if by(ctx) == "librarian",
      do: {:error, "the librarian writes only the repository's facts, never a person's memory"},
      else: :ok
  end

  ## The fact

  defp kind(args) do
    case Map.get(args, "kind") do
      kind when kind in @kinds -> {:ok, kind}
      nil -> {:error, "a fact needs a kind: one of #{Enum.join(@kinds, ", ")}"}
      other -> {:error, "unknown kind #{inspect(other)}; one of #{Enum.join(@kinds, ", ")}"}
    end
  end

  defp claim(args) do
    case Map.get(args, "claim") do
      claim when is_binary(claim) ->
        if String.trim(claim) == "",
          do: {:error, "nothing to remember: the claim is empty"},
          else: {:ok, String.trim(claim)}

      _ ->
        {:error, "nothing to remember: a fact needs a claim"}
    end
  end

  defp scope(args) do
    case Map.get(args, "scope") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      scope when is_binary(scope) -> {:ok, scope}
      other -> {:error, "scope must be a glob, got #{inspect(other)}"}
    end
  end

  # A note is an agent's, from real work: the librarian surveys, and what it learns is a
  # command, a convention, an overview or a layout.
  defp allowed(ctx, "note") do
    if by(ctx) == "librarian",
      do: {:error, "the librarian writes no notes: a note is what an agent learned working here"},
      else: :ok
  end

  defp allowed(_ctx, _kind), do: :ok

  # Each anchor a file inside the workspace, as it really is: a path out of it, a link out
  # of it, or something that is not a file is refused by name. The hash is the store's to
  # take, of what the file holds as this call runs.
  defp anchors(_ctx, paths) when not is_list(paths),
    do: {:error, "anchors must be a list of paths"}

  defp anchors(ctx, paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case anchor(ctx, path) do
        {:ok, relative} -> {:cont, {:ok, [relative | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, relative} -> {:ok, relative |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp anchor(ctx, path) when is_binary(path) do
    with {:ok, real} <- Workspace.resolve(ctx.workspace, path, :read),
         true <- Workspace.inside?(ctx.workspace, real),
         true <- File.regular?(real) do
      {:ok, ctx.workspace |> Workspace.relative(real) |> String.replace("\\", "/")}
    else
      {:error, {:outside_workspace, _}} -> {:error, "#{path} is outside the workspace: no anchor"}
      _ -> {:error, "#{path} is not a file in the workspace: no anchor"}
    end
  end

  defp anchor(_ctx, path), do: {:error, "an anchor is a path, got #{inspect(path)}"}

  defp replaced(_ctx, nil), do: {:ok, nil}
  defp replaced(ctx, id) when is_binary(id), do: replaceable(ctx, id)
  defp replaced(_ctx, other), do: {:error, "replaces is a fact's id, got #{inspect(other)}"}

  defp replaceable(ctx, id) do
    case Enum.find(Facts.list(root(ctx)), &(&1["id"] == id)) do
      nil ->
        {:error, "no fact #{id}: recall lists the facts there are"}

      %{"evidence" => %{"by" => "person"}} ->
        {:error, "#{id} is a person's fact: only they forget or change it"}

      fact ->
        may_replace(by(ctx), fact)
    end
  end

  # The librarian re-verifies any fact but a person's; another agent changes only a fact it
  # wrote itself, or one that may no longer be true.
  defp may_replace("librarian", fact), do: {:ok, fact}

  defp may_replace(by, fact) do
    if get_in(fact, ["evidence", "by"]) == by or fact["status"] in ~w(moved missing),
      do: {:ok, fact},
      else:
        {:error,
         "#{fact["id"]} is #{get_in(fact, ["evidence", "by"]) || "another writer"}'s and " <>
           "still current: an agent changes only its own facts, or one that may no longer be true"}
  end

  ## Evidence, from the session's own log

  defp evidence(ctx, events, kind, claim) do
    %{session: ctx.session_id, seq: seq(ctx, events), by: by(ctx)}
    |> put_exit_status(if kind == "command", do: exit_status(events, claim))
  end

  defp put_exit_status(evidence, nil), do: evidence
  defp put_exit_status(evidence, status), do: Map.put(evidence, :exit_status, status)

  defp by(%{definition: %{name: "librarian"}}), do: "librarian"
  defp by(%{definition: %{name: name}}) when is_binary(name), do: "agent:" <> name
  defp by(%{agent_path: path}), do: "agent:" <> List.last(path)

  # The seq of the event that started this call.
  defp seq(ctx, events) do
    Enum.find_value(events, fn
      %{type: "tool_call_started", seq: seq, data: %{"call_id" => id}} when id == ctx.call_id ->
        seq

      _ ->
        nil
    end)
  end

  # How the session's latest run of a command the claim names exited: a command is named
  # when it is the claim, or one of its code spans, word for word. A run its timeout ended
  # has no exit status, and a command the session never ran has none to give.
  defp exit_status(events, claim) do
    named = MapSet.new([squish(claim) | spans(claim)])

    commands =
      for %{type: "tool_call_started", data: %{"name" => "shell", "call_id" => id} = data} <-
            events,
          command = get_in(data, ["args", "command"]),
          is_binary(command) and MapSet.member?(named, squish(command)),
          into: %{},
          do: {id, true}

    events
    |> Enum.filter(fn
      %{type: "tool_call_completed", data: %{"call_id" => id}} -> Map.has_key?(commands, id)
      _ -> false
    end)
    |> List.last()
    |> case do
      %{data: %{"exit_status" => status}} when is_integer(status) -> status
      _ -> nil
    end
  end

  defp spans(claim),
    do: ~r/`([^`]+)`/ |> Regex.scan(claim, capture: :all_but_first) |> Enum.map(&squish(hd(&1)))

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  # The anchors no call of this session showed it, in the order given.
  defp unread(anchors, ctx, events) do
    seen =
      for %{type: "tool_call_started", data: %{"name" => name, "args" => %{"path" => path}}} <-
            events,
          name in @readers,
          is_binary(path),
          {:ok, relative} <- [anchor(ctx, path)],
          into: MapSet.new(),
          do: relative

    Enum.reject(anchors, &MapSet.member?(seen, &1))
  end

  # The session's log; a call with no session behind it (a test's) has none.
  defp events(ctx) do
    Log.replay(ctx.session_id)
  catch
    :exit, _ -> []
  end

  defp answer(fact, replaced, unread) do
    anchored =
      case fact["anchors"] do
        [] -> "unanchored: it ages out"
        anchors -> "anchored on " <> Enum.map_join(anchors, ", ", & &1["path"])
      end

    [
      "remembered #{fact["kind"]} fact #{fact["id"]} (#{anchored})",
      replaced && replacing(replaced, fact),
      unread != [] &&
        ". Note: you did not read #{Enum.join(unread, ", ")} in this session; it is anchored as it is now"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp replacing(%{"id" => id}, %{"id" => id}), do: "; the same claim, re-anchored"
  defp replacing(replaced, _fact), do: "; replaces #{replaced["id"]}"

  defp root(ctx), do: ctx.workspace.root_real

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
