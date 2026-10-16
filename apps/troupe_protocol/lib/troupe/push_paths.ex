defmodule Troupe.PushPaths do
  @moduledoc """
  The paths a push from a pod never carries to GitHub, whatever the agent put in the tree.

  A worker profile's `spec.github.denyPaths` adds patterns to a default list and cannot
  take one away: the defaults are the files that hold a credential by their name alone
  (`.env`, `*.pem`, private keys). The plane checks a profile's patterns when the profile
  is written and hands the whole list to the pod with the fix loop's token; the pod
  matches every path a push would add or change against it before anything is sent, and
  starts from the defaults even if the plane sent none.

  ## How a pattern matches

  As `.gitignore` reads one, near enough to need no second syntax:

  - a pattern with no `/` in it, a trailing one aside, matches a name at any depth, a
    file's or a directory's on the way to one: `*.pem` denies `certs/server.pem`, `.env` denies
    `api/.env` and everything under a directory called `.env`;
  - a pattern with a `/` in it is a path from the repository's root: `config/secrets`
    denies that file or everything under that directory, `deploy/**/*.key` any `.key`
    file anywhere under `deploy`;
  - `*` is any run of characters within one name, `?` one character, `**` any number of
    whole directories; nothing else is special;
  - letters match either case, so `.ENV` is `.env`: a checkout on a case-insensitive disk
    would make them one file.
  """

  # What every profile denies, extended by its own `denyPaths`: files whose name alone says
  # they hold a credential.
  @defaults [
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "id_rsa*",
    "id_dsa*",
    "id_ecdsa*",
    "id_ed25519*"
  ]

  @max_patterns 100
  @max_length 200

  @doc "The patterns every profile denies."
  @spec defaults() :: [String.t()]
  def defaults, do: @defaults

  @doc "The defaults and a profile's own patterns, each once, the defaults first."
  @spec effective([String.t()] | nil) :: [String.t()]
  def effective(extra) when is_list(extra),
    do: Enum.uniq(@defaults ++ Enum.filter(extra, &pattern?/1))

  def effective(_extra), do: @defaults

  @doc """
  The problems with a profile's `denyPaths`, as sentences: a list of at most
  #{@max_patterns} patterns, each a non-empty string of at most #{@max_length} characters
  that is not a path out of the repository.
  """
  @spec problems(term()) :: [String.t()]
  def problems(nil), do: []

  def problems(list) when is_list(list) do
    if length(list) > @max_patterns,
      do: ["github.denyPaths holds at most #{@max_patterns} patterns"],
      else: Enum.flat_map(list, &pattern_problem/1)
  end

  def problems(_other),
    do: ["github.denyPaths is a list of patterns, such as [\"secrets/\", \"*.tfstate\"]"]

  defp pattern_problem(pattern) when is_binary(pattern) do
    trimmed = String.trim(pattern)

    cond do
      trimmed == "" or trimmed == "/" ->
        ["github.denyPaths has an empty pattern"]

      String.length(pattern) > @max_length ->
        ["github.denyPaths has a pattern longer than #{@max_length} characters"]

      String.contains?(pattern, <<0>>) ->
        ["github.denyPaths has a pattern with a NUL in it"]

      ".." in String.split(trimmed, "/") ->
        ["github.denyPaths pattern #{inspect(pattern)} climbs out of the repository"]

      true ->
        []
    end
  end

  defp pattern_problem(other), do: ["github.denyPaths has #{inspect(other)}, not a pattern"]

  defp pattern?(pattern), do: is_binary(pattern) and pattern_problem(pattern) == []

  @doc """
  Which of `paths` (repository-relative, `/`-separated, as git names them) one of
  `patterns` denies, in the order given, each with the pattern that denied it.
  """
  @spec denied([String.t()], [String.t()]) :: [{String.t(), String.t()}]
  def denied(paths, patterns) do
    compiled = for pattern <- patterns, pattern?(pattern), do: {pattern, compile(pattern)}

    for path <- paths,
        {pattern, _rule} <- [Enum.find(compiled, &matches?(elem(&1, 1), path))],
        do: {path, pattern}
  end

  @doc "Whether `pattern` denies `path`."
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(path, pattern), do: pattern?(pattern) and matches?(compile(pattern), path)

  # -- matching ----------------------------------------------------------------------

  defp compile(pattern) do
    pattern = pattern |> String.trim() |> String.trim_trailing("/")

    if String.contains?(pattern, "/") do
      {:rooted, regex(String.trim_leading(pattern, "/"))}
    else
      {:name, regex(pattern)}
    end
  end

  # A name pattern denies a path when any of its names, the file's or a directory's on the
  # way to it, matches.
  defp matches?({:name, regex}, path) do
    path |> String.split("/", trim: true) |> Enum.any?(&Regex.match?(regex, &1))
  end

  # A rooted pattern denies the path itself or any directory it is under.
  defp matches?({:rooted, regex}, path) do
    names = String.split(path, "/", trim: true)

    Enum.any?(1..max(length(names), 1)//1, fn n ->
      Regex.match?(regex, names |> Enum.take(n) |> Enum.join("/"))
    end)
  end

  defp regex(glob) do
    body =
      glob
      |> tokens([])
      |> Enum.map_join(fn
        :globstar_dir -> "(?:[^/]+/)*"
        :globstar -> ".*"
        :star -> "[^/]*"
        :any -> "[^/]"
        literal -> Regex.escape(literal)
      end)

    Regex.compile!("\\A" <> body <> "\\z", "iu")
  end

  defp tokens("", acc), do: Enum.reverse(acc)
  defp tokens("**/" <> rest, acc), do: tokens(rest, [:globstar_dir | acc])
  defp tokens("**" <> rest, acc), do: tokens(rest, [:globstar | acc])
  defp tokens("*" <> rest, acc), do: tokens(rest, [:star | acc])
  defp tokens("?" <> rest, acc), do: tokens(rest, [:any | acc])

  defp tokens(<<char::utf8, rest::binary>>, acc),
    do: tokens(rest, [<<char::utf8>> | acc])
end
