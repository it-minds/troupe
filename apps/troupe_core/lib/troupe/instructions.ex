defmodule Troupe.Instructions do
  @moduledoc """
  The instruction files a repository already carries for coding agents, read into every
  agent's system prompt (Decision 706).

  `AGENTS.md` is the file the tools settled on, and a repository that has one has told
  agents how to work in it. Troupe reads it the way the others do: the person's own
  `<config>/AGENTS.md` first, then the repository root's, then one in each directory
  between the root and the workspace the session works in, and Troupe's own brief
  (`.troupe/memory.md`) last. Every one applies; where two disagree the nearer wins,
  which is why the nearer comes later in the prompt. In one directory `AGENTS.md`,
  `CLAUDE.md`, `GEMINI.md` and `.github/copilot-instructions.md` are the same file under
  other tools' names: the first that exists is read and the rest are named as skipped,
  so nobody debugs a file that was never loaded.

  Read from disk at every turn, so an edit takes effect on the next one. What was read
  is summed up in a digest, and the agent writes an `instructions_loaded` event when the
  digest changes and nothing while it does not: that is the cache, and what it buys is
  a log that says which files each turn was read from without saying so every turn.

  The files share one character budget, `instructions_max_chars`. The nearest is kept
  whole first; a file the remainder cannot hold is cut, or left out, and the prompt, the
  event and `context.get` all say so. The brief keeps its own budget
  (`memory_max_chars`). Nothing reaches the prompt from a file without appearing in
  `provenance/1`.

  Pure but for the reads. Nothing here writes.
  """

  alias Troupe.{Config, Memory, Paths}
  alias Troupe.Session.Memory, as: Brief

  require Logger

  @aliases ["AGENTS.md", "CLAUDE.md", "GEMINI.md", ".github/copilot-instructions.md"]
  @default_max_chars 16_000

  @preamble """
  What the people who work in this repository wrote for coding agents, read from disk
  at every turn. Every file applies; where two disagree, the one nearer the directory
  you are working in wins, and it comes later here.
  """

  @typedoc """
  One scope, in the order they are read: the person's own file, the repository root's,
  a directory between the root and the workspace, and the brief.
  """
  @type scope :: :user | :root | :nested | :brief

  @typedoc """
  One file in force. `size` is its bytes on disk; `chars` what reached the prompt, which
  counts against `budget`; `status` is `whole`, `trimmed` (`trimmed` characters cut) or
  `dropped` for an instruction file, and for the brief what `Troupe.Session.Memory`
  says of it. `skipped` names the aliases the file hid in its directory; `where` is the
  directory's path from the repository root, for the prompt to name it by.
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
  Reads every instruction file in force for a workspace, farthest scope first, and the
  brief after them. `searched` is every directory looked in, whether or not it had one.
  """
  @spec load(Path.t(), Config.t() | nil) :: t()
  def load(workspace, config) do
    workspace = Path.expand(workspace)
    budget = max_chars(config)
    directories = directories(workspace)

    files =
      directories
      |> Enum.flat_map(&find/1)
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
  @spec provenance(Path.t(), Config.t() | nil) :: map()
  def provenance(workspace, config), do: workspace |> load(config) |> provenance()

  ## Where to look

  # The person's own directory, the repository root, then every directory below it on
  # the way to the workspace, the workspace itself last. Without a `.git` the workspace is
  # the root; a `.git` file is a worktree's, which reads its own checkout's files.
  defp directories(workspace) do
    root = repository_root(workspace)

    nested =
      if workspace == root,
        do: [],
        else: workspace |> Path.relative_to(root) |> Path.split() |> nested_dirs(root)

    [{:user, Path.expand(Paths.config_dir()), nil}, {:root, root, nil} | nested]
    |> Enum.uniq_by(&elem(&1, 1))
  end

  # Each directory with its path from the root, which is how the prompt names it.
  defp nested_dirs(segments, root) do
    segments
    |> Enum.scan({root, []}, fn segment, {dir, rel} ->
      {Path.join(dir, segment), rel ++ [segment]}
    end)
    |> Enum.map(fn {dir, rel} -> {:nested, dir, Enum.join(rel, "/")} end)
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

  defp find({scope, dir, where}) do
    case Enum.filter(@aliases, &File.regular?(Path.join(dir, &1))) do
      [] -> []
      [name | skipped] -> read(scope, dir, where, name, skipped)
    end
  end

  defp read(scope, dir, where, name, skipped) do
    path = Path.join(dir, name)

    case File.read(path) do
      {:ok, content} ->
        [
          %{
            scope: scope,
            path: path,
            directory: dir,
            where: where,
            size: byte_size(content),
            hash: hash(content),
            skipped: skipped,
            text: content |> String.replace("\r\n", "\n") |> String.trim()
          }
        ]

      {:error, reason} ->
        Logger.warning("instructions: ignoring unreadable #{path}: #{inspect(reason)}")
        []
    end
  end

  # The nearest first: each takes what it needs from what is left, so the farthest is
  # the one cut or left out when the files together outrun the budget.
  defp allot(files, budget) do
    {allotted, _left} =
      files
      |> Enum.reverse()
      |> Enum.map_reduce(budget, fn file, left ->
        {fit(file, budget, left), max(left - String.length(file.text), 0)}
      end)

    Enum.reverse(allotted)
  end

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
  # asked for once, since that is a `git` call and this runs before every model call.
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
      Enum.join([f.path, f.hash || "", f.status, f.chars, f.trimmed | f.skipped], "\t")
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

  defp label(%{scope: :user}), do: "your own, every repository"
  defp label(%{scope: :root}), do: "repository root"
  defp label(%{scope: :nested, where: where}), do: "nearer: #{where}/"

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
      "skipped" => f.skipped
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
