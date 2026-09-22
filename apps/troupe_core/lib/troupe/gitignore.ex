defmodule Troupe.Gitignore do
  @moduledoc """
  A `.gitignore` matcher good enough for deciding what the agent and the watcher see.

  It implements the parts of the format that matter in practice — anchoring, negation
  with `!`, directory-only patterns, `**`, and per-directory files — and errs toward
  *not* ignoring when a pattern is beyond it, because a file wrongly hidden from the
  agent is a much worse failure than one wrongly shown.

  `.git/` is always ignored regardless of any file's contents.
  """

  @enforce_keys [:rules]
  defstruct [:rules]

  @type rule :: %{
          regex: Regex.t(),
          negated?: boolean(),
          dir_only?: boolean(),
          base: String.t()
        }
  @type t :: %__MODULE__{rules: [rule()]}

  @doc """
  Load every `.gitignore` under a root, plus the root's `.git/info/exclude`.

  Loading is eager because the alternative — checking for a `.gitignore` in every
  ancestor of every path — turns one scan into thousands of stat calls.

  The walk prunes as it goes, as git does: a directory that is already ignored is not
  entered, `.git/` is not entered, and a symlink is not followed. It used to be
  `Path.wildcard("**/.gitignore")`, which descends into everything — on Windows a pnpm
  `node_modules` alone took 29 seconds, twice per session start, and the client's
  `session.create` timed out waiting.
  """
  @spec load(Path.t()) :: t()
  def load(root) do
    exclude = read_rules(Path.join(root, ".git/info/exclude"), "")
    %__MODULE__{rules: exclude ++ walk(root, "", exclude)}
  end

  # The rules found at and under `rel`, parents before children so later (deeper) rules
  # win. `seen` is every rule that applies above this directory, used only to prune.
  defp walk(root, rel, seen) do
    dir = if rel == "", do: root, else: Path.join(root, rel)
    own = read_rules(Path.join(dir, ".gitignore"), rel)
    matcher = %__MODULE__{rules: seen ++ own}

    nested =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.sort()
          |> Enum.map(&join_rel(rel, &1))
          |> Enum.filter(&descend?(root, &1, matcher))
          |> Enum.flat_map(&walk(root, &1, matcher.rules))

        {:error, _} ->
          []
      end

    own ++ nested
  end

  # A real directory — `lstat`, so a symlink or junction is not followed — that no rule
  # hides. `.git` by name at any depth, not only at the root, because a repository
  # vendored inside this one has one too and nothing in it is ours to read.
  defp descend?(root, rel, matcher) do
    Path.basename(rel) != ".git" and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(root, rel))) and
      not ignored?(matcher, rel)
  end

  defp join_rel("", name), do: name
  defp join_rel(rel, name), do: rel <> "/" <> name

  defp read_rules(file, base) do
    case File.read(file) do
      {:ok, contents} -> parse(contents, base)
      {:error, _} -> []
    end
  end

  @doc "An empty matcher that still hides `.git/`."
  @spec empty() :: t()
  def empty, do: %__MODULE__{rules: []}

  @doc "Build a matcher from pattern lines. Tests, and callers with no repo on disk."
  @spec from_string(String.t()) :: t()
  def from_string(contents), do: %__MODULE__{rules: parse(contents, "")}

  @doc """
  Whether a workspace-relative path is ignored.

  Later rules win, which is what makes `!` un-ignore work.
  """
  @spec ignored?(t(), String.t()) :: boolean()
  def ignored?(%__MODULE__{rules: rules}, path) do
    path = normalize(path)

    git_internal?(path) or Enum.reduce(rules, false, &apply_rule(&1, path, &2))
  end

  # Later rules win, which is what makes `!` un-ignore work.
  defp apply_rule(rule, path, ignored) do
    if matches?(rule, path), do: not rule.negated?, else: ignored
  end

  defp git_internal?(path), do: path == ".git" or String.starts_with?(path, ".git/")

  # A rule from a nested `.gitignore` only applies inside its own directory.
  defp matches?(%{base: ""} = rule, path), do: Regex.match?(rule.regex, path)

  defp matches?(rule, path) do
    String.starts_with?(path, rule.base <> "/") and
      Regex.match?(rule.regex, relative_to_base(path, rule.base))
  end

  defp relative_to_base(path, ""), do: path

  defp relative_to_base(path, base) do
    binary_part(path, byte_size(base) + 1, byte_size(path) - byte_size(base) - 1)
  end

  defp normalize(path) do
    path |> String.replace("\\", "/") |> String.trim_leading("./") |> String.trim_trailing("/")
  end

  defp parse(contents, base) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(&parse_line(&1, base))
  end

  defp parse_line(line, base) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> []
      String.starts_with?(trimmed, "#") -> []
      true -> [build_rule(trimmed, base)]
    end
  end

  defp build_rule(pattern, base) do
    {negated?, pattern} =
      case pattern do
        "!" <> rest -> {true, rest}
        _ -> {false, pattern}
      end

    {dir_only?, pattern} =
      if String.ends_with?(pattern, "/"),
        do: {true, String.trim_trailing(pattern, "/")},
        else: {false, pattern}

    # A pattern with a slash anywhere but the end is anchored to the file's directory;
    # one without matches at any depth. That distinction is most of gitignore.
    anchored? = String.contains?(pattern, "/")
    pattern = String.trim_leading(pattern, "/")

    %{
      regex: compile(pattern, anchored?, dir_only?),
      negated?: negated?,
      dir_only?: dir_only?,
      base: base
    }
  end

  defp compile(pattern, anchored?, dir_only?) do
    body = translate(pattern)
    prefix = if anchored?, do: "\\A", else: "\\A(?:.*/)?"
    # A directory pattern also hides everything under it.
    suffix = if dir_only?, do: "(?:/.*)?\\z", else: "(?:/.*)?\\z"

    Regex.compile!(prefix <> body <> suffix)
  end

  defp translate(pattern) do
    pattern
    |> String.replace("**/", "\x00DOUBLESLASH\x00")
    |> String.replace("**", "\x00DOUBLE\x00")
    |> escape()
    |> String.replace("\x00DOUBLESLASH\x00", "(?:.*/)?")
    |> String.replace("\x00DOUBLE\x00", ".*")
  end

  defp escape(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> "[^/]*"
      "?" -> "[^/]"
      "." -> "\\."
      "+" -> "\\+"
      "(" -> "\\("
      ")" -> "\\)"
      "|" -> "\\|"
      "^" -> "\\^"
      "$" -> "\\$"
      "{" -> "\\{"
      "}" -> "\\}"
      "\\" -> "\\\\"
      c -> c
    end)
  end
end
