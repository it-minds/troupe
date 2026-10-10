defmodule Troupe.Onboard.Notice do
  @moduledoc """
  What a session's start owes a workspace (Decisions 827 and 835): onboarding first, then
  the brief. Onboarding proposes by itself and never writes by itself.

  - **Onboarding is due** `first` in a workspace with other tools' files, nothing
    onboarded (no `.troupe/onboarded.json`, no file recording where it came from) and
    nothing declined in it; `outdated` in one onboarded under older rules than this build's
    (`Troupe.Onboard.onboarded_version/2` below `Troupe.Onboard.version/0`); otherwise
    `none`. A person who said no to onboarding the workspace under this build's rules
    (`decline_onboarding/2`) is not asked again until the rules change. Only in a git
    repository: a workspace in none (the home directory, say, whose `.claude/` is Claude
    Code's own) is due nothing, and no source is asked about it (Decision 835).
  - **The brief is due** `first` when there is none and `stale` when it is stale, each as
    `Troupe.Session.Memory.refresh_due?/2` has it (Decisions 696 and 713, the TUI's 127);
    `outdated` when an older survey than this build's wrote it
    (`Troupe.Memory.survey_version/0`) and the person has not said no to that
    (`decline_brief/2`); otherwise `none`, and always `none` outside a git repository, as
    onboarding is (Decision 838).
  - **The notice.** `due/2` is the `onboarding_suggested` event a session's start logs:
    what to say about onboarding (counted by kind, `2 AGENTS.md files, 3 rules and 1
    agent`, never the content) and about an older brief, with what is due (`due`,
    `brief_due`) and the files a client would ask about (`counts`). It is said at every
    start while onboarding is due or the brief is outdated and the person has not said no
    for that version (Decision 835; Decision 827 said it once per version, and a person who
    closed the client before answering was never asked again), so a client that asks on
    the event asks until it is answered.

  The person's answers live where those to `troupe onboard` are, in the state directory's
  `onboard.json`, never in the repository: `onboarding_declined` (the workspace's real path
  to the rules' version the person said no under) and `brief_declined` (the brief's path to
  the survey's). Nothing here writes anything else: no proposal is accepted, no brief
  rebuilt, and the notice itself writes nothing.

  Asked only on the person's own machine (not on a pod, not where a worker runs). The
  first-time look asks each source's `found?/1` first, a look at the workspace's root, so a
  workspace with none of their files costs a few `stat` calls a start, and then asks the
  sources for the workspace's files only (`targets`) unless told otherwise, so the notice
  reads nothing in the person's home or config directory.
  """

  alias Troupe.{Config, Memory, Onboard, Paths, Workspace}
  alias Troupe.Onboard.Pod
  alias Troupe.Session.Memory, as: Brief

  # The state file `Troupe.Onboard` keeps declines in, under the same lock.
  @state "onboard.json"

  @typedoc "What is due, the version recorded and this build's, and the plan it took to say."
  @type onboarding :: %{
          due: String.t(),
          recorded: non_neg_integer() | nil,
          version: pos_integer(),
          plan: Onboard.plan() | nil
        }

  @type brief :: %{due: String.t(), recorded: non_neg_integer() | nil, version: pos_integer()}

  @doc """
  The `onboarding_suggested` event's data for a session starting in `workspace` now, or
  `nil` when there is nothing to say: onboarding is not due and the brief is not outdated,
  or the person said no to each for this version. Options: `state_dir`, `config` (the
  workspace's, for the brief), `memory` (`false` when the brief is off), and `sources`,
  `config_dir` and `home` for a test.
  """
  @spec due(Path.t(), keyword()) :: map() | nil
  def due(workspace, opts \\ []) do
    if Pod.allowed?(nil), do: due_here(Path.expand(workspace), opts)
  end

  @doc """
  Whether onboarding is due in `workspace` (`first`, `outdated` or `none`), the version it
  was onboarded under (`nil`: never) and this build's. To say `first` it plans, and the
  plan comes back with it: for `targets` (`[:workspace, :repo]` unless told, so nothing of
  the person's own is read), and with every registered source when `all_sources: true`
  (the ones that find their files at the root otherwise). Options as `due/2`'s.
  """
  @spec onboarding(Path.t(), keyword()) :: onboarding()
  def onboarding(workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    current = Onboard.version()
    recorded = Onboard.onboarded_version(workspace, Keyword.take(opts, [:config_dir, :home]))
    none = %{due: "none", recorded: recorded, version: current, plan: nil}

    cond do
      not Pod.allowed?(nil) -> none
      not repository?(workspace) -> none
      said_no?("onboarding_declined", key(workspace), current, opts) -> none
      is_integer(recorded) and recorded < current -> %{none | due: "outdated"}
      is_integer(recorded) -> none
      true -> first(workspace, none, opts)
    end
  end

  # Nothing onboarded: due when the sources that find their files at the root would propose
  # something into the workspace, unless the person has already said no to something here.
  defp first(workspace, none, opts) do
    registered = Keyword.get(opts, :sources, Onboard.sources())
    found = Enum.filter(registered, &found?(&1, workspace))

    if found == [] or declined_here?(key(workspace), opts) do
      none
    else
      plan =
        Onboard.plan(
          workspace,
          Keyword.merge(Keyword.take(opts, [:state_dir, :config_dir, :home]),
            sources: if(opts[:all_sources], do: registered, else: found),
            targets: Keyword.get(opts, :targets, [:workspace, :repo])
          )
        )

      if Enum.any?(plan.proposals, &(&1.proposal.target in [:workspace, :repo])),
        do: %{none | due: "first", plan: plan},
        else: %{none | plan: plan}
    end
  end

  @doc """
  Whether the brief is due in `workspace`: `first` (none, and a librarian may start),
  `stale`, `outdated` (an older survey wrote it) or `none`, with the survey version it
  records (`nil`: no brief; `0`: one from before there were versions) and this build's.
  `config` is the workspace's (`memory`, `memory_max_age_days`, `state_dir`); `memory:
  false` says the brief is off without one.
  """
  @spec brief(Path.t(), keyword()) :: brief()
  def brief(workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    config = Keyword.get(opts, :config)
    version = Memory.survey_version()

    if Keyword.get(opts, :memory, true) == false do
      %{due: "none", recorded: nil, version: version}
    else
      brief = Brief.brief(workspace)
      recorded = brief && version(brief.survey)
      %{due: brief_due(workspace, brief, config, opts), recorded: recorded, version: version}
    end
  end

  # Outside a git repository nothing is due, as onboarding is not (Decision 838).
  defp brief_due(workspace, brief, config, opts) do
    if Brief.repository?(workspace),
      do: brief_due_here(workspace, brief, config, opts),
      else: "none"
  end

  defp brief_due_here(workspace, brief, config, opts) do
    case Brief.status(workspace, config) do
      :absent -> if Brief.held_until(workspace, config) == nil, do: "first", else: "none"
      :stale -> if Brief.held_until(workspace, config) == nil, do: "stale", else: "none"
      :fresh -> if outdated_brief?(workspace, brief, opts), do: "outdated", else: "none"
      :disabled -> "none"
    end
  end

  defp outdated_brief?(workspace, brief, opts) do
    older(brief) != [] and
      not said_no?("brief_declined", brief_key(workspace), Memory.survey_version(), opts)
  end

  @doc """
  Remembers that the person said no to onboarding `workspace` under this build's rules:
  not asked again, at a start, until the rules change. Options: `state_dir`.
  """
  @spec decline_onboarding(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def decline_onboarding(workspace, opts \\ []),
    do: put_state("onboarding_declined", key(Path.expand(workspace)), Onboard.version(), opts)

  @doc """
  Remembers that the person said no to rewriting the brief an older survey wrote: not
  asked again until the survey changes. Kept under the brief's path, so a worktree's
  answer is its repository's. Options: `state_dir`.
  """
  @spec decline_brief(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def decline_brief(workspace, opts \\ []),
    do:
      put_state(
        "brief_declined",
        brief_key(Path.expand(workspace)),
        Memory.survey_version(),
        opts
      )

  defp due_here(workspace, opts) do
    status = onboarding(workspace, Keyword.take(opts, [:state_dir, :config_dir, :home, :sources]))

    onboarding =
      case status do
        %{due: "first", plan: plan} -> [{:first, counts(plan.proposals)}]
        %{due: "outdated", recorded: recorded} -> [{:outdated, recorded}]
        _none -> []
      end

    case onboarding ++ say_brief(workspace, opts) do
      [] -> nil
      parts -> data(workspace, parts, status, opts)
    end
  end

  ## Onboarding

  # In a git repository: a `.git` (a worktree's file too) here or in a directory above, as
  # the instruction files are read up to it. Onboarding brings a repository's files in; a
  # start in a directory that is in none (the home directory, whose `.claude/` is Claude
  # Code's own) is due nothing, and no source looks at it, let alone walks it.
  defp repository?(workspace), do: Brief.repository?(workspace)

  defp found?(source, workspace) do
    if Code.ensure_loaded?(source) and function_exported?(source, :found?, 1),
      do: source.found?(workspace) == true,
      else: true
  end

  defp declined_here?(key, opts) do
    opts
    |> state()
    |> Map.get("declined", %{})
    |> Map.keys()
    |> Enum.any?(&String.starts_with?(&1, key <> "/"))
  end

  @kinds [
    {"instructions", "AGENTS.md", "AGENTS.md files"},
    {"rules", "rule", "rules"},
    {"agents", "agent", "agents"},
    {"commands", "command", "commands"},
    {"skills", "skill file", "skill files"},
    {"workflows", "workflow", "workflows"},
    {"mcp", "MCP servers file", "MCP servers files"},
    {"other", "other file", "other files"}
  ]

  # The workspace's proposals by kind, in the order `@kinds` names them, each `{kind, n}`.
  defp counts(items) do
    by_kind = Enum.frequencies_by(items, &kind(&1.proposal))

    for {kind, _one, _many} <- @kinds, n = by_kind[kind], n != nil, do: {kind, n}
  end

  defp kind(%{target: :workspace}), do: "instructions"
  defp kind(%{path: "rules/" <> _}), do: "rules"
  defp kind(%{path: "agents/" <> _}), do: "agents"
  defp kind(%{path: "commands/" <> _}), do: "commands"
  defp kind(%{path: "skills/" <> _}), do: "skills"
  defp kind(%{path: "workflows/" <> _}), do: "workflows"
  defp kind(%{path: "mcp.json"}), do: "mcp"
  defp kind(_proposal), do: "other"

  ## The brief

  # A brief an older survey wrote, said until it is written again or the person says no to
  # rewriting it under this survey.
  defp say_brief(workspace, opts) do
    cond do
      Keyword.get(opts, :memory, true) == false -> []
      not repository?(workspace) -> []
      said_no?("brief_declined", brief_key(workspace), Memory.survey_version(), opts) -> []
      true -> older(Brief.brief(workspace))
    end
  end

  defp older(%Memory{sections: [_ | _], survey: survey}) do
    if version(survey) < Memory.survey_version(), do: [{:brief, version(survey)}], else: []
  end

  defp older(_none), do: []

  ## The event

  defp data(workspace, parts, onboarding, opts) do
    counts = Enum.find_value(parts, [], fn part -> match?({:first, _}, part) && elem(part, 1) end)
    brief = Enum.find_value(parts, fn part -> match?({:brief, _}, part) && elem(part, 1) end)

    %{
      "workspace" => workspace,
      "reasons" => Enum.map(parts, &(&1 |> elem(0) |> Atom.to_string())),
      "message" => Enum.map_join(parts, " ", &sentence/1),
      "command" => "troupe onboard",
      "proposals" => Map.new(counts),
      "onboarding_version" => Onboard.version(),
      "onboarded_version" => onboarding.recorded,
      "survey_version" => Memory.survey_version(),
      "brief_version" => brief,
      "due" => onboarding.due,
      "brief_due" => brief_status(workspace, opts),
      "counts" => questions(onboarding.plan)
    }
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  # What a client asks at this start about the brief; `none` when the brief is off.
  defp brief_status(workspace, opts) do
    brief(workspace, Keyword.take(opts, [:config, :memory, :state_dir])).due
  rescue
    _cannot_tell -> nil
  end

  # The files a client would ask about, as the workspace's plan has them: how many, how
  # many are ordinary writes, and how many a new `AGENTS.md`, which is asked on its own.
  defp questions(nil), do: nil

  defp questions(plan) do
    creates = Enum.count(plan.proposals, &(&1.question == :create_agents_md))
    total = length(plan.proposals)
    %{"files" => total, "write" => total - creates, "create_agents_md" => creates}
  end

  defp sentence({:first, counts}) do
    "Other tools' files are here: `troupe onboard` would bring in #{listed(counts)} as " <>
      "Troupe's own files. Run it in this workspace to see each as a diff and choose; " <>
      "nothing is written until you do."
  end

  defp sentence({:outdated, version}) do
    "This workspace was onboarded under version #{version} of the onboarding rules, and " <>
      "this build's are version #{Onboard.version()}: run `troupe onboard` to see what " <>
      "they would write now."
  end

  defp sentence({:brief, version}) do
    "The project brief was written by version #{version} of the librarian's survey, and " <>
      "this build's is version #{Memory.survey_version()}: `/memory refresh` has the " <>
      "librarian write it again."
  end

  defp listed(counts) do
    words =
      for {kind, n} <- counts do
        {^kind, one, many} = List.keyfind(@kinds, kind, 0)
        if n == 1, do: "1 #{one}", else: "#{n} #{many}"
      end

    case Enum.split(words, -1) do
      {[], [only]} -> only
      {rest, [last]} -> Enum.join(rest, ", ") <> " and " <> last
    end
  end

  ## State

  defp state(opts) do
    with {:ok, text} <- File.read(state_file(opts)),
         {:ok, %{} = map} <- Jason.decode(text) do
      map
    else
      _ -> %{}
    end
  end

  # The person said no under this version, or a newer one.
  defp said_no?(section, key, current, opts) do
    opts |> state() |> Map.get(section, %{}) |> Map.get(key) |> version() >= current
  end

  defp put_state(section, key, value, opts) do
    update_state(opts, fn map ->
      Map.put(map, section, map |> Map.get(section, %{}) |> Map.put(key, value))
    end)
  end

  defp update_state(opts, fun) do
    file = state_file(opts)

    :global.trans({{Onboard, file}, self()}, fn ->
      map = fun.(state(opts))
      tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- File.write(tmp, Jason.encode!(map, pretty: true) <> "\n"),
           :ok <- File.rename(tmp, file) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, "cannot write #{Paths.display(file)}: #{:file.format_error(reason)}"}
      end
    end)
  end

  defp state_file(opts), do: Path.join(Paths.state_dir(state_dir(opts)), @state)

  defp state_dir(opts) do
    case {opts[:state_dir], opts[:config]} do
      {dir, _config} when is_binary(dir) -> dir
      {nil, %Config{state_dir: dir}} -> dir
      _none -> nil
    end
  end

  defp key(workspace) do
    case Workspace.real_path(workspace) do
      {:ok, real} -> Workspace.compare_key(real)
      {:error, _reason} -> Workspace.compare_key(workspace)
    end
  end

  # The brief's own path, so every checkout of one repository shares the answer.
  defp brief_key(workspace), do: workspace |> Brief.path() |> key()

  defp version(n) when is_integer(n) and n >= 0, do: n
  defp version(_none), do: 0
end
