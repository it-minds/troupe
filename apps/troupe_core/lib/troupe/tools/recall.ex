defmodule Troupe.Tools.Recall do
  @moduledoc """
  Looks up the repository's facts (`Troupe.Memory.Facts.recall/2`, Decision 838): the ones
  every prompt does not carry (the overview, the layout, notes, what did not work) and the
  commands and conventions that did not fit, each with its status and where it came from.

  A tool the model calls rather than a retrieval the harness runs before a turn (#248's
  Option 2): the prompt names it and says how many facts it answers, and an agent asks
  when it needs one, so a fact costs no prompt space until then. Read-only and `:auto`,
  like `read_file`: it reads nothing the session could not, and only what was written for
  agents to read.
  """

  @behaviour Troupe.Tool

  alias Troupe.Memory
  alias Troupe.Memory.Facts

  @limit 20

  @impl Troupe.Tool
  def name, do: "recall"

  @impl Troupe.Tool
  def description do
    """
    Look up what earlier agents found out about this repository and kept as facts: its overview and layout, notes, what did not work, and the commands and conventions (the ones in your system prompt, and any that did not fit there).

    Each fact comes with its status: current, unanchored (not tied to a file), or "may no longer be true" when a file it rests on has changed or gone since it was checked. Check one of those before you rely on it.

    Ask by `query` (words in the fact), `kind` (#{Enum.join(Memory.kinds(), ", ")}), or `path` (a file or directory the fact rests on or applies to); with none, every fact. Cheaper than surveying the repository again: ask before you explore.
    """
    |> String.trim()
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Words the fact holds; any of them."},
        "kind" => %{"type" => "string", "enum" => Memory.kinds()},
        "path" => %{
          "type" => "string",
          "description" =>
            "A file or directory, from the workspace, a fact rests on or applies to."
        }
      }
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, query} <- optional(args, "query"),
         {:ok, kind} <- optional(args, "kind"),
         {:ok, path} <- optional(args, "path"),
         :ok <- check_kind(kind) do
      if enabled?(ctx),
        do: {:ok, answer(ctx.workspace.root_real, query, kind, path)},
        else:
          {:ok, "The project brief is off in this workspace (memory: false): no facts are kept."}
    end
  end

  defp answer(workspace, query, kind, path) do
    found = Facts.recall(workspace, query: query, kind: kind, path: path, limit: @limit + 1)
    total = Facts.count(workspace)

    cond do
      total == 0 ->
        "Nothing is kept about this repository yet. What you find out that will stay true " <>
          "is worth `remember`ing."

      found == [] ->
        "No fact matches. #{kept(total)} Ask with fewer words, or by kind or path alone."

      true ->
        shown = Enum.take(found, @limit)

        more =
          if length(found) > @limit,
            do: "\n\nMore match than these #{@limit}: ask with more words, a kind or a path.",
            else: ""

        "#{matched(length(shown), total)}\n\n" <> Enum.map_join(shown, "\n", &fact_line/1) <> more
    end
  end

  defp fact_line(fact) do
    "- [#{fact["kind"]}, #{status(fact["status"])}] #{indent(fact["claim"])}\n" <>
      "  #{provenance(fact)}"
  end

  defp status("moved"), do: "may no longer be true: a file it rests on changed since"
  defp status("missing"), do: "may no longer be true: a file it rests on is gone"
  defp status(status), do: status

  defp provenance(fact) do
    anchors = for %{"path" => path} <- List.wrap(fact["anchors"]), do: path
    evidence = fact["evidence"] || %{}

    [
      anchors != [] && "rests on #{Enum.join(anchors, ", ")}",
      fact["scope"] && "applies to #{fact["scope"]}",
      "checked #{day(fact["verified_at"])} by #{evidence["by"] || "someone"}" <> proof(evidence),
      "id #{fact["id"]}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  defp proof(evidence) do
    parts =
      [
        evidence["session"] && "session #{evidence["session"]}",
        evidence["seq"] && "seq #{evidence["seq"]}",
        evidence["head"] && "HEAD #{evidence["head"]}",
        is_integer(evidence["exit_status"]) && "exit #{evidence["exit_status"]}"
      ]
      |> Enum.filter(& &1)

    if parts == [], do: "", else: " (#{Enum.join(parts, ", ")})"
  end

  defp indent(claim), do: String.replace(claim, "\n", "\n  ")

  defp day(nil), do: "at an unknown time"
  defp day(at), do: String.slice(at, 0, 10)

  defp matched(1, total), do: "1 fact matches, of #{total} kept:"
  defp matched(n, total), do: "#{n} facts match, of #{total} kept:"

  defp kept(1), do: "1 fact is kept."
  defp kept(n), do: "#{n} facts are kept."

  defp optional(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _other -> {:error, "#{key} must be a string"}
    end
  end

  defp check_kind(nil), do: :ok

  defp check_kind(kind) do
    if kind in Memory.kinds(),
      do: :ok,
      else: {:error, "unknown kind #{kind}; one of #{Enum.join(Memory.kinds(), ", ")}"}
  end

  defp enabled?(%{config: %Troupe.Config{memory: false}}), do: false
  defp enabled?(_ctx), do: true
end
