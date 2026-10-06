defmodule Troupe.Instructions do
  @moduledoc """
  The instruction files a repository already carries for coding agents, read into every
  agent's system prompt (Decisions 706 and 798).

  `AGENTS.md` is the file the tools settled on, and a repository that has one has told
  agents how to work in it. Troupe reads it the way the others do: the person's own
  `<config>/AGENTS.md` first, then the repository root's, then one in each directory on
  the way from the root to where the session works, and Troupe's own brief
  (`.troupe/memory.md`) last. Where the session works is its workspace and the directory
  of every file its conversation has read, edited or written (`focus/1`), so a
  `frontend/AGENTS.md` applies once the agent has opened something under `frontend/`.
  Every one applies; where two disagree the nearer wins, which is why the nearer comes
  later in the prompt. In one directory `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and
  `.github/copilot-instructions.md` are the same file under other tools' names: the
  first that exists is read and the rest are named as skipped, so nobody debugs a file
  that was never loaded.

  A file may import another with `@path/to/file.md`, as Claude Code's do: resolved from
  the importing file's directory, followed five deep, each file read once, and never
  from outside the repository (or, for the person's own file, the config directory). An
  import is read right after the file that names it and belongs to that file's scope;
  one that is not followed is named on its importer, with why. The files found in the
  directories are held to the same edge: one that is really elsewhere, through a link,
  is listed as `outside` and not read.

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

  require Logger

  @aliases ["AGENTS.md", "CLAUDE.md", "GEMINI.md", ".github/copilot-instructions.md"]
  @default_max_chars 16_000

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
  `dropped`, or `outside` (a file that is really outside the repository, not read) for
  an instruction file, and for the brief what `Troupe.Session.Memory` says of it. `skipped` names the aliases the file hid in its directory; `where` is the
  directory's path from the repository root, for the prompt to name it by.
  `imported_by` is the file whose `@` import brought this one in, and `unfollowed` the
  imports this file names that were not read, with why: `missing`, `outside` the
  directory imports may come from, `depth` past five, or a `cycle`.
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
          trimmed: non_neg_integer(),
          skipped: [String.t()],
          imported_by: Path.t() | nil,
          unfollowed: [%{import: String.t(), reason: :missing | :outside | :depth | :cycle}],
          text: String.t()
        }

  @type t :: %{
          files: [file()],
          searched: [Path.t()],
          budget: pos_integer(),
          used: non_neg_integer(),
          digest: String.t()
        }

  @doc "The names one directory may carry, in the order the first of them is taken."
  @spec aliases() :: [String.t()]
  def aliases, do: @aliases

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
  those on the way to the workspace. `searched` is every directory looked in, whether or
  not it had one.
  """
  @spec load(Path.t(), Config.t() | nil, [Path.t()]) :: t()
  def load(workspace, config, focus \\ []) do
    workspace = Path.expand(workspace)
    budget = max_chars(config)
    {root, directories} = directories(workspace, focus)

    bounds = %{user: key(Paths.config_dir()), repository: key(root)}
    found = Enum.flat_map(directories, &find(&1, bounds))

    files =
      found
      |> Enum.map_reduce(MapSet.new(found, &key(&1.path)), &imports(&1, &2, bounds))
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
  the budget they count against and its share of it. Wire-shaped, string keys.
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

  defp repository_root(workspace) do
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

  defp find({scope, dir, where}, bounds) do
    case Enum.filter(@aliases, &File.regular?(Path.join(dir, &1))) do
      [] -> []
      [name | skipped] -> read(scope, dir, where, name, skipped, bound(scope, bounds))
    end
  end

  # A file found in a directory is confined as an import is: one that is really somewhere
  # outside the repository (or, for the person's own, the config directory), a link out
  # or a directory linked out, is not read, and is listed as `outside` with nothing of it
  # in the prompt, not even its size.
  defp read(scope, dir, where, name, skipped, bound) do
    path = Path.join(dir, name)
    fields = %{scope: scope, where: where, skipped: skipped}

    if under?(key(path), bound) do
      case entry(path, fields) do
        {:ok, file} -> [%{file | directory: dir}]
        :error -> []
      end
    else
      [Map.merge(outside(path, dir), fields)]
    end
  end

  defp outside(path, dir) do
    %{
      path: path,
      directory: dir,
      size: 0,
      hash: nil,
      skipped: [],
      imported_by: nil,
      unfollowed: [],
      text: "",
      status: :outside
    }
  end

  defp bound(:user, bounds), do: bounds.user
  defp bound(_scope, bounds), do: bounds.repository

  defp entry(path, fields) do
    case File.read(path) do
      {:ok, content} ->
        {:ok,
         Map.merge(
           %{
             path: path,
             directory: Path.dirname(path),
             size: byte_size(content),
             hash: hash(content),
             skipped: [],
             imported_by: nil,
             unfollowed: [],
             text: content |> String.replace("\r\n", "\n") |> String.trim()
           },
           fields
         )}

      {:error, reason} ->
        Logger.warning("instructions: ignoring unreadable #{path}: #{inspect(reason)}")
        :error
    end
  end

  ## Imports

  # A file and what it imports, depth first, each import right after the file that names
  # it. `seen` is every file already in the prompt, so each is read once; the person's
  # own file imports from the config directory, every other from the repository.
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
      :error -> missing(spec)
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
  # a scope the file comes before what it imports.
  defp allot(scopes, budget) do
    {allotted, _left} =
      scopes
      |> Enum.reverse()
      |> Enum.map_reduce(budget, fn files, left ->
        Enum.map_reduce(files, left, fn file, left ->
          {fit(file, budget, left), max(left - String.length(file.text), 0)}
        end)
      end)

    allotted |> Enum.reverse() |> Enum.concat()
  end

  defp fit(%{status: :outside} = file, budget, _left),
    do: Map.merge(file, %{chars: 0, trimmed: 0, budget: budget})

  defp fit(file, budget, left) do
    chars = String.length(file.text)

    cond do
      chars <= left ->
        Map.merge(file, %{chars: chars, trimmed: 0, status: :whole, budget: budget})

      left == 0 ->
        Map.merge(file, %{chars: 0, trimmed: chars, status: :dropped, budget: budget, text: ""})

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
  # asked for once, since that is a `git` call and this runs at every turn.
  defp brief(workspace, config) do
    path = Brief.path(workspace)
    max = memory_max_chars(config)
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
      trimmed: if(status == :trimmed, do: overflow, else: 0),
      skipped: [],
      imported_by: nil,
      unfollowed: [],
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
      Enum.join(fields ++ f.skipped ++ unfollowed, "\t")
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

  defp block(f), do: "Contents of #{f.path} (#{label(f)}):\n#{f.text}"

  defp label(%{imported_by: by} = f) when is_binary(by),
    do: "#{scope_label(f)}, imported by #{by}"

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
      "trimmed" => f.trimmed,
      "skipped" => f.skipped,
      "imported_by" => f.imported_by,
      "unfollowed" =>
        Enum.map(f.unfollowed, &%{"import" => &1.import, "reason" => to_string(&1.reason)})
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
