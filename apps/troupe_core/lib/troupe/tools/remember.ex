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

  The arguments from before facts, `section` and `text`, keep working for one release,
  so an older prompt or a bundle's agent still writes something sensible: a note is a
  `note` fact, and a section is a fact of its kind per bullet, replacing what the section
  wrote last time.
  """

  @behaviour Troupe.Tool

  alias Troupe.Memory.Facts
  alias Troupe.Session.Log
  alias Troupe.{Tool, Workspace}

  @kinds ~w(command convention overview layout negative note)
  @sections %{
    "overview" => "overview",
    "layout" => "layout",
    "commands" => "command",
    "conventions" => "convention",
    "note" => "note"
  }
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

  # `section` and `text`, the older form, are accepted and not offered (Decision 839).
  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => @kinds},
        "claim" => %{"type" => "string"},
        "anchors" => %{"type" => "array", "items" => %{"type" => "string"}},
        "scope" => %{"type" => "string", "description" => "A glob; none is the whole repository."},
        "replaces" => %{"type" => "string"}
      }
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(%{"section" => _} = args, ctx) when not is_map_key(args, "claim"),
    do: section(args, ctx)

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
        {:ok, fact}
    end
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

  ## The older form

  defp section(args, ctx) do
    with {:ok, section} <- Tool.fetch_string(args, "section"),
         {:ok, text} <- Tool.fetch_string(args, "text"),
         {:ok, kind} <- section_kind(section),
         :ok <-
           if(String.trim(text) == "",
             do: {:error, "nothing to remember: text is empty"},
             else: :ok
           ),
         :ok <- allowed(ctx, kind) do
      write_section(ctx, kind, text)
    end
  end

  defp section_kind(section) do
    case Map.fetch(@sections, section) do
      {:ok, kind} ->
        {:ok, kind}

      :error ->
        {:error, "unknown section #{section}; one of #{Enum.join(Map.keys(@sections), ", ")}"}
    end
  end

  defp write_section(ctx, "note", text), do: put_old(ctx, "note", [squish(text)])

  # A section was replaced wholesale: what this writer wrote of the kind the old way
  # before, unanchored, goes, and each bullet is a fact of its own.
  defp write_section(ctx, kind, text) do
    by = by(ctx)

    for %{"kind" => ^kind, "anchors" => [], "evidence" => %{"by" => ^by}} = fact <-
          Facts.list(root(ctx)),
        do: Facts.delete(root(ctx), fact["id"])

    put_old(ctx, kind, bullets(text))
  end

  defp put_old(ctx, kind, claims) do
    events = events(ctx)

    claims
    |> Enum.reduce_while({:ok, []}, fn claim, {:ok, ids} ->
      attrs = %{kind: kind, claim: claim, anchors: [], scope: nil}

      case put(ctx, attrs, evidence(ctx, events, kind, claim)) do
        {:ok, fact} -> {:cont, {:ok, [fact["id"] | ids]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, old_answer(kind, Enum.reverse(ids))}
      error -> error
    end
  end

  defp old_answer(kind, ids) do
    "remembered #{length(ids)} #{kind} fact(s), unanchored (#{Enum.join(ids, ", ")}). " <>
      "section and text are the older form: kind, claim and anchors make a fact that says " <>
      "when it may no longer be true"
  end

  # A bulleted section's items, a continuation line kept with its bullet; text with no
  # bullets is one claim.
  defp bullets(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^\s*(?:[-*+]|\d+[.)])\s+(.*)$/, line) do
        [_line, item] -> [item | acc]
        nil -> continue(acc, line)
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&squish/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp continue([], line), do: [line]
  defp continue([last | rest], line), do: [last <> " " <> line | rest]

  defp root(ctx), do: ctx.workspace.root_real

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
