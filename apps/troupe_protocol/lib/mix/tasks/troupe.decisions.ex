defmodule Mix.Tasks.Troupe.Decisions do
  @shortdoc "List the decisions that govern a path, or check every decision file"

  @moduledoc """
  The decisions, a file each under `docs/decisions/` (Decision 790).

      mix troupe.decisions --for apps/troupe_gateway/lib/troupe/gateway/private.ex
      mix troupe.decisions --for clients/tui --for PROTOCOL.md
      mix troupe.decisions --check

  The repository's decisions are in `docs/decisions/`, the TUI's in `docs/decisions/tui/`
  and the daemon's in `docs/decisions/daemon/`, each log numbered on its own, so a number
  is written `790`, `tui/108` or `daemon/5` here. A file is
  `<four-digit number>-<slug>.md` and starts with a front matter:

      ---
      number: 790
      title: One sentence, the decision itself
      date: 2026-10-05
      status: accepted
      issue: 437
      paths:
        - docs/decisions/
        - apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex
      gist: What someone changing those paths must not undo, in about 150 characters
      ---

  `paths` are globs, from the repository root, of the files and directories the decision
  governs. `status` is `accepted` or `superseded` (`superseded by 791` reads too);
  `supersedes:` (numbers), `symbols:` (modules and functions), `issue:` and `pr:` are
  optional.

  ## --for

  The decisions whose `paths` name the path, a directory it is in, or, for a directory,
  something inside it: newest first, the number, the gist and the file. A superseded one
  says what replaced it; one another decision replaced in part says that. The gist is
  there so that an agent or a person can tell without reading the decision whether it
  bears on the change they are about to make.

  ## --check

  What CI holds every file to: a front matter that reads as YAML reads it, the fields
  above present and of their kind, the number the file name's, no number twice in one
  log, a body, and every `paths` glob matching something in the checkout. A glob that
  matches nothing is a decision whose files moved or went, which is the moment someone
  should look at it, not a year later.

  ## Why it needs nothing but Elixir

  A glob stops matching when any file moves, whatever the change was, so CI runs
  `--check` in the job that runs on every change and compiles nothing, as it checks the
  documentation's links. This module therefore uses no dependency, and loads into a bare
  `elixir`:

      elixir -r apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex \\
        -e 'Mix.Tasks.Troupe.Decisions.run(System.argv())' -- --check

  The front matter is read by the small reader below, of the part of YAML a decision is
  written in: `key: value`, a value plain, single- or double-quoted, a list of them one
  `- item` a line or `[a, b]`. It refuses what YAML would read as something other than it
  looks, so that what passes here is what the documentation site reads: an unquoted value
  holding `: `, or starting with a character YAML reserves (a backtick, `*`, `&`, `[`,
  ...), and an unquoted title or gist that YAML would cut at a ` #` or read as a number.
  """

  use Mix.Task

  @dir "docs/decisions"
  @required ~w(number title date status paths gist)
  @name ~r/^(\d{4,})-[a-z0-9][a-z0-9-]*\.md$/

  # What YAML reads, unquoted, as something other than text.
  @not_text ~r/^(?:~|null|true|false|yes|no|on|off|[-+]?(?:\d[\d_]*)?\.?\d+(?:[eE][-+]?\d+)?)$/i

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv, strict: [for: :keep, check: :boolean, root: :string])

    root = opts[:root] || root(File.cwd!())
    paths = Keyword.get_values(opts, :for)

    cond do
      invalid != [] or rest != [] -> Mix.raise(usage())
      opts[:check] -> check!(root)
      paths != [] -> Enum.each(paths, &list(root, &1))
      true -> Mix.raise(usage())
    end
  end

  defp usage do
    "usage: mix troupe.decisions --for <path> [--for <path> ...] | mix troupe.decisions --check"
  end

  # The nearest directory above `dir` that has `docs/decisions`, so the task runs from the
  # repository root, from an app's directory and from `clients/tui`.
  defp root(dir) do
    cond do
      File.dir?(Path.join(dir, @dir)) -> dir
      Path.dirname(dir) == dir -> dir
      true -> root(Path.dirname(dir))
    end
  end

  # -- --for ----------------------------------------------------------------------

  defp list(root, path) do
    {decisions, _problems} = load(root)
    target = relative(root, path)

    case governing(decisions, root, target) do
      [] ->
        IO.puts("#{target}: no decision names it")

      found ->
        IO.puts("#{target}: #{count(found)}, newest first\n")
        Enum.each(found, &IO.puts(line(&1, decisions)))
    end
  end

  defp count([_one]), do: "1 decision"
  defp count(found), do: "#{length(found)} decisions"

  defp line(decision, decisions) do
    id = String.pad_trailing(decision.id, 11)
    indent = String.duplicate(" ", 11)
    "  #{id}#{mark(decision, decisions)}#{decision.gist}\n  #{indent}#{decision.file}"
  end

  defp mark(decision, decisions) do
    by = decisions |> superseders(decision) |> Enum.map_join(", ", & &1.id)
    superseded? = String.starts_with?(decision.status, "superseded")

    cond do
      superseded? and by == "" -> "[superseded] "
      superseded? -> "[superseded by #{by}] "
      by != "" -> "[partly superseded by #{by}] "
      true -> ""
    end
  end

  defp superseders(decisions, decision) do
    Enum.filter(decisions, &(&1.log == decision.log and decision.number in &1.supersedes))
  end

  @doc """
  The decisions among `decisions` whose `paths` govern `target`, a path relative to
  `root`, newest first.
  """
  def governing(decisions, root, target) do
    decisions
    |> Enum.filter(fn decision -> Enum.any?(decision.paths, &governs?(root, &1, target)) end)
    |> Enum.sort_by(&{&1.date, &1.number}, :desc)
  end

  defp governs?(root, glob, target) do
    root
    |> expand(glob)
    |> Enum.any?(fn found ->
      target in [".", found] or String.starts_with?(target, found <> "/") or
        String.starts_with?(found, target <> "/")
    end)
  end

  defp relative(root, path) do
    path = path |> String.replace("\\", "/") |> Path.expand() |> drive()

    case Path.relative_to(path, drive(Path.expand(root))) do
      ^path -> Mix.raise("#{path} is not inside #{root}")
      inside -> String.trim_trailing(inside, "/")
    end
  end

  # `C:/` and `c:/` are one drive, whichever a shell handed over.
  defp drive(<<letter, ?:, rest::binary>>) when letter in ?A..?Z, do: <<letter + 32, ?:>> <> rest
  defp drive(path), do: path

  defp expand(root, glob) do
    root
    |> Path.join(String.trim_trailing(glob, "/"))
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  # -- --check --------------------------------------------------------------------

  defp check!(root) do
    unless File.dir?(Path.join(root, @dir)), do: Mix.raise("no #{@dir} under #{root}")

    {decisions, _problems} = loaded = load(root)

    case problems(root, loaded) do
      [] ->
        logs = decisions |> Enum.map(& &1.log) |> Enum.uniq() |> length()

        IO.puts(
          "decisions: #{length(decisions)} in #{logs} logs; numbers unique, fields present, " <>
            "every path matches"
        )

      problems ->
        Enum.each(problems, fn {file, message} -> IO.puts(:stderr, "#{file}: #{message}") end)
        Mix.raise("#{length(problems)} problem(s) in #{@dir}; see above")
    end
  end

  @doc """
  Every problem with the decision files under `root`, as `{file, message}`.
  """
  def check(root), do: problems(root, load(root))

  defp problems(root, {decisions, problems}) do
    duplicates =
      decisions
      |> Enum.group_by(&{&1.log, &1.number})
      |> Enum.filter(fn {_key, same} -> length(same) > 1 end)
      |> Enum.flat_map(fn {_key, [first | others]} ->
        for other <- others, do: {other.file, "number #{other.number} is #{first.file}'s too"}
      end)

    unmatched =
      for decision <- decisions, glob <- decision.paths, expand(root, glob) == [] do
        {decision.file, "paths: #{glob} matches nothing"}
      end

    Enum.sort(problems ++ duplicates ++ unmatched)
  end

  @doc """
  The decision files under `root`: `{decisions, problems}`, where a file with a problem
  in its name or its front matter is a problem and not a decision.
  """
  def load(root) do
    base = Path.join(root, @dir)

    base
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in ["README.md", "index.md"]))
    |> Enum.sort()
    |> Enum.map(&read(&1, base, root))
    |> Enum.split_with(&is_map/1)
  end

  defp read(path, base, root) do
    file = Path.relative_to(path, root)
    log = path |> Path.dirname() |> Path.relative_to(base)
    log = if log in [".", base], do: "", else: log

    with {:ok, number} <- file_number(path),
         {:ok, fields, body} <- path |> File.read!() |> parse(),
         {:ok, decision} <- decision(fields, body, number) do
      id = if log == "", do: "#{number}", else: "#{log}/#{number}"
      Map.merge(decision, %{file: file, log: log, id: id})
    else
      {:error, message} -> {file, message}
    end
  end

  defp file_number(path) do
    case Regex.run(@name, Path.basename(path), capture: :all_but_first) do
      [digits] -> {:ok, String.to_integer(digits)}
      nil -> {:error, "a decision's file is named <four-digit number>-<slug>.md, in lower case"}
    end
  end

  defp decision(fields, body, number) do
    missing = for key <- @required, Map.get(fields, key) in [nil, {:plain, ""}], do: key

    cond do
      missing != [] -> {:error, "missing #{Enum.join(missing, ", ")}"}
      String.trim(body) == "" -> {:error, "no body: the reasoning goes under the front matter"}
      true -> fields(fields, number)
    end
  end

  defp fields(fields, number) do
    with {:ok, n} <- number(fields["number"], number),
         {:ok, title} <- text(fields["title"], "title"),
         {:ok, gist} <- text(fields["gist"], "gist"),
         {:ok, date} <- date(fields["date"]),
         {:ok, status} <- status(fields["status"]),
         {:ok, lists} <- lists(fields) do
      {:ok, Map.merge(%{number: n, title: title, gist: gist, date: date, status: status}, lists)}
    end
  end

  defp lists(fields) do
    with {:ok, paths} <- strings(fields["paths"], "paths"),
         {:ok, symbols} <- strings(Map.get(fields, "symbols", {:list, []}), "symbols"),
         {:ok, supersedes} <- integers(Map.get(fields, "supersedes", {:list, []})),
         {:ok, issue} <- optional_integer(fields["issue"], "issue") do
      {:ok, %{paths: paths, symbols: symbols, supersedes: supersedes, issue: issue}}
    end
  end

  # -- the fields ---------------------------------------------------------------

  defp number(value, from_name) do
    case integer(value, "number") do
      {:ok, ^from_name} -> {:ok, from_name}
      {:ok, n} -> {:error, "number is #{n}, and the file name says #{from_name}"}
      error -> error
    end
  end

  defp integer({kind, value}, key) when kind in [:plain, :cut] do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, "#{key} is a number, unquoted: #{value}"}
    end
  end

  defp integer(_other, key), do: {:error, "#{key} is a number, unquoted"}

  defp optional_integer(nil, _key), do: {:ok, nil}
  defp optional_integer(value, key), do: integer(value, key)

  defp integers({:list, items}), do: each(items, &integer(&1, "supersedes"))
  defp integers(single), do: integers({:list, [single]})

  # A title or gist is a string to YAML too: unquoted, `true`, `12` or `1.5` would not be.
  defp text({:quoted, value}, key), do: nonempty(value, key)

  defp text({:plain, value}, key) do
    if Regex.match?(@not_text, value),
      do: {:error, "#{key}: YAML reads #{value} as something other than text; put it in quotes"},
      else: nonempty(value, key)
  end

  defp text({:cut, _value}, key) do
    {:error,
     "#{key}: YAML reads ` #` as the start of a comment and drops the rest; put it in quotes"}
  end

  defp text(_list, key), do: {:error, "#{key} is one line of text, not a list"}

  defp nonempty(value, key) do
    if String.trim(value) == "", do: {:error, "#{key} is empty"}, else: {:ok, value}
  end

  defp date({kind, value}) when kind in [:plain, :quoted, :cut] do
    case Date.from_iso8601(value) do
      {:ok, _date} -> {:ok, value}
      {:error, _reason} -> {:error, "date is a day, YYYY-MM-DD: #{value}"}
    end
  end

  defp date(_other), do: {:error, "date is a day, YYYY-MM-DD"}

  defp status({kind, value}) when kind in [:plain, :quoted, :cut] do
    if value in ["accepted", "superseded"] or String.starts_with?(value, "superseded by "),
      do: {:ok, value},
      else: {:error, "status is accepted or superseded: #{value}"}
  end

  defp status(_other), do: {:error, "status is accepted or superseded"}

  defp strings({:list, []}, "paths"), do: {:error, "paths names at least one file or directory"}
  defp strings({:list, items}, key), do: each(items, &path(&1, key))
  defp strings(single, key), do: strings({:list, [single]}, key)

  defp path({kind, value}, key) when kind in [:plain, :quoted, :cut] do
    cond do
      value == "" ->
        {:error, "#{key}: an empty entry"}

      key == "paths" and (Path.type(value) != :relative or ".." in Path.split(value)) ->
        {:error, "paths: #{value} is not inside the repository; write it from the root"}

      true ->
        {:ok, value}
    end
  end

  defp path(_other, key), do: {:error, "#{key}: each entry is one line of text"}

  # `fun` over `items`, all `{:ok, value}` or the first error.
  defp each(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  # -- the front matter ---------------------------------------------------------

  @doc """
  A decision file's text as `{:ok, fields, body}`, or `{:error, message}`.

  A field's value is `{:plain, text}`, `{:quoted, text}`, `{:cut, text}` (plain, with a
  YAML comment cut off it) or `{:list, values}`.
  """
  def parse(text) do
    text = String.replace(text, "\r\n", "\n")

    case Regex.run(~r/\A---[ \t]*\n(.*?)^---[ \t]*$\n?(.*)\z/ms, text, capture: :all_but_first) do
      [front, body] ->
        with {:ok, fields} <- front_matter(front), do: {:ok, fields, body}

      nil ->
        {:error,
         "no front matter: the file starts with a line `---`, then the fields, then `---`"}
    end
  end

  defp front_matter(front) do
    front
    |> String.split("\n")
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, []}, &group/2)
    |> case do
      {:ok, groups} -> groups |> Enum.reverse() |> values()
      error -> error
    end
  end

  # Lines into `{key, inline, more}`: a `key:` at the margin, and the indented or `- `
  # lines under it. MkDocs ends a front matter at the first `---` or `...` that ends a
  # line, wherever in the line it is.
  defp group({line, n}, {:ok, groups}) do
    key = Regex.run(~r/^([A-Za-z_][\w-]*):(?:[ \t]+(.*)|[ \t]*)$/, line, capture: :all_but_first)

    cond do
      Regex.match?(~r/(\.{3}|-{3})[ \t]*$/, line) ->
        {:halt,
         {:error, "line #{n} of the front matter ends with `...` or `---`, which ends it early"}}

      key != nil ->
        {:cont, {:ok, [{hd(key), Enum.at(key, 1, ""), []} | groups]}}

      String.trim(line) == "" or String.starts_with?(line, "#") ->
        {:cont, {:ok, groups}}

      groups != [] and Regex.match?(~r/^(\s|- |-$)/, line) ->
        {:cont, {:ok, more(groups, line)}}

      true ->
        {:halt, {:error, "line #{n} of the front matter is not `key: value`: #{line}"}}
    end
  end

  defp more([{key, inline, lines} | rest], line), do: [{key, inline, lines ++ [line]} | rest]

  defp values(groups) do
    Enum.reduce_while(groups, {:ok, %{}}, fn {key, inline, more}, {:ok, acc} ->
      if Map.has_key?(acc, key),
        do: {:halt, {:error, "#{key} is given twice"}},
        else: value(key, inline, more, acc)
    end)
  end

  defp value(key, inline, more, acc) do
    case read_value(String.trim(inline), more) do
      {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
      {:error, message} -> {:halt, {:error, "#{key}: #{message}"}}
    end
  end

  defp read_value("", []), do: {:ok, nil}
  defp read_value("", more), do: block_list(more)

  defp read_value("[" <> _ = inline, more),
    do: flow_list(Enum.join([inline | trimmed(more)], " "))

  defp read_value(inline, more) when inline in [">", ">-", "|", "|-"] do
    joint = if String.starts_with?(inline, "|"), do: "\n", else: " "
    {:ok, {:quoted, more |> trimmed() |> Enum.join(joint)}}
  end

  defp read_value(inline, more), do: scalar(Enum.join([inline | trimmed(more)], " "))

  defp trimmed(lines), do: lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp block_list(lines) do
    items =
      lines
      |> trimmed()
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.reduce_while({:ok, []}, &item/2)

    with {:ok, items} <- items, do: scalars(items)
  end

  # An entry is `- value`; a line under it that does not start `- ` continues it.
  defp item("-", _items), do: {:halt, {:error, "an empty list entry"}}
  defp item("- " <> value, {:ok, items}), do: {:cont, {:ok, items ++ [String.trim(value)]}}
  defp item(line, {:ok, []}), do: {:halt, {:error, "a list's entries each start `- `: #{line}"}}

  defp item(line, {:ok, items}),
    do: {:cont, {:ok, List.update_at(items, -1, &(&1 <> " " <> line))}}

  defp flow_list(text) do
    case Regex.run(~r/^\[(.*)\]\s*(?:#.*)?$/, text, capture: :all_but_first) do
      [inner] ->
        inner
        |> String.split(~r/,(?=(?:[^"']|"[^"]*"|'[^']*')*$)/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> scalars()

      nil ->
        {:error, "a list in brackets ends at its `]`"}
    end
  end

  defp scalars(items) do
    with {:ok, values} <- each(items, &scalar/1), do: {:ok, {:list, values}}
  end

  defp scalar(~s(") <> _ = text) do
    case Regex.run(~r/^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/s, text, capture: :all_but_first) do
      [inner] -> unescape(inner)
      nil -> {:error, "a double-quoted value ends at its closing quote: #{text}"}
    end
  end

  defp scalar("'" <> _ = text) do
    case Regex.run(~r/^'((?:[^']|'')*)'\s*(?:#.*)?$/s, text, capture: :all_but_first) do
      [inner] -> {:ok, {:quoted, String.replace(inner, "''", "'")}}
      nil -> {:error, "a single-quoted value ends at its closing quote: #{text}"}
    end
  end

  defp scalar(text) do
    {value, kind} =
      case String.split(text, ~r/\s#/, parts: 2) do
        [value, _comment] -> {String.trim(value), :cut}
        [value] -> {String.trim(value), :plain}
      end

    cond do
      Regex.match?(~r/^([`@*&!%|>,\[\]{}#'"]|[-?:](\s|$))/, value) ->
        {:error, "#{value} starts with a character YAML reads as syntax; put it in double quotes"}

      String.contains?(value, ": ") or String.ends_with?(value, ":") ->
        {:error, "#{value} has `: `, which YAML reads as a key; put it in double quotes"}

      true ->
        {:ok, {kind, value}}
    end
  end

  @escape ~r/\\(u[0-9a-fA-F]{4}|.)/s
  @escapes %{"\\" => "\\", ~s(") => ~s("), "/" => "/", "n" => "\n", "t" => "\t", " " => " "}

  defp unescape(inner) do
    odd =
      @escape
      |> Regex.scan(inner, capture: :all_but_first)
      |> List.flatten()
      |> Enum.find(
        &(not Map.has_key?(@escapes, &1) and not Regex.match?(~r/^u[0-9a-fA-F]{4}$/, &1))
      )

    if odd,
      do:
        {:error, "\\#{odd} is not an escape this reads as YAML does; write the character itself"},
      else: {:ok, {:quoted, Regex.replace(@escape, inner, &unescape_one/2)}}
  end

  defp unescape_one(_all, "u" <> hex) when byte_size(hex) == 4,
    do: <<String.to_integer(hex, 16)::utf8>>

  defp unescape_one(_all, escape), do: Map.fetch!(@escapes, escape)
end
