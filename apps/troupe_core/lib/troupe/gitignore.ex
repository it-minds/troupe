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
  """
  @spec load(Path.t()) :: t()
  def load(root) do
    # `match_dot: true` matters: `.gitignore` is itself a dotfile, and the default
    # wildcard would silently find none of them.
    files =
      [
        Path.join(root, ".git/info/exclude")
        | Path.wildcard(Path.join(root, "**/.gitignore"), match_dot: true)
      ]
      |> Enum.filter(&File.regular?/1)

    rules =
      Enum.flat_map(files, fn file ->
        base = file |> Path.dirname() |> Path.relative_to(root) |> normalize_base()

        file
        |> File.read!()
        |> parse(base)
      end)

    %__MODULE__{rules: rules}
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

  defp normalize_base("."), do: ""
  defp normalize_base(base), do: normalize(base)

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
