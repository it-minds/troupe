defmodule Troupe.Instructions.Check do
  @moduledoc """
  `troupe instructions check`: the instruction files a session in a workspace would read,
  checked against each other and against this machine (issue #123, Decision 810).

  Six kinds of finding, each on one line with its file and line:

  - `contradiction`: two scopes name different commands for one subject, as the root's
    `npm test` and `frontend/AGENTS.md`'s `pnpm test` do. The subject (test, build, lint,
    format, run) and its ecosystem are read from a short list of commands; a scope is
    held to the nearest scope around it that names the same subject in the same
    ecosystem, and the two disagree when they name no command in common.
  - `path`: a repository path a rule names, in a code span or a link, that is not there,
    from the directory the file is about (the one holding its `.agents` or `.troupe`), its
    own directory or the repository root; and an `@` import the loader found missing.
  - `command`: a command a rule names, in a code span or a fenced block, whose program is
    not on the `PATH` a session's commands run with.
  - `duplicate`: a rule, a paragraph or a list item, said again in another file.
  - `drift`: a file onboarding wrote, under the workspace's `.troupe/` or the person's
    config directory, whose source has changed or gone since (Decision 823), read from the
    provenance the file recorded (`Troupe.Onboard.drift/2`), not from a search of its own.
  - `outdated`: the workspace was onboarded under older onboarding rules than this
    build's (Decision 827), on the line of `.troupe/onboarded.json`'s `onboarding`; `troupe
    onboard` shows what the newer rules would write, and a run that answers every question
    records them. Also `Troupe.Onboard.drift/2`'s.

  Each would rather miss a finding than make a false one: only what reads unmistakably as
  a command or a repository path is checked (`Troupe.Instructions.Check.Text`), and the
  rest is passed over.

  The files are `Troupe.Instructions.load/3`'s, as a session that had worked on every file
  under the workspace would read them, so a nested `AGENTS.md` is checked wherever it is
  and whatever else the loader reads comes with it: `.agents/AGENTS.md` and
  `.troupe/rules/*.md`, and none of the other tools' files it lists as skipped (Decision
  828). Which files and which import are the loader's alone; this reads each file it read
  again, whole, for the lines. The brief is Troupe's own, and not checked.

  `findings/2` is pure but for the two probes it is handed; `run/2` reads.
  """

  alias Troupe.{Executable, Gitignore, Instructions, Onboard, Paths, Reaper}
  alias Troupe.Instructions.Check.Text

  @type kind :: :contradiction | :path | :command | :duplicate | :drift | :outdated

  @type finding :: %{path: Path.t(), line: pos_integer(), kind: kind(), message: String.t()}

  @typedoc """
  One file the loader read: its path, scope and directory as `Troupe.Instructions` gives
  them, the imports it named that were not followed, and its whole content. `directory`
  is the one the file is about, the loader's: an `.agents/AGENTS.md`'s or a rule's is the
  directory that holds its `.agents` or `.troupe`, not the file's own.
  """
  @type source :: %{
          required(:path) => Path.t(),
          required(:scope) => atom(),
          required(:where) => String.t() | nil,
          required(:unfollowed) => [map()],
          required(:content) => String.t(),
          optional(:directory) => Path.t()
        }

  # What each subject is for, in the finding's words.
  @subjects %{
    test: "run the tests",
    build: "build",
    lint: "lint",
    format: "format",
    run: "run it"
  }

  # The commands a subject is recognised by: the subject, the ecosystem the command
  # belongs to, and the tool it chooses there. Two scopes contradict each other only
  # within one ecosystem, so a root's `mix test` and `frontend/`'s `pnpm test` are two
  # parts of a repository, not a disagreement.
  @commands [
    {~r/^npm (?:test|t|run test)(?:\s|$)/, :test, :node, "npm"},
    {~r/^(pnpm|yarn|bun) (?:run )?test(?:\s|$)/, :test, :node, 1},
    {~r/^deno test(?:\s|$)/, :test, :node, "deno"},
    {~r/^npm run build(?:\s|$)/, :build, :node, "npm"},
    {~r/^(pnpm|yarn|bun) (?:run )?build(?:\s|$)/, :build, :node, 1},
    {~r/^npm run lint(?:\s|$)/, :lint, :node, "npm"},
    {~r/^(pnpm|yarn|bun) (?:run )?lint(?:\s|$)/, :lint, :node, 1},
    {~r/^deno lint(?:\s|$)/, :lint, :node, "deno"},
    {~r/^npm run (?:format|fmt)(?:\s|$)/, :format, :node, "npm"},
    {~r/^(pnpm|yarn|bun) (?:run )?(?:format|fmt)(?:\s|$)/, :format, :node, 1},
    {~r/^deno fmt(?:\s|$)/, :format, :node, "deno"},
    {~r/^npm (?:start|run (?:dev|start))(?:\s|$)/, :run, :node, "npm"},
    {~r/^(pnpm|yarn|bun) (?:run )?(?:dev|start)(?:\s|$)/, :run, :node, 1},
    {~r/^mix test(?:\s|$)/, :test, :elixir, "mix"},
    {~r/^mix compile(?:\s|$)/, :build, :elixir, "mix"},
    {~r/^mix credo(?:\s|$)/, :lint, :elixir, "mix"},
    {~r/^mix format(?:\s|$)/, :format, :elixir, "mix"},
    {~r/^(?:mix phx\.server|iex -S mix)(?:\s|$)/, :run, :elixir, "mix"},
    {~r/^cargo test(?:\s|$)/, :test, :rust, "cargo test"},
    {~r/^cargo nextest run(?:\s|$)/, :test, :rust, "cargo nextest"},
    {~r/^cargo build(?:\s|$)/, :build, :rust, "cargo"},
    {~r/^cargo clippy(?:\s|$)/, :lint, :rust, "cargo"},
    {~r/^cargo fmt(?:\s|$)/, :format, :rust, "cargo"},
    {~r/^cargo run(?:\s|$)/, :run, :rust, "cargo"},
    {~r/^go test(?:\s|$)/, :test, :go, "go"},
    {~r/^go build(?:\s|$)/, :build, :go, "go"},
    {~r/^go vet(?:\s|$)/, :lint, :go, "go"},
    {~r/^(?:gofmt|go fmt)(?:\s|$)/, :format, :go, "go"},
    {~r/^go run(?:\s|$)/, :run, :go, "go"},
    {~r/^(?:pytest|py\.test|python3? -m pytest)(?:\s|$)/, :test, :python, "pytest"},
    {~r/^python3? -m unittest(?:\s|$)/, :test, :python, "unittest"},
    {~r/^ruff check(?:\s|$)/, :lint, :python, "ruff"},
    {~r/^flake8(?:\s|$)/, :lint, :python, "flake8"},
    {~r/^pylint(?:\s|$)/, :lint, :python, "pylint"},
    {~r/^ruff format(?:\s|$)/, :format, :python, "ruff"},
    {~r/^black(?:\s|$)/, :format, :python, "black"}
  ]

  # A file name a path in a span may end with: one with a slash and one of these is a
  # repository path, whether or not its directories exist.
  @extensions ~w(md mdc markdown txt rst adoc ex exs eex heex leex erl hrl ts tsx mts cts js
                 jsx mjs cjs json jsonc json5 yaml yml toml lock ini cfg conf env rs go mod py
                 pyi ipynb rb sh bash zsh fish ps1 psm1 psd1 bat cmd css scss sass less html
                 htm svelte vue astro sql graphql gql proto xml svg png jpg jpeg gif webp ico
                 pdf csv tsv java kt kts gradle swift c h cc cpp hpp cs csproj sln fs php lua
                 dart scala tf hcl nix zig)

  @doc """
  Checks the instruction files a session in `workspace` would read, and answers what
  `troupe instructions check` prints and its exit status: 0 for no finding, 1 for any, 2
  when the workspace cannot be read. `json: true` prints the same as one object.
  `executable?` replaces the `PATH` lookup, and `config_dir` and `home` where onboarded
  files and their sources are, for a test.
  """
  @spec run(Path.t(), keyword()) :: {String.t(), 0 | 1 | 2}
  def run(workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    json? = Keyword.get(opts, :json, false)

    case File.ls(workspace) do
      {:ok, _names} ->
        %{root: root, sources: sources, elsewhere?: elsewhere?} = sources(workspace)
        found = findings(sources, [root: root, elsewhere?: elsewhere?] ++ opts)
        onboarded = Onboard.drift(workspace, Keyword.take(opts, [:config_dir, :home]))

        report(
          %{
            workspace: workspace,
            root: root,
            sources: sources,
            onboarded: onboarded.files,
            findings: found ++ onboarded.findings
          },
          json?
        )

      {:error, reason} ->
        unreadable(workspace, reason, json?)
    end
  end

  @doc """
  The files `Troupe.Instructions.load/3` reads for a session in `workspace` that had worked
  on every file under it, each with its whole content; the repository root; and
  `elsewhere?`, whether the repository has a path that is not where a rule's words put
  it. A directory `.gitignore` hides is not worked in, nor is a repository inside this
  one (a submodule, a worktree), whose files are its own.
  """
  @spec sources(Path.t()) :: %{
          root: Path.t(),
          sources: [source()],
          elsewhere?: (Path.t() -> boolean())
        }
  def sources(workspace) do
    workspace = Path.expand(workspace)
    ignore = Gitignore.load(workspace)
    files = walk(workspace, "", ignore)
    loaded = Instructions.load(workspace, nil, files)
    root = root(loaded.files, workspace)

    sources =
      for file <- loaded.files,
          file.scope != :brief and file.status not in [:skipped, :outside, :unreadable],
          {:ok, content} <- [File.read(file.path)] do
        file
        |> Map.take([:path, :scope, :where, :unfollowed, :directory])
        |> Map.put(:content, content)
      end

    %{root: root, sources: sources, elsewhere?: elsewhere(workspace, root, files, ignore)}
  end

  @doc """
  Every finding in `sources`, in the order the files are read and then by line. Options:
  `root`, the repository root paths are resolved from; `exists?`, whether a path is
  there (`File.exists?/1`); `elsewhere?`, whether a path that is not there is one the
  repository has under another directory, or hides (`sources/1`'s; none by default);
  `executable?`, whether a program is on the `PATH` a session's commands run with.
  """
  @spec findings([source()], keyword()) :: [finding()]
  def findings(sources, opts \\ []) do
    root = Keyword.get(opts, :root)

    probes = %{
      exists?: Keyword.get(opts, :exists?, &File.exists?/1),
      elsewhere?: Keyword.get(opts, :elsewhere?, fn _path -> false end)
    }

    executable? = Keyword.get_lazy(opts, :executable?, fn -> on_path() end)

    docs = Enum.map(sources, &Map.put(&1, :text, Text.read(&1.content)))
    order = sources |> Enum.with_index() |> Map.new(fn {s, i} -> {s.path, i} end)

    (contradictions(docs, root) ++
       paths(docs, root, probes) ++
       commands(docs, executable?) ++ duplicates(docs, root))
    |> Enum.sort_by(&{order[&1.path], &1.line, rank(&1.kind)})
  end

  ## Contradictions

  defp contradictions(docs, root) do
    mentions =
      for doc <- docs,
          command <- doc.text.commands,
          {subject, ecosystem, tool} <- subject(command.command),
          do: %{
            scope: scope(doc),
            path: doc.path,
            line: command.line,
            text: command.text,
            about: {subject, ecosystem},
            tool: tool
          }

    scopes = docs |> Enum.map(&scope/1) |> Enum.uniq()

    for {scope, i} <- Enum.with_index(scopes),
        ours = Enum.filter(mentions, &(&1.scope == scope)),
        about <- ours |> Enum.map(& &1.about) |> Enum.uniq(),
        ours = Enum.filter(ours, &(&1.about == about)),
        theirs = around(scopes, i, mentions, about),
        theirs != [],
        disjoint?(ours, theirs) do
      [mine | _] = ours
      [other | _] = theirs
      {subject, _ecosystem} = about

      finding(
        mine,
        mine.line,
        :contradiction,
        "how to #{@subjects[subject]}: `#{mine.text}` here, `#{other.text}` in " <>
          "#{shown(other.path, root)}:#{other.line}"
      )
    end
  end

  defp subject(command) do
    Enum.find_value(@commands, :none, fn {regex, subject, ecosystem, tool} ->
      case Regex.run(regex, command) do
        nil -> nil
        captures -> {subject, ecosystem, tool(tool, captures)}
      end
    end)
    |> case do
      :none -> []
      found -> [found]
    end
  end

  defp tool(index, captures) when is_integer(index), do: Enum.at(captures, index)
  defp tool(tool, _captures), do: tool

  # The mentions of the nearest scope read before this one whose work holds this one's
  # and that names the same subject in the same ecosystem.
  defp around(scopes, i, mentions, about) do
    scope = Enum.at(scopes, i)

    scopes
    |> Enum.take(i)
    |> Enum.filter(&holds?(&1, scope))
    |> Enum.reverse()
    |> Enum.find_value([], fn outer ->
      case Enum.filter(mentions, &(&1.scope == outer and &1.about == about)) do
        [] -> nil
        found -> found
      end
    end)
  end

  defp disjoint?(ours, theirs) do
    MapSet.disjoint?(MapSet.new(ours, & &1.tool), MapSet.new(theirs, & &1.tool))
  end

  # A scope is its kind and, below the root, the directory it is for; a file and what it
  # imports are one. The person's own file applies everywhere, a file at the root (and
  # any scope the loader reads there) to the whole repository, a nested one to the work
  # under its directory.
  defp scope(%{scope: scope, where: where}), do: {scope, where}

  defp holds?({:user, _}, _scope), do: true
  defp holds?(_outer, {:user, _}), do: false

  defp holds?({:nested, outer}, {:nested, inner}),
    do: inner == outer or String.starts_with?(inner, outer <> "/")

  defp holds?({:nested, _outer}, _root), do: false
  defp holds?(_root, _scope), do: true

  ## Paths

  defp paths(docs, root, probes) do
    for doc <- docs, finding <- doc_paths(doc, root, probes), uniq: true, do: finding
  end

  # The person's own file is for every repository, so the paths it names are not this
  # one's to judge; an import the loader could not find is, wherever it was named.
  defp doc_paths(doc, root, probes) do
    named =
      if doc.scope == :user or root == nil do
        []
      else
        spans =
          for {n, span} <- doc.text.spans, path <- span_path(span), do: {n, path, path, :span}

        links =
          for {n, link} <- doc.text.links, path <- link_path(link), do: {n, link, path, :link}

        for {n, shown, path, how} <- spans ++ links,
            missing?(path, how, doc, root, probes),
            do: finding(doc, n, :path, "`#{shown}` does not exist")
      end

    imports =
      for %{import: spec, reason: :missing} <- doc.unfollowed,
          do:
            finding(
              doc,
              import_line(doc, spec),
              :path,
              "`@#{spec}` imports a file that does not exist"
            )

    named |> Enum.uniq_by(& &1.message) |> Kernel.++(imports)
  end

  # A span that reads as a path in this repository: one starting `./` or `../`, or one
  # with a slash that ends in one, names a file with a known extension, or starts with a
  # directory that is here. A bare file name (`an AGENTS.md`) is a kind of file as often
  # as it is one, and a word with a slash is a branch, a package or a media type as often
  # as a path, so neither is checked.
  defp span_path(span) do
    token =
      case String.split(span) do
        [one] -> one
        [first | _rest] -> if explicit?(first), do: first, else: nil
      end

    with token when is_binary(token) <- token,
         token = token |> String.replace(~r/(:\d+)+$/, "") |> String.replace(~r/#.*$/, ""),
         token =
           if(String.contains?(token, "/"), do: token, else: String.replace(token, "\\", "/")),
         false <- token == "" or token =~ ~r/:\/\/|^[\/~$%@-]|[*?\[\]{}<>|"'=,;()!:]|\.\.\./,
         true <- String.contains?(token, "/") do
      [token]
    else
      _ -> []
    end
  end

  defp explicit?(word) do
    word =~ ~r{^\.\.?[/\\]} or (String.contains?(word, "/") and extension?(word))
  end

  defp extension?(token) do
    case token |> String.trim_trailing("/") |> Path.basename() |> Path.extname() do
      "." <> ext -> ext in @extensions
      _ -> false
    end
  end

  # A link's target, unless it is a URL, an anchor or a placeholder; a leading `/` is the
  # repository root's, as a forge reads it.
  defp link_path(target) do
    target = target |> String.replace(~r/[#?].*$/, "")

    cond do
      target =~ ~r/^[a-z][a-z0-9+.-]*:/i or String.starts_with?(target, "//") -> []
      target == "" or target =~ ~r/[<>{}*$]/ -> []
      true -> [decode(target)]
    end
  end

  defp decode(target) do
    URI.decode(target)
  rescue
    ArgumentError -> target
  end

  # Missing from the directory the file is about, its own and the root alike, and not one
  # the repository has under another directory (a rule that names `client/link.ex` after
  # naming `lib/troupe/`) or hides (`_build/`). A path that leads out of the repository is
  # not judged at all. A link's target is a path whatever it looks like; a span's is not
  # when its first directory is not here and nothing else says it is one (`origin/main`,
  # `example.com/x.md`). The directory a file is about is its scope's: `web/` for
  # `web/.agents/AGENTS.md` and a rule in `web/.troupe/rules`, the file's own for the rest.
  defp missing?(path, how, doc, root, %{exists?: exists?, elsewhere?: elsewhere?}) do
    about = Map.get(doc, :directory) || Path.dirname(doc.path)

    {path, bases} =
      if String.starts_with?(path, "/"),
        do: {String.trim_leading(path, "/"), [root]},
        else: {path, Enum.uniq([about, Path.dirname(doc.path), root])}

    targets =
      for base <- bases, target = Path.expand(path, base), inside?(target, root), do: target

    targets != [] and not Enum.any?(targets, exists?) and not Enum.any?(targets, elsewhere?) and
      (how == :link or span_path?(path, bases, exists?))
  end

  defp span_path?(path, bases, exists?) do
    [first | _rest] = String.split(path, "/")

    cond do
      host?(first) -> false
      path =~ ~r{^\.\.?/} or String.ends_with?(path, "/") or extension?(path) -> true
      true -> Enum.any?(bases, &exists?.(Path.join(&1, first)))
    end
  end

  # `example.com/docs/x.md` is a page, not a path.
  defp host?(segment),
    do: segment =~ ~r/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/ and segment =~ ~r/[a-z]/

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp import_line(doc, spec) do
    Enum.find_value(doc.text.prose, 1, fn {n, text} ->
      if String.contains?(text, "@" <> spec), do: n
    end)
  end

  ## Commands

  # Once for each program in a file, where it is first named.
  defp commands(docs, executable?) do
    named = for doc <- docs, command <- doc.text.commands, command.check?, do: {doc, command}
    programs = named |> Enum.map(fn {_doc, c} -> c.program end) |> Enum.uniq()
    found = Map.new(programs, &{&1, executable?.(&1)})

    named
    |> Enum.reject(fn {_doc, command} -> found[command.program] end)
    |> Enum.uniq_by(fn {doc, command} -> {doc.path, command.program} end)
    |> Enum.map(fn {doc, command} ->
      message = "`#{command.program}` is not on the PATH (`#{command.text}`)"
      finding(doc, command.line, :command, message)
    end)
  end

  # The PATH a session's commands get (`Troupe.Reaper.child_env/0`): in a release, this
  # VM's less the release's own runtime, whose `erl` is no program of the repository's.
  defp on_path do
    path =
      case Reaper.child_env() do
        [{"PATH", path}] -> path
        _none -> System.get_env("PATH", "")
      end

    # Looked for as the session's own commands are found: on the PATH alone (Decision 846).
    fn program -> Executable.find(program, path: path) != nil end
  end

  ## Duplicates

  # Each rule's first appearance, in the order the files are read, stands; the same rule
  # in a later file is the finding, pointing back at it. Twice in one file is that file's
  # own business.
  defp duplicates(docs, root) do
    docs
    |> Enum.flat_map_reduce(%{}, fn doc, seen ->
      doc.text.rules
      |> Enum.uniq_by(&elem(&1, 1))
      |> Enum.flat_map_reduce(seen, &repeated(doc, &1, &2, root))
    end)
    |> elem(0)
  end

  defp repeated(doc, {n, rule}, seen, root) do
    case seen do
      %{^rule => {path, first}} when path != doc.path ->
        {[finding(doc, n, :duplicate, "the same rule as #{shown(path, root)}:#{first}")], seen}

      %{^rule => _same_file} ->
        {[], seen}

      _new ->
        {[], Map.put(seen, rule, {doc.path, n})}
    end
  end

  ## Reading

  # Every file under the workspace a session could work on, from the workspace: `.git` and
  # what `.gitignore` hides left out, a link not followed, and a directory with a `.git` of
  # its own, another repository, not entered.
  defp walk(workspace, rel, ignore) do
    dir = if rel == "", do: workspace, else: Path.join(workspace, rel)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(&if(rel == "", do: &1, else: rel <> "/" <> &1))
        |> Enum.reject(&(Path.basename(&1) == ".git" or Gitignore.ignored?(ignore, &1)))
        |> Enum.flat_map(&entry(workspace, &1, ignore))

      {:error, _reason} ->
        []
    end
  end

  defp entry(workspace, rel, ignore) do
    case File.lstat(Path.join(workspace, rel)) do
      {:ok, %File.Stat{type: :directory}} -> directory(workspace, rel, ignore)
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] -> [rel]
      _other -> []
    end
  end

  defp directory(workspace, rel, ignore) do
    if File.exists?(Path.join([workspace, rel, ".git"])),
      do: [],
      else: walk(workspace, rel, ignore)
  end

  # Whether the repository has a path, under any directory (`client/link.ex` is
  # `lib/troupe/client/link.ex`'s tail), or `.gitignore` hides it, as what a build makes.
  defp elsewhere(workspace, root, files, ignore) do
    base = Path.relative_to(workspace, root)
    prefix = if base in [".", workspace], do: "", else: base <> "/"

    known =
      for file <- files,
          segments = Path.split(prefix <> file),
          n <- 1..length(segments)//1,
          into: MapSet.new(),
          do: segments |> Enum.take(n) |> Path.join()

    fn path ->
      ignored?(path, workspace, ignore) or
        (inside?(path, root) and tail?(Path.relative_to(path, root), known))
    end
  end

  defp ignored?(path, workspace, ignore) do
    inside?(path, workspace) and path != workspace and
      Gitignore.ignored?(ignore, Path.relative_to(path, workspace))
  end

  defp tail?(relative, known),
    do: Enum.any?(known, &(&1 == relative or String.ends_with?(&1, "/" <> relative)))

  # The repository root as the loader found it: a root file's directory, or a nested
  # file's directory less the `where` it is named by; the workspace when there is neither.
  defp root(files, workspace) do
    Enum.find_value(files, workspace, fn
      %{scope: :root, directory: dir, imported_by: nil} ->
        dir

      %{scope: :nested, directory: dir, where: where, imported_by: nil} when is_binary(where) ->
        dir |> Path.split() |> Enum.drop(-length(Path.split(where))) |> Path.join()

      _other ->
        nil
    end)
  end

  ## Reporting

  defp finding(%{path: path}, line, kind, message),
    do: %{path: path, line: line, kind: kind, message: message}

  defp rank(kind),
    do:
      Enum.find_index(
        [:contradiction, :path, :command, :duplicate, :drift, :outdated],
        &(&1 == kind)
      )

  defp report(result, true) do
    %{workspace: workspace, root: root, sources: sources, findings: found} = result

    json = %{
      "workspace" => workspace,
      "root" => root,
      "files" =>
        Enum.map(
          sources,
          &%{"file" => shown(&1.path, root), "path" => &1.path, "scope" => to_string(&1.scope)}
        ),
      "onboarded" =>
        Enum.map(
          result.onboarded,
          &%{"file" => shown(&1.file, root), "path" => &1.file, "imported_from" => &1.from}
        ),
      "findings" =>
        Enum.map(found, fn f ->
          %{
            "file" => shown(f.path, root),
            "path" => f.path,
            "line" => f.line,
            "kind" => to_string(f.kind),
            "message" => f.message
          }
        end)
    }

    {Jason.encode!(json, pretty: true) <> "\n", status(found)}
  end

  defp report(%{sources: [], onboarded: []} = result, false),
    do: {"no instruction files reach a session in #{Paths.display(result.workspace)}\n", 0}

  defp report(%{findings: [], sources: sources, onboarded: onboarded, root: root} = result, false) do
    files =
      Enum.map_join(
        Enum.map(sources, & &1.path) ++ Enum.map(onboarded, & &1.file),
        ", ",
        &shown(&1, root)
      )

    {"no findings in #{counted(result)}: #{files}\n", 0}
  end

  defp report(%{findings: found, root: root} = result, false) do
    lines =
      Enum.map_join(found, "\n", &"#{shown(&1.path, root)}:#{&1.line}: #{&1.kind}: #{&1.message}")

    {lines <> "\n\n#{count(found, "finding")} in #{counted(result)}.\n", 1}
  end

  # The files checked: the instruction files, and the onboarded ones when there are any.
  defp counted(%{sources: sources, onboarded: []}), do: count(sources, "instruction file")

  defp counted(%{sources: sources, onboarded: onboarded}),
    do: "#{count(sources, "instruction file")} and #{count(onboarded, "onboarded file")}"

  defp unreadable(workspace, reason, json?) do
    message =
      "cannot read the workspace #{Paths.display(workspace)}: #{:file.format_error(reason)}"

    if json?,
      do:
        {Jason.encode!(%{"workspace" => workspace, "error" => message}, pretty: true) <> "\n", 2},
      else: {message <> "\n", 2}
  end

  defp status([]), do: 0
  defp status(_found), do: 1

  defp count([_one], noun), do: "1 #{noun}"
  defp count(list, noun), do: "#{length(list)} #{noun}s"

  # A file in the repository by its path from the root, as a forge and an editor name it;
  # the person's own, where it is.
  defp shown(path, root) when is_binary(root) do
    if inside?(path, root) and path != root,
      do: Path.relative_to(path, root),
      else: Paths.display(path)
  end

  defp shown(path, _root), do: Paths.display(path)
end
