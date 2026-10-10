defmodule Troupe.Onboard.Start do
  @moduledoc """
  Onboarding, then the brief, at a session's start, as a client asks them over the
  protocol (Decision 835): `onboard.plan` (`plan/2`), `onboard.apply` (`accept/3`),
  `onboard.decline` (`decline/3`) and `memory.decline` (`decline_brief/2`). The answers
  are JSON-ready maps.

  - **The plan** says what is due (`Troupe.Onboard.Notice`): onboarding `first` or
    `outdated`, and the brief `first`, `stale` or `outdated`. While onboarding is due it
    lists every proposal the person would see, the workspace's and their own
    (`Troupe.Onboard.plan/2` for every target), each with an `id`, the other tools they
    came from (`tools`), and what was found and not proposed (`skipped`). While it is not,
    the list is empty and no source is asked, so a start where nothing is due costs a few
    `stat` calls and no walk of the workspace. On a pod, or a machine a worker runs on,
    onboarding is never due and `refusal` is `Troupe.Onboard.Pod`'s sentence.
  - **An id is what was shown.** It is a hash of the file's target and path, the sources it
    is made from with their hashes, and what the file holds now, so an id names one
    proposal as it was shown: once a source or the file changes, it names nothing, and the
    write is refused with a sentence rather than made over something the person did not
    see.
  - **Apply and decline plan again** (every target, nothing declined offered), and act on
    the items named, or on all of them: `accept` with `all` writes every ordinary write and
    never creates an `AGENTS.md` that is not there (Decision 827: that is asked on its own,
    and named by its id); `decline` with `all` says no to every one and remembers the no
    for this version of the rules (`Notice.decline_onboarding/2`). Once a call has
    answered everything its plan held, the workspace is recorded as onboarded under this
    build's rules (`Troupe.Onboard.stamp/1`), as `troupe onboard` records it.
  """

  alias Troupe.Onboard
  alias Troupe.Onboard.{Notice, Pod}

  @all_targets [:workspace, :repo, :user]

  # Each other tool, by a directory its files are in or a file name of its own; the first
  # that matches names a file.
  @tools [
    {"Cursor", [".cursor", ".cursorrules"]},
    {"GitHub Copilot", [".github"]},
    {"Claude Code", [".claude", "CLAUDE.md", "CLAUDE.local.md", ".mcp.json"]},
    {"Gemini CLI", ["GEMINI.md"]},
    {"opencode", [".opencode", "opencode.json", "opencode.jsonc"]}
  ]

  @doc """
  What a start owes `workspace`: `onboarding` (`due`, `recorded`, `version`, `tools`,
  `items`, `skipped`), `brief` (`due`, `recorded`, `version`) and `refusal`. Options:
  `config` (the workspace's), `state_dir`, and `sources`, `config_dir` and `home` for a
  test.
  """
  @spec plan(Path.t(), keyword()) :: map()
  def plan(workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    opts = with_state_dir(opts)
    refusal = Pod.refusal(nil)

    status =
      Notice.onboarding(
        workspace,
        onboard_opts(opts) ++ [targets: @all_targets, all_sources: true]
      )

    plan =
      cond do
        status.due == "none" -> nil
        status.plan -> status.plan
        true -> Onboard.plan(workspace, onboard_opts(opts) ++ [targets: @all_targets])
      end

    items = if plan, do: Enum.map(plan.proposals, &item_json/1), else: []

    %{
      "onboarding" => %{
        "due" => status.due,
        "recorded" => status.recorded,
        "version" => status.version,
        "tools" => tools(items),
        "items" => items,
        "skipped" => if(plan, do: skipped_json(plan), else: [])
      },
      "brief" => brief_json(workspace, opts),
      "refusal" => refusal
    }
  end

  @doc """
  Writes the items named by `ids`, or with `:all` every one that is an ordinary write.
  Answers `written` (`id`, `shown`, `action`) and `refused` (`id`, `reason`), or the pod's
  sentence where onboarding does not run.
  """
  @spec accept(Path.t(), [String.t()] | :all, keyword()) :: {:ok, map()} | {:error, String.t()}
  def accept(workspace, selection, opts \\ []) do
    workspace = Path.expand(workspace)
    opts = with_state_dir(opts)

    with :ok <- allowed() do
      plan = Onboard.plan(workspace, onboard_opts(opts) ++ [targets: @all_targets])
      {chosen, unknown} = choose(plan.proposals, selection, &(&1.question == :write))

      results = Enum.map(chosen, &write(&1, workspace, opts))
      written = for {:written, w} <- results, do: w
      refused = for({:refused, r} <- results, do: r) ++ Enum.map(unknown, &not_shown/1)

      stamp_if_answered(workspace, plan, length(written))
      {:ok, %{"written" => written, "refused" => refused}}
    end
  end

  @doc """
  Says no to the items named by `ids`, or with `:all` to every one, and then remembers
  the no for this version of the rules. Answers `declined`, how many.
  """
  @spec decline(Path.t(), [String.t()] | :all, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def decline(workspace, selection, opts \\ []) do
    workspace = Path.expand(workspace)
    opts = with_state_dir(opts)

    with :ok <- allowed() do
      plan = Onboard.plan(workspace, onboard_opts(opts) ++ [targets: @all_targets])
      {chosen, _unknown} = choose(plan.proposals, selection, fn _item -> true end)
      declined = Enum.count(chosen, &(Onboard.decline(&1, onboard_opts(opts)) == :ok))

      if selection == :all, do: Notice.decline_onboarding(workspace, onboard_opts(opts))

      stamp_if_answered(workspace, plan, declined)
      {:ok, %{"declined" => declined}}
    end
  end

  @doc "Remembers a no to rewriting a brief an older survey wrote, for that survey's version."
  @spec decline_brief(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def decline_brief(workspace, opts \\ []),
    do: Notice.decline_brief(workspace, onboard_opts(with_state_dir(opts)))

  @doc """
  The id of an item `Troupe.Onboard.plan/2` gave: a hash of where it would be written,
  what it was made from, and what the file holds now.
  """
  @spec id(Onboard.item()) :: String.t()
  def id(item) do
    also =
      item.proposal
      |> Map.get(:also_from, [])
      |> Enum.map(&"#{&1.source}\u0000#{&1.source_hash}")
      |> Enum.sort()

    current = if item.current, do: sha256(item.current), else: "-"

    [
      to_string(item.proposal.target),
      item.proposal.path,
      item.proposal.source,
      item.proposal.source_hash,
      current | also
    ]
    |> Enum.join("\n")
    |> sha256()
    |> binary_part(0, 16)
  end

  @doc "An item as the protocol carries it."
  @spec item_json(Onboard.item()) :: map()
  def item_json(item) do
    %{
      "id" => id(item),
      "target" => to_string(item.proposal.target),
      "path" => item.proposal.path,
      "shown" => item.shown,
      "status" => to_string(item.status),
      "question" => to_string(item.question),
      "source" => item.proposal.source,
      "also_from" => Enum.map(Map.get(item.proposal, :also_from, []), & &1.source),
      "was" => item.was,
      "notes" => Map.get(item.proposal, :notes, []),
      "diff" => item.diff
    }
  end

  @doc """
  The other tool a file of theirs belongs to, by its name and place, or `nil` for one this
  does not know (a file opencode's `instructions` names, say, which is opencode's through
  `opencode.json`).
  """
  @spec tool(String.t()) :: String.t() | nil
  def tool(source) do
    parts = source |> String.trim_leading("~/") |> String.split("/")
    names = MapSet.new([List.last(parts) | Enum.drop(parts, -1)])

    Enum.find_value(@tools, fn {tool, marks} ->
      if Enum.any?(marks, &MapSet.member?(names, &1)), do: tool
    end)
  end

  ## Internals

  defp write(item, workspace, opts) do
    case Onboard.accept(item, workspace, onboard_opts(opts)) do
      {:ok, written} ->
        {:written,
         %{"id" => id(item), "shown" => written.shown, "action" => to_string(written.action)}}

      {:error, reason} ->
        {:refused, %{"id" => id(item), "reason" => reason}}
    end
  end

  defp allowed do
    case Pod.refusal(nil) do
      nil -> :ok
      sentence -> {:error, sentence}
    end
  end

  # The items a selection names, and the ids it names that are not in the plan; `:all` is
  # every item `all?` keeps.
  defp choose(items, :all, all?), do: {Enum.filter(items, all?), []}

  defp choose(items, ids, _all?) when is_list(ids) do
    by_id = Map.new(items, &{id(&1), &1})
    ids = Enum.uniq(ids)
    {for(id <- ids, item = by_id[id], do: item), Enum.reject(ids, &Map.has_key?(by_id, &1))}
  end

  defp not_shown(id),
    do: %{
      "id" => id,
      "reason" =>
        "it is not proposed as it was shown any more: its source or the file changed, or it " <>
          "was written or left out since; ask for the plan again"
    }

  # Every item the plan held was answered by this call: nothing is left to ask about.
  defp stamp_if_answered(workspace, plan, answered) do
    if answered == length(plan.proposals), do: Onboard.stamp(workspace), else: :ok
  end

  defp tools(items) do
    items
    |> Enum.flat_map(&[&1["source"] | &1["also_from"]])
    |> Enum.map(&tool/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp skipped_json(plan) do
    Enum.map(plan.skipped, &%{"source" => &1.source, "reason" => &1.reason}) ++
      Enum.map(plan.refused, fn refusal ->
        %{"source" => refusal.source || refusal.path, "reason" => refusal.reason}
      end)
  end

  defp brief_json(workspace, opts) do
    brief = Notice.brief(workspace, Keyword.take(opts, [:config, :state_dir]))
    %{"due" => brief.due, "recorded" => brief.recorded, "version" => brief.version}
  end

  defp onboard_opts(opts), do: Keyword.take(opts, [:state_dir, :sources, :config_dir, :home])

  # The workspace's config keeps the state directory, unless a test names one.
  defp with_state_dir(opts) do
    case {opts[:state_dir], opts[:config]} do
      {nil, %Troupe.Config{state_dir: dir}} when is_binary(dir) ->
        Keyword.put(opts, :state_dir, dir)

      _keep ->
        opts
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
