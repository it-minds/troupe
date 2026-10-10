defmodule Troupe.Instructions do
  @moduledoc """
  The instruction files a repository carries for coding agents, read into every agent's
  system prompt (Decisions 706, 798, 806 and 828).

  `AGENTS.md` is the file the tools settled on, and a repository that has one has told
  agents how to work in it. Troupe reads it the way the others do: the person's own
  `<config>/AGENTS.md` first, then the repository root's, then one in each directory on
  the way from the root to where the session works, and Troupe's own brief
  (`.troupe/memory.md`) last. Where the session works is its workspace and the directory
  of every file its conversation has read, edited or written (`focus/1`), so a
  `frontend/AGENTS.md` applies once the agent has opened something under `frontend/`.
  Every one applies; where two disagree the nearer wins, which is why the nearer comes
  later in the prompt.

  Other tools' files are not read (Decision 828): `troupe onboard` brings what they say
  into Troupe's own files once. A `CLAUDE.md` or a `GEMINI.md` in one of those
  directories, Copilot's `.github/copilot-instructions.md` at the root, and Cursor's
  `.cursorrules` and `.cursor/rules/*.mdc` are each listed as skipped, saying so, so
  nobody debugs a file that was never loaded. A Copilot file below the root never counted
  (Decision 806), and says that instead. A file that is there and cannot be read is
  listed too, with why.

  An `.agents/AGENTS.md` in the repository root, or in a directory on the way to where
  the session works, is that directory's too (Decision 822): read right before the
  directory's own file, in its scope, so where the two disagree the directory's own wins.
  The person's own directory has none.

  A file may import another with `@path/to/file.md`, as Claude Code's do: resolved from
  the importing file's directory, followed five deep, each file read once, and never
  from outside the repository (or, for the person's own file, the config directory). An
  import is read right after the file that names it and belongs to that file's scope;
  one that is not followed is named on its importer, with why. The files found in the
  directories are held to the same edge: one that is really elsewhere, through a link,
  is listed as `outside` and not read.

  Troupe's own rules are read as Cursor reads its rules (Decisions 809 and 828): each
  `.troupe/rules/*.md` in the repository root, and in a directory on the way to where the
  session works, comes after that directory's instruction file, its front matter saying
  when it applies. A rule with `alwaysApply: true` is in every prompt; one with `globs`
  joins once the session has worked on a file one of them matches, the globs taken from
  the directory that holds `.troupe`; one with only a `description` is listed in the
  prompt by it, for the agent to read when it applies, its body not joined; one with none
  of them is not joined. Each says why it applies (`applies`) or why not (`reason`), and
  is held to the repository's edge as every other file is. A rule's `@` is not followed
  as an import.

  Read from disk when asked, which the agent does as a turn begins, so an edit takes
  effect on the next turn. What was read is summed up in a digest, and the agent writes
  an `instructions_loaded` event when the digest changes and nothing while it does not:
  that is the cache, and what it buys is a log that says which files each turn was read
  from without saying so every turn.

  The files share one character budget, `instructions_max_chars`, allotted scope by
  scope, a file and what it imports being one: the nearest is kept whole first; a file
  the remainder cannot hold is cut, or left out, and the prompt, the event and
  `context.get` all say so. The brief keeps its own budget (`memory_max_chars`).
  Nothing reaches the prompt from a file without appearing in `provenance/1`.

  Pure but for the reads. Nothing here writes.
  """

  alias Troupe.{Config, Memory, Paths, Workspace}
  alias Troupe.LLM.{Message, ToolUse}
  alias Troupe.Session.Memory, as: Brief

  @agents "AGENTS.md"
  @dot_agents ".agents/AGENTS.md"
  @budget_reason "left out: the budget was spent on nearer files"
  @default_max_chars 16_000

  # Other tools' names for the same file, read until Decision 828 and now listed, when one
  # is found, as waiting for `troupe onboard`. Copilot's counts at the root only, and below
  # it says so (Decision 806).
  @retired ["CLAUDE.md", "GEMINI.md"]
  @copilot ".github/copilot-instructions.md"
  @onboard_reason "not read: run troupe onboard"
  @copilot_reason "not read: Copilot's file counts only at the root"

  # Troupe's own rules; and Cursor's, and the single file Cursor read before them at the
  # repository root, no longer read (Decision 828).
  @rules_dir ".troupe/rules"
  @cursor_rules ".cursor/rules"
  @legacy_rules ".cursorrules"
  @requested_reason "requested by description only: listed in the prompt, not joined"
  @manual_reason "not joined: no alwaysApply, globs or description"

  # How many imports deep a file may reach: an instruction file's own imports are the
  # first, as Claude Code counts its hops.
  @max_depth 5

  # The calls whose `path` is a file the agent is working on.
  @file_tools ["read_file", "edit_file", "write_file"]

  # `@` at the start of a line or after a space, then the path up to the next space.
  @import ~r/(?:^|(?<=\s))@(\S+)/u

  @preamble """
  What the people who work in this repository wrote for coding agents, read from disk
  as this turn began. Every file applies. A file from a directory below the root is about
  the work under that directory, and where two disagree, the one nearer the file you are
  working on wins; nearer files come later here.
  """

  @typedoc """
  One scope, in the order they are read: the person's own file, the repository root's,
  a directory between the root and where the session works, and the brief.
  """
  @type scope :: :user | :root | :nested | :brief

  @typedoc """
  One file in force. `size` is its bytes on disk; `chars` what reached the prompt, which
  counts against `budget`; `status` is `whole`, `trimmed` (`trimmed` characters cut),
  `dropped`, `outside` (a file that is really outside the repository, not read),
  `unreadable` (one that is there and could not be read) or `skipped` (another tool's
  file, or a Copilot file below the root, not read) for an instruction file, and for the
  brief what `Troupe.Session.Memory` says of it, or `outside` too. `reason` says in words
  why a file was left out (`nil` for one read): what `context.get` answers and `/context`
  prints. `skipped` is always empty now that no other name stands for `AGENTS.md`
  (Decision 828), kept for the clients that read it; `where` is the directory's path from
  the repository root, for the prompt to name it by. `imported_by` is the file whose `@`
  import brought this one in, and `unfollowed` the imports this file names that were not
  read, with why: `missing`, `outside` the directory imports may come from, `depth` past
  five, or a `cycle`.

  A rule has its front matter in `rule` (`nil` for every other file) and a
  `status` of its own while it is not joined: `inactive` (a `globs` rule no file worked
  on matches yet, or one with nothing that says when it applies), or `listed` (one with
  only a `description`, which is its `text`, listed in the prompt by it). One that is
  joined says why in `applies` (`nil` for every other file and every rule not joined).
  """
  @type file :: %{
          scope: scope(),
          path: Path.t(),
          directory: Path.t(),
          where: String.t() | nil,
          size: non_neg_integer(),
          chars: non_neg_integer(),
          budget: pos_integer(),
          hash: String.t() | nil,
          status: atom(),
          reason: String.t() | nil,
          trimmed: non_neg_integer(),
          skipped: [String.t()],
          imported_by: Path.t() | nil,
          unfollowed: [%{import: String.t(), reason: :missing | :outside | :depth | :cycle}],
          rule: rule() | nil,
          applies: String.t() | nil,
          text: String.t()
        }

  @typedoc """
  A rule's front matter, and when it applies: `always` (`alwaysApply: true`), `globs`,
  `requested` (only a `description`) or `manual` (none of them). `matched` is the file
  worked on that a glob matched, from the directory that holds `.troupe`, while the rule
  is joined by it.
  """
  @type rule :: %{
          apply: :always | :globs | :requested | :manual,
          globs: [String.t()],
          description: String.t() | nil,
          matched: String.t() | nil
        }

  @type t :: %{
          files: [file()],
          searched: [Path.t()],
          budget: pos_integer(),
          used: non_neg_integer(),
          digest: String.t()
        }

  @doc """
  The files a conversation has read, edited or written, as its calls named them, each
  once: where the agent has been working, for `load/3` to read the instruction files on
  the way to. A compaction's summary names no calls, so what it folded away is no longer
  worked in.
  """
  @spec focus([Message.t()]) :: [String.t()]
  def focus(conversation) do
    for %Message{role: :assistant} = message <- conversation,
        %ToolUse{name: name, input: %{"path" => path}} <- Message.tool_uses(message),
        name in @file_tools and is_binary(path) and path != "",
        uniq: true,
        do: path
  end

  @doc """
  Reads every instruction file in force for a workspace, farthest scope first, and the
  brief after them. `focus` is the files the session is working on (`focus/1`), relative
  to the workspace or absolute: the directories on the way to each are read as well as
  those on the way to the workspace, and they are what a rule's globs match.
  `searched` is every directory looked in, whether or not it had one.
  """
  @spec load(Path.t(), Config.t() | nil, [Path.t()]) :: t()
  def load(workspace, config, focus \\ []) do
    workspace = Path.expand(workspace)
    budget = max_chars(config)
    {root, directories} = directories(workspace, focus)
    worked_on = Enum.map(focus, &Path.expand(&1, workspace))

    bounds = %{user: key(Paths.config_dir()), repository: key(root)}
    found = Enum.flat_map(directories, &(find(&1, bounds) ++ rules(&1, bounds, worked_on)))

    # A file skipped, or a rule not joined, is not in the prompt, so an import may still
    # bring it in.
    seen =
      for file <- found,
          not match?(
            %{status: status} when status in [:skipped, :unreadable, :inactive, :listed],
            file
          ),
          into: MapSet.new(),
          do: key(file.path)

    files =
      found
      |> Enum.map_reduce(seen, &imports(&1, &2, bounds))
      |> elem(0)
      |> allot(budget)
      |> Kernel.++([brief(workspace, config)])

    used = files |> Enum.reject(&(&1.scope == :brief)) |> Enum.map(& &1.chars) |> Enum.sum()

    %{
      files: files,
      searched: Enum.map(directories, &elem(&1, 1)),
      budget: budget,
      used: used,
      digest: digest(files)
    }
  end

  @doc """
  The system prompt's `# Instruction files` block, then the brief's own block, or `""`
  when there is neither.
  """
  @spec to_prompt(t() | nil) :: String.t()
  def to_prompt(nil), do: ""

  def to_prompt(%{files: files}) do
    {briefs, instructions} = Enum.split_with(files, &(&1.scope == :brief))

    blocks =
      instructions
      |> Enum.reject(&(&1.text == "" and &1.status != :dropped))
      |> Enum.map(&block/1)

    section =
      case blocks do
        [] -> ""
        _ -> "# Instruction files\n#{@preamble}\n" <> Enum.join(blocks, "\n\n")
      end

    [section | Enum.map(briefs, & &1.text)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  What `context.get` answers and the `instructions_loaded` event carries: every file, in
  the order it is read, with its scope, size, the characters that reached the prompt,
  the budget they count against and its share of it, and for a rule its front matter
  (`rule`) and why it applies (`applies`) or not (`reason`). Wire-shaped, string keys.
  """
  @spec provenance(t()) :: map()
  def provenance(%{} = loaded) do
    %{
      "budget" => loaded.budget,
      "used" => loaded.used,
      "searched" => loaded.searched,
      "files" => Enum.map(loaded.files, &file_json/1)
    }
  end

  @doc "`provenance/1` of a fresh read, as the next turn would read it."
  @spec provenance(Path.t(), Config.t() | nil, [Path.t()]) :: map()
  def provenance(workspace, config, focus \\ []),
    do: workspace |> load(config, focus) |> provenance()

  ## Where to look

  # The person's own directory, the repository root, then every directory below it on
  # the way to the workspace or to a file the session works on, a parent before its
  # children. Without a `.git` the workspace is the root; a `.git` file is a worktree's,
  # which reads its own checkout's files.
  defp directories(workspace, focus) do
    root = repository_root(workspace)

    nested =
      [workspace | Enum.map(focus, &Path.dirname(Path.expand(&1, workspace)))]
      |> Enum.flat_map(&below(&1, root))
      |> Enum.uniq()
      |> Enum.sort_by(&{length(&1), &1})
      |> Enum.map(fn rel -> {:nested, Path.join([root | rel]), Enum.join(rel, "/")} end)

    directories =
      [{:user, Path.expand(Paths.config_dir()), nil}, {:root, root, nil} | nested]
      |> Enum.uniq_by(&elem(&1, 1))

    {root, directories}
  end

  # Each directory from just below the root down to `dir`, as its segments from the root;
  # none for the root itself or for a directory outside it.
  defp below(dir, root) do
    case Path.relative_to(dir, root) do
      "." ->
        []

      ^dir ->
        []

      relative ->
        segments = Path.split(relative)
        for n <- 1..length(segments), do: Enum.take(segments, n)
    end
  end

  @doc """
  The repository a workspace is in, as the instruction files are read up to it: the
  nearest directory with a `.git` (a worktree's `.git` file counts), or the workspace
  itself without one. `Troupe.Skills.Local` reads `.agents/skills` up to the same root.
  """
  @spec repository_root(Path.t()) :: Path.t()
  def repository_root(workspace) do
    workspace
    |> ancestors()
    |> Enum.find(workspace, &File.exists?(Path.join(&1, ".git")))
  end

  defp ancestors(dir) do
    case Path.dirname(dir) do
      ^dir -> [dir]
      parent -> [dir | ancestors(parent)]
    end
  end

  ## Reading

  # A directory's `AGENTS.md`, after its `.agents/AGENTS.md`, and then the other tools'
  # files found beside it, listed and not read (Decision 828). An `.agents` directory,
  # walked when the session works under it, has no file of its own: its `AGENTS.md` is
  # its parent's `.agents/AGENTS.md`, read there.
  defp find({scope, dir, where}, bounds) do
    fields = %{scope: scope, where: where}

    own =
      if Path.basename(dir) != ".agents" and File.regular?(Path.join(dir, @agents)),
        do: read(dir, @agents, fields, bound(scope, bounds)),
        else: []

    dot_agents(scope, dir, fields, bounds) ++ own ++ retired(scope, dir, fields)
  end

  # A directory's `.agents/AGENTS.md`, before its own file and in its scope, so that file
  # is the nearer of the two (Decision 822); confined as any found file is. Not in the
  # person's own directory, whose file is `<config>/AGENTS.md`.
  defp dot_agents(:user, _dir, _fields, _bounds), do: []

  defp dot_agents(scope, dir, fields, bounds) do
    if File.regular?(Path.join(dir, @dot_agents)),
      do: read(dir, @dot_agents, fields, bound(scope, bounds)),
      else: []
  end

  # Another tool's file in this directory: listed with nothing of it read, not even where
  # a link points, saying `troupe onboard` brings it in. Copilot's below the root was never
  # read, and keeps saying why (Decision 806).
  defp retired(scope, dir, fields) do
    copilot = if scope == :root, do: @onboard_reason, else: @copilot_reason
    names = for(name <- @retired, do: {name, @onboard_reason}) ++ [{@copilot, copilot}]

    for {name, reason} <- names,
        path = Path.join(dir, name),
        File.regular?(path),
        do: unread(path, dir, fields, :skipped, reason)
  end

  # A file found in a directory is confined as an import is: one that is really somewhere
  # outside the repository (or, for the person's own, the config directory), a link out
  # or a directory linked out, is not read, and is listed as `outside` with nothing of it
  # in the prompt, not even its size. One that cannot be read is listed with why.
  defp read(dir, name, fields, bound) do
    path = Path.join(dir, name)

    if under?(key(path), bound) do
      case entry(path, fields) do
        {:ok, file} -> [%{file | directory: dir}]
        {:error, reason} -> [unreadable(path, dir, fields, reason)]
      end
    else
      [unread(path, dir, fields, :outside, outside_reason(fields.scope))]
    end
  end

  defp unreadable(path, dir, fields, reason),
    do: unread(path, dir, fields, :unreadable, "not read: #{:file.format_error(reason)}")

  # A file found and not read: listed with nothing of it in the prompt, not even its size,
  # and with why in words.
  defp unread(path, dir, fields, status, reason) do
    Map.merge(
      %{
        path: path,
        directory: dir,
        size: 0,
        hash: nil,
        skipped: [],
        imported_by: nil,
        unfollowed: [],
        rule: nil,
        applies: nil,
        text: "",
        status: status,
        reason: reason
      },
      fields
    )
  end

  defp outside_reason(:user), do: "not read: outside the config directory"
  defp outside_reason(_scope), do: "not read: outside the repository"

  defp bound(:user, bounds), do: bounds.user
  defp bound(_scope, bounds), do: bounds.repository

  defp entry(path, fields) do
    with {:ok, content} <- File.read(path) do
      {:ok,
       Map.merge(
         %{
           path: path,
           directory: Path.dirname(path),
           size: byte_size(content),
           hash: hash(content),
           reason: nil,
           skipped: [],
           imported_by: nil,
           unfollowed: [],
           rule: nil,
           applies: nil,
           text: content |> String.replace("\r\n", "\n") |> String.trim()
         },
         fields
       )}
    end
  end

  ## Rules

  # A directory's `.troupe/rules/*.md`, in name order, after its instruction file
  # (Decisions 809 and 828), then Cursor's rules found there, listed and not read: the
  # legacy `.cursorrules` at the repository root and each `.cursor/rules/*.mdc`. Not in the
  # person's own directory, whose own file is `<config>/AGENTS.md`.
  defp rules({:user, _dir, _where}, _bounds, _worked_on), do: []

  defp rules({scope, dir, where}, bounds, worked_on) do
    fields = %{scope: scope, where: where}
    bound = bounds.repository
    legacy = Path.join(dir, @legacy_rules)

    legacy =
      if scope == :root and File.regular?(legacy),
        do: [unread(legacy, dir, fields, :skipped, @onboard_reason)],
        else: []

    in_rules_dir(Path.join(dir, @rules_dir), ".md", dir, fields, bound, fn path ->
      rule(path, dir, fields, bound, worked_on)
    end) ++
      legacy ++
      in_rules_dir(Path.join(dir, @cursor_rules), ".mdc", dir, fields, bound, fn path ->
        [unread(path, dir, fields, :skipped, @onboard_reason)]
      end)
  end

  # Each file in a rules directory with the extension, in name order, through `each`. One
  # that is really outside the repository is listed once, as `outside`, and not looked
  # into, so not even the names of what is there reach the log.
  defp in_rules_dir(rules_dir, extension, dir, fields, bound, each) do
    cond do
      not File.dir?(rules_dir) ->
        []

      not under?(key(rules_dir), bound) ->
        [unread(rules_dir, dir, fields, :outside, outside_reason(fields.scope))]

      true ->
        rules_dir
        |> File.ls()
        |> case do
          {:ok, names} -> names
          {:error, _reason} -> []
        end
        |> Enum.filter(&(String.downcase(Path.extname(&1)) == extension))
        |> Enum.sort()
        |> Enum.map(&Path.join(rules_dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(each)
    end
  end

  # One rule, confined as a found file is, then read and judged against the files the
  # session worked on. A rule's globs are taken from `dir`, the directory that holds its
  # `.troupe` (the repository root's, as Cursor had it for `.cursor`).
  defp rule(path, dir, fields, bound, worked_on) do
    if under?(key(path), bound) do
      case entry(path, fields) do
        {:ok, file} ->
          {rule, body} = front_matter(file)
          [judge(%{file | directory: dir}, rule, body, worked_on)]

        {:error, reason} ->
          [unreadable(path, dir, fields, reason)]
      end
    else
      [unread(path, dir, fields, :outside, outside_reason(fields.scope))]
    end
  end

  defp judge(file, %{apply: :always} = rule, body, _worked_on),
    do: %{file | text: body, rule: rule, applies: "always applied"}

  defp judge(file, %{apply: :globs, globs: globs} = rule, body, worked_on) do
    case matched(globs, file.directory, worked_on) do
      {relative, glob} ->
        applies = "applied: #{shown(relative, file)} matches #{glob}#{under(file)}"
        %{file | text: body, rule: %{rule | matched: relative}, applies: applies}

      nil ->
        reason =
          "applies when a file#{under(file)} matching #{Enum.join(globs, " or ")} " <>
            "is read or edited"

        Map.merge(file, %{text: "", rule: rule, status: :inactive, reason: reason})
    end
  end

  # Listed by its description, the line the prompt shows, and not joined: Cursor's agent
  # asks for such a rule when the description fits the work, and here the agent reads it.
  defp judge(file, %{apply: :requested, description: description} = rule, _body, _worked_on) do
    line = description |> String.split() |> Enum.join(" ")
    Map.merge(file, %{text: line, rule: rule, status: :listed, reason: @requested_reason})
  end

  defp judge(file, rule, _body, _worked_on),
    do: Map.merge(file, %{text: "", rule: rule, status: :inactive, reason: @manual_reason})

  defp under(%{scope: :nested, where: where}), do: " under #{where}/"
  defp under(_file), do: ""

  defp shown(relative, %{scope: :nested, where: where}), do: "#{where}/#{relative}"
  defp shown(relative, _file), do: relative

  # The first file worked on that one of the globs matches, as its path from `base`, and
  # that glob; `nil` when none does.
  defp matched(globs, base, worked_on) do
    patterns = for glob <- globs, {:ok, regex} <- [glob_regex(glob)], do: {glob, regex}

    Enum.find_value(worked_on, fn path ->
      relative = from_base(path, base)
      relative && first_glob(patterns, relative)
    end)
  end

  defp first_glob(patterns, relative) do
    case Enum.find(patterns, fn {_glob, regex} -> Regex.match?(regex, relative) end) do
      {glob, _regex} -> {relative, glob}
      nil -> nil
    end
  end

  defp from_base(path, base) do
    case Path.relative_to(path, base) do
      ^path -> nil
      "." -> nil
      relative -> relative
    end
  end

  # A glob as Cursor writes one: `**` crosses directories, `*` and `?` do not, `{a,b}` is
  # either. One without a `/` matches a file's name in any directory (`*.tsx`), one with a
  # `/` matches the path from `base`; one ending in `/` everything under it. A glob that
  # does not compile matches nothing. Without case on Windows, as its paths compare.
  defp glob_regex(glob) do
    glob = glob |> String.trim_leading("./") |> String.trim_leading("/")
    glob = if String.ends_with?(glob, "/"), do: glob <> "**", else: glob
    prefix = if String.contains?(glob, "/"), do: "\\A", else: "\\A(?:.*/)?"
    options = if match?({:win32, _}, :os.type()), do: "iu", else: "u"
    Regex.compile(prefix <> translate(glob, 0) <> "\\z", options)
  end

  defp translate("", _depth), do: ""
  defp translate("**/" <> rest, depth), do: "(?:.*/)?" <> translate(rest, depth)
  defp translate("**" <> rest, depth), do: ".*" <> translate(rest, depth)
  defp translate("*" <> rest, depth), do: "[^/]*" <> translate(rest, depth)
  defp translate("?" <> rest, depth), do: "[^/]" <> translate(rest, depth)
  defp translate("{" <> rest, depth), do: "(?:" <> translate(rest, depth + 1)
  defp translate("}" <> rest, depth) when depth > 0, do: ")" <> translate(rest, depth - 1)
  defp translate("," <> rest, depth) when depth > 0, do: "|" <> translate(rest, depth)

  defp translate(<<char::utf8, rest::binary>>, depth),
    do: Regex.escape(<<char::utf8>>) <> translate(rest, depth)

  # A rule's front matter and its body. The front matter is read a line per key, as Cursor
  # writes it in an `.mdc` and YAML would not always read it (`globs: *.ts` is an alias to
  # YAML): `globs` a comma-separated string, a `[...]` list or a list of `- ` lines.
  defp front_matter(%{text: text}) do
    text = String.trim_leading(text, "\uFEFF")
    text |> String.split("\n") |> split_front_matter(text)
  end

  defp split_front_matter([first | rest], text) do
    with "---" <- String.trim(first),
         {front, [_close | body]} <- Enum.split_while(rest, &(String.trim(&1) != "---")) do
      fields = keys(front)
      always = String.downcase(scalar(fields["alwaysApply"])) == "true"

      description =
        case scalar(fields["description"]) do
          "" -> nil
          description -> description
        end

      rule = rule_from(always, globs(fields["globs"]), description)
      {rule, body |> Enum.join("\n") |> String.trim()}
    else
      _no_front_matter -> {rule_from(false, [], nil), text}
    end
  end

  defp rule_from(always, globs, description) do
    apply =
      cond do
        always -> :always
        globs != [] -> :globs
        description != nil -> :requested
        true -> :manual
      end

    %{apply: apply, globs: globs, description: description, matched: nil}
  end

  # Each `key:` line and the lines after it that are indented or a list's `-`, trimmed.
  defp keys(lines) do
    lines
    |> Enum.reduce({%{}, nil}, fn line, {fields, key} ->
      case Regex.run(~r/^([A-Za-z][\w-]*)\s*:\s*(.*)$/, line) do
        [_line, name, value] -> {Map.put(fields, name, [String.trim(value)]), name}
        nil when key != nil -> {continue(fields, key, line), key}
        nil -> {fields, nil}
      end
    end)
    |> elem(0)
  end

  defp continue(fields, key, line) do
    if line =~ ~r/^(\s+\S|-)/,
      do: Map.update!(fields, key, &(&1 ++ [String.trim(line)])),
      else: fields
  end

  defp scalar(nil), do: ""

  defp scalar([block | lines]) when block in ["|", ">", "|-", ">-"],
    do: lines |> Enum.join(" ") |> unquote_value()

  defp scalar(lines), do: lines |> Enum.join(" ") |> unquote_value()

  defp globs(nil), do: []

  defp globs(["" | lines]) do
    for "-" <> item <- lines, item = unquote_value(item), item != "", do: item
  end

  defp globs(lines) do
    value = lines |> Enum.join(" ") |> String.trim()

    value =
      if String.starts_with?(value, "[") and String.ends_with?(value, "]"),
        do: String.slice(value, 1..-2//1),
        else: value

    for item <- split_globs(value), item = unquote_value(item), item != "", do: item
  end

  # On the commas outside braces, so `**/*.{ts,tsx}` stays one glob.
  defp split_globs(value) do
    {items, current, _depth} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {items, current, 0} -> {[current | items], "", 0}
        "{", {items, current, depth} -> {items, current <> "{", depth + 1}
        "}", {items, current, depth} -> {items, current <> "}", max(depth - 1, 0)}
        char, {items, current, depth} -> {items, current <> char, depth}
      end)

    Enum.reverse([current | items])
  end

  defp unquote_value(value) do
    value = String.trim(value)

    case value do
      <<q, rest::binary>> when q in [?", ?'] and byte_size(rest) > 0 ->
        if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: value

      _other ->
        value
    end
  end

  ## Imports

  # A file and what it imports, depth first, each import right after the file that names
  # it. `seen` is every file already in the prompt, so each is read once; the person's
  # own file imports from the config directory, every other from the repository. A
  # rule's `@` names a file to attach, as Cursor took it, not an import, and is left alone.
  defp imports(%{rule: %{}} = file, seen, _bounds), do: {[file], seen}

  defp imports(file, seen, bounds),
    do: follow(file, [key(file.path)], seen, bound(file.scope, bounds), 1)

  defp follow(file, stack, seen, bound, depth) do
    {imported, unfollowed, seen} =
      file.text
      |> import_specs()
      |> Enum.reduce({[], [], seen}, fn spec, {imported, unfollowed, seen} ->
        case take(spec, file, stack, seen, bound, depth) do
          {:read, child} ->
            key = key(child.path)
            {files, seen} = follow(child, [key | stack], MapSet.put(seen, key), bound, depth + 1)
            {Enum.reverse(files, imported), unfollowed, seen}

          {:refuse, reason} ->
            {imported, [%{import: spec, reason: reason} | unfollowed], seen}

          :ignore ->
            {imported, unfollowed, seen}
        end
      end)

    {[%{file | unfollowed: Enum.reverse(unfollowed)} | Enum.reverse(imported)], seen}
  end

  # Whether one import is read, refused with a reason, or passed over: a file already in
  # the prompt is not read twice, and a word after an `@` that names no file and does not
  # look like a path is a mention, not a missing file. Outside is judged first, so nothing
  # says whether a file there exists.
  defp take(spec, importer, stack, seen, bound, depth) do
    path = Path.expand(spec, Path.dirname(importer.path))
    key = key(path)

    cond do
      not under?(key, bound) -> {:refuse, :outside}
      not File.regular?(path) -> missing(spec)
      key in stack -> {:refuse, :cycle}
      MapSet.member?(seen, key) -> :ignore
      depth > @max_depth -> {:refuse, :depth}
      true -> read_import(path, spec, importer)
    end
  end

  defp read_import(path, spec, importer) do
    fields = %{scope: importer.scope, where: importer.where, imported_by: importer.path}

    case entry(path, fields) do
      {:ok, child} -> {:read, child}
      {:error, _reason} -> missing(spec)
    end
  end

  defp missing(spec) do
    if String.contains?(spec, ["/", "."]), do: {:refuse, :missing}, else: :ignore
  end

  # The `@` imports one file names, in order, each once: not inside a code span or a
  # fenced block, and without the punctuation a sentence puts after a path.
  defp import_specs(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {specs, fenced} ->
      cond do
        line =~ ~r/^\s{0,3}(```|~~~)/ -> {specs, not fenced}
        fenced -> {specs, fenced}
        true -> {Enum.reverse(line_specs(line), specs), fenced}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp line_specs(line) do
    stripped = String.replace(line, ~r/`[^`]*`/, "")

    for [spec] <- Regex.scan(@import, stripped, capture: :all_but_first),
        spec = String.replace(spec, ~r/[.,;:!?)\]}"']+$/, ""),
        spec != "",
        do: spec
  end

  defp under?(key, bound), do: key == bound or String.starts_with?(key, bound <> "/")

  # The form two paths are told apart in: where each really is, symlinks followed, as the
  # platform compares them. So a link cannot carry an import out of the repository, and
  # one file under two names is still read once.
  defp key(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> Workspace.compare_key(real)
      {:error, _reason} -> Workspace.compare_key(Path.expand(path))
    end
  end

  ## The budget

  # Scope by scope, the nearest first: each takes what it needs from what is left, so the
  # farthest is the one cut or left out when the files together outrun the budget. Within
  # a scope the file comes before what it imports. What is left is what was not taken, so
  # a rule's description left out whole leaves its room to the files farther out.
  defp allot(scopes, budget) do
    {allotted, _left} =
      scopes
      |> Enum.reverse()
      |> Enum.map_reduce(budget, fn files, left ->
        Enum.map_reduce(files, left, fn file, left ->
          fitted = fit(file, budget, left)
          {fitted, left - fitted.chars}
        end)
      end)

    allotted |> Enum.reverse() |> Enum.concat()
  end

  defp fit(%{status: status} = file, budget, _left)
       when status in [:outside, :unreadable, :skipped, :inactive],
       do: Map.merge(file, %{chars: 0, trimmed: 0, budget: budget})

  # A rule listed by its description is listed whole or not at all.
  defp fit(%{status: :listed} = file, budget, left) do
    case String.length(file.text) do
      chars when chars <= left ->
        Map.merge(file, %{chars: chars, trimmed: 0, budget: budget})

      chars ->
        Map.merge(file, %{
          chars: 0,
          trimmed: chars,
          status: :dropped,
          reason: @budget_reason,
          budget: budget,
          text: ""
        })
    end
  end

  defp fit(file, budget, left) do
    chars = String.length(file.text)

    cond do
      chars <= left ->
        Map.merge(file, %{chars: chars, trimmed: 0, status: :whole, budget: budget})

      left == 0 ->
        Map.merge(file, %{
          chars: 0,
          trimmed: chars,
          status: :dropped,
          reason: @budget_reason,
          budget: budget,
          text: ""
        })

      true ->
        Map.merge(file, %{
          chars: left,
          trimmed: chars - left,
          status: :trimmed,
          budget: budget,
          text: String.slice(file.text, 0, left)
        })
    end
  end

  # The brief as `Troupe.Session.Memory` puts it in the prompt, with its own budget and
  # status: listed here so one table says everything a prompt was read from. Its path is
  # asked for once, since that is a `git` call and this runs at every turn. A brief that is
  # a link out of its repository is `outside`, as an instruction file is, and not read.
  defp brief(workspace, config) do
    path = Brief.path(workspace)
    max = memory_max_chars(config)

    if Brief.inside?(path) do
      brief(path, max, config)
    else
      fields = %{scope: :brief, where: nil, chars: 0, budget: max, trimmed: 0}
      unread(path, Path.dirname(path), fields, :outside, outside_reason(:brief))
    end
  end

  defp brief(path, max, config) do
    {size, hash} = stat(path)
    brief = Brief.read(path)
    text = Brief.to_prompt(brief, config)
    overflow = Memory.overflow(brief, max_chars: max)

    status =
      cond do
        not memory_enabled?(config) -> :disabled
        size == nil -> :absent
        overflow > 0 -> :trimmed
        true -> :whole
      end

    %{
      scope: :brief,
      path: path,
      directory: Path.dirname(path),
      where: nil,
      size: size || 0,
      chars: String.length(text),
      budget: max,
      hash: hash,
      status: status,
      reason: nil,
      trimmed: if(status == :trimmed, do: overflow, else: 0),
      skipped: [],
      imported_by: nil,
      unfollowed: [],
      rule: nil,
      applies: nil,
      text: text
    }
  end

  defp stat(path) do
    case File.read(path) do
      {:ok, content} -> {byte_size(content), hash(content)}
      {:error, _reason} -> {nil, nil}
    end
  end

  defp hash(content), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  # What the prompt was read from, as one string: the paths, what each held and how much
  # of it got in. Two turns with the same digest read the same files to the same effect.
  defp digest(files) do
    files
    |> Enum.map_join("\n", fn f ->
      unfollowed = Enum.map(f.unfollowed, &"#{&1.import}:#{&1.reason}")
      fields = [f.path, f.hash || "", f.status, f.chars, f.trimmed, f.imported_by || ""]
      Enum.join(fields ++ [f.applies || ""] ++ f.skipped ++ unfollowed, "\t")
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  ## Rendering

  defp block(%{status: :dropped} = f) do
    "Contents of #{f.path} (#{label(f)}): left out, the instructions budget of " <>
      "#{f.budget} characters was spent on nearer files."
  end

  defp block(%{status: :trimmed} = f) do
    "Contents of #{f.path} (#{label(f)}):\n#{f.text}\n\n(cut here: #{f.trimmed} more " <>
      "characters of this file did not fit the instructions budget)"
  end

  # A rule with only a description: the agent reads the file when the description fits.
  defp block(%{status: :listed} = f),
    do: "Rule #{f.path} (#{scope_label(f)}), to read when it applies: #{f.text}"

  defp block(f), do: "Contents of #{f.path} (#{label(f)}):\n#{f.text}"

  defp label(%{imported_by: by} = f) when is_binary(by),
    do: "#{scope_label(f)}, imported by #{by}"

  defp label(%{rule: %{apply: :always}} = f), do: "#{scope_label(f)}, a rule that always applies"

  defp label(%{rule: %{apply: :globs, globs: globs}} = f),
    do: "#{scope_label(f)}, a rule for files matching #{Enum.join(globs, " or ")}"

  defp label(f), do: scope_label(f)

  defp scope_label(%{scope: :user}), do: "your own, every repository"
  defp scope_label(%{scope: :root}), do: "repository root"
  defp scope_label(%{scope: :nested, where: where}), do: "nearer: #{where}/"

  defp file_json(f) do
    %{
      "scope" => to_string(f.scope),
      "path" => f.path,
      "size" => f.size,
      "chars" => f.chars,
      "budget" => f.budget,
      "share" => Float.round(f.chars / f.budget, 3),
      "hash" => f.hash,
      "status" => to_string(f.status),
      "reason" => f.reason,
      "trimmed" => f.trimmed,
      "skipped" => f.skipped,
      "imported_by" => f.imported_by,
      "unfollowed" =>
        Enum.map(f.unfollowed, &%{"import" => &1.import, "reason" => to_string(&1.reason)}),
      "rule" => rule_json(f.rule),
      "applies" => f.applies
    }
  end

  defp rule_json(nil), do: nil

  defp rule_json(rule) do
    %{
      "apply" => to_string(rule.apply),
      "globs" => rule.globs,
      "description" => rule.description,
      "matched" => rule.matched
    }
  end

  ## Config

  defp max_chars(%Config{instructions_max_chars: n}) when is_integer(n) and n > 0, do: n
  defp max_chars(_config), do: @default_max_chars

  defp memory_max_chars(%Config{memory_max_chars: n}) when is_integer(n) and n > 0, do: n
  defp memory_max_chars(_config), do: 6_000

  defp memory_enabled?(%Config{memory: enabled}), do: enabled != false
  defp memory_enabled?(_config), do: true
end
