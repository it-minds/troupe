defmodule Troupe.Onboard.Notice do
  @moduledoc """
  What a session's start says about onboarding (Decision 827; #516's fourth decision):
  onboarding proposes by itself and never writes by itself.

  - **The first time.** A workspace with other tools' files and nothing onboarded (no
    `.troupe/onboarded.json`, no file recording where it came from) and nothing declined
    in it is told what `troupe onboard` would propose, counted by kind (`2 AGENTS.md
    files, 3 rules and 1 agent`), never the content, and how to run it.
  - **Older rules.** A workspace onboarded under older rules than this build's
    (`Troupe.Onboard.onboarded_version/2` below `Troupe.Onboard.version/0`) is told to run
    `troupe onboard` again, and one whose brief an older survey wrote
    (`Troupe.Memory.survey_version/0`) to have the librarian write it again
    (`/memory refresh`). In the same notice, one `onboarding_suggested` event.

  Each is looked for once per workspace and version, said when there is something to
  say, and remembered where the person's answers to `troupe onboard` are, in the state
  directory's `onboard.json` (`suggested`, keyed by the workspace's real path, with the
  versions looked for): never in the repository. Onboarding the workspace, or declining a
  proposal in it, ends the first notice for good; a later build with newer rules looks
  again, once. Nothing here writes anything else: no proposal is accepted, no brief
  rebuilt.

  Asked only on the person's own machine (not on a pod, not where a worker runs); the
  first-time look asks each source's `found?/1` first, a look at the workspace's root, so
  a workspace with none of their files costs a few `stat` calls a start.
  """

  alias Troupe.{Memory, Onboard, Paths, Workspace}
  alias Troupe.Onboard.Pod
  alias Troupe.Session.Memory, as: Brief

  # The state file `Troupe.Onboard` keeps declines in, under the same lock.
  @state "onboard.json"

  @doc """
  The `onboarding_suggested` event's data for a session starting in `workspace` now, or
  `nil` when there is nothing to say or it was said already; what it says is remembered as
  said. Options: `state_dir`, `memory` (`false` when the brief is off), and `sources`,
  `config_dir` and `home` for a test.
  """
  @spec due(Path.t(), keyword()) :: map() | nil
  def due(workspace, opts \\ []) do
    if Pod.allowed?(nil), do: due_here(Path.expand(workspace), opts)
  end

  defp due_here(workspace, opts) do
    key = key(workspace)
    told = state(opts) |> Map.get("suggested", %{}) |> Map.get(key, %{})
    {onboarding, onboarded, looked} = onboarding(workspace, told, key, opts)
    {brief, checked} = brief(workspace, told, opts)

    remember(key, Map.merge(looked, checked), opts)

    case onboarding ++ brief do
      [] -> nil
      parts -> data(workspace, parts, onboarded)
    end
  end

  ## Onboarding

  # What to say, the version the workspace was onboarded under, and what to remember:
  # that this version's look was taken, when it was, whether or not it found anything to
  # say, so a workspace whose files give nothing (a `CLAUDE.md` that is a link to its
  # `AGENTS.md`) is not planned again at every start.
  defp onboarding(workspace, told, key, opts) do
    current = Onboard.version()
    looked = %{"onboarding" => current}

    if version(told["onboarding"]) >= current do
      {[], nil, %{}}
    else
      case Onboard.onboarded_version(workspace, Keyword.take(opts, [:config_dir, :home])) do
        nil -> first(workspace, key, opts)
        version when version < current -> {[{:outdated, version}], version, looked}
        version -> {[], version, %{}}
      end
    end
  end

  # Nothing onboarded: what the sources that find their files at the root would propose,
  # unless the person has already said no to something here.
  defp first(workspace, key, opts) do
    sources = Enum.filter(Keyword.get(opts, :sources, Onboard.sources()), &found?(&1, workspace))

    if sources == [] or declined_here?(key, opts) do
      {[], nil, %{}}
    else
      plan =
        Onboard.plan(
          workspace,
          Keyword.merge(Keyword.take(opts, [:state_dir, :config_dir, :home]), sources: sources)
        )

      case counts(plan.proposals) do
        [] -> {[], nil, %{"onboarding" => Onboard.version()}}
        counts -> {[{:first, counts}], nil, %{"onboarding" => Onboard.version()}}
      end
    end
  end

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

  # The proposals by kind, in the order `@kinds` names them, each `{kind, n}`.
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

  # A brief an older survey wrote. Checked once per survey version and workspace whatever
  # it finds, since a brief written from now on is this version's or newer.
  defp brief(workspace, told, opts) do
    if Keyword.get(opts, :memory, true) == false or
         version(told["survey"]) >= Memory.survey_version(),
       do: {[], %{}},
       else: {older(Brief.brief(workspace)), %{"survey" => Memory.survey_version()}}
  end

  defp older(%Memory{sections: [_ | _], survey: survey}) do
    if version(survey) < Memory.survey_version(), do: [{:brief, version(survey)}], else: []
  end

  defp older(_none), do: []

  ## The event

  defp data(workspace, parts, onboarded) do
    counts = Enum.find_value(parts, [], fn part -> match?({:first, _}, part) && elem(part, 1) end)
    brief = Enum.find_value(parts, fn part -> match?({:brief, _}, part) && elem(part, 1) end)

    %{
      "workspace" => workspace,
      "reasons" => Enum.map(parts, &(&1 |> elem(0) |> Atom.to_string())),
      "message" => Enum.map_join(parts, " ", &sentence/1),
      "command" => "troupe onboard",
      "proposals" => Map.new(counts),
      "onboarding_version" => Onboard.version(),
      "onboarded_version" => onboarded,
      "survey_version" => Memory.survey_version(),
      "brief_version" => brief
    }
    |> Map.reject(fn {_key, value} -> value == nil end)
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

  defp remember(_key, told, _opts) when told == %{}, do: :ok

  defp remember(key, told, opts) do
    file = state_file(opts)

    :global.trans({{Onboard, file}, self()}, fn ->
      map = state(opts)
      suggested = Map.get(map, "suggested", %{})
      entry = suggested |> Map.get(key, %{}) |> Map.merge(told)
      map = Map.put(map, "suggested", Map.put(suggested, key, entry))
      tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- File.write(tmp, Jason.encode!(map, pretty: true) <> "\n") do
        File.rename(tmp, file)
      end
    end)
  end

  defp state_file(opts), do: Path.join(Paths.state_dir(opts[:state_dir]), @state)

  defp key(workspace) do
    case Workspace.real_path(workspace) do
      {:ok, real} -> Workspace.compare_key(real)
      {:error, _reason} -> Workspace.compare_key(workspace)
    end
  end

  defp version(n) when is_integer(n) and n >= 0, do: n
  defp version(_none), do: 0
end
