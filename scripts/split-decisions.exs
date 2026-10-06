# The three decision logs, split into one file per decision (issue #437, Decision 790).
#
#     elixir scripts/split-decisions.exs
#
# `DECISIONS.md`, `clients/tui/DECISIONS.md` and `apps/troupe_daemon/DECISIONS.md` were one
# file each, and every pull request that decided something appended to the end of one, so
# any two of them conflicted there. This reads whichever of the three is present and writes
# each numbered entry to `docs/decisions/` (the TUI's to `tui/`, the daemon's to `daemon/`)
# as `<four-digit number>-<slug>.md`, the body as it was, under the front matter
# `mix troupe.decisions --check` reads, drafted from what is already there:
#
#   * title       the entry's bold first sentence, without its full stop;
#   * date        the day the entry's first line was added to its log, from git (today,
#                 for one no commit has yet);
#   * status      superseded where a later entry says it replaces this one whole;
#   * supersedes  on the later entry, the numbers it says it replaces, whole or in part;
#   * issue       the first issue the entry names as its own;
#   * paths       the files whose code or documents cite the number (a log's own citation
#                 form: in `clients/tui` a bare number is the TUI's and `root Decision N` the
#                 repository's; elsewhere `TUI Decision N` is the TUI's); failing those, the
#                 files and modules the entry names; failing those, the narrowest directory
#                 it is about;
#   * gist        the title, cut to about 150 characters where it is longer.
#
# It stays so that a branch cut before the split, which appended to a log, can catch up:
# keep that log as the branch has it, run this, and its new entries become files. A number
# that already has a file is not written again; when the log's body for it differs from
# the file's, the log is left where it is and the number is named, to be compared by hand.
# Otherwise the log is removed.

defmodule SplitDecisions do
  @root Path.expand("..", __DIR__)

  @logs [
    {:root, "DECISIONS.md", "docs/decisions"},
    {:tui, "clients/tui/DECISIONS.md", "docs/decisions/tui"},
    {:daemon, "apps/troupe_daemon/DECISIONS.md", "docs/decisions/daemon"}
  ]

  # Where a log's own entries live, for a file it names relative to itself and for an entry
  # nothing else points at.
  @home %{tui: "clients/tui", daemon: "apps/troupe_daemon"}

  # What cites a decision without being governed by it: the logs, the decisions themselves,
  # the defects list (which says where a decision was not kept) and this script.
  @not_citations ["docs/decisions/", "docs/developer/defects.md", "scripts/split-decisions.exs"]

  # Supersession an entry states in words no pattern below reads: the daemon's 5 puts
  # Windows back in the matrix that 4 took it out of.
  @stated %{{:daemon, 5} => [{4, :whole}]}

  # For an entry of the repository's log that neither cites nor names a file: the
  # directory of the component it talks about most.
  @areas [
    {"apps/troupe_operator", ~r/\boperator\b|\bCRDs?\b|\breconcil/i},
    {"apps/troupe_plane",
     ~r/\bplane\b|\bpanel\b|\bconsole\b|\bbudgets?\b|\bledger\b|\bcaps?\b|\breservations?\b|\bprincipals?\b/i},
    {"apps/troupe_worker", ~r/\bworkers?\b|\bpods?\b/i},
    {"apps/troupe_gateway", ~r/\bgateway\b/i},
    {"apps/troupe_daemon", ~r/\bdaemon\b/i},
    {"apps/troupe_a2a", ~r/\bA2A\b/},
    {"apps/troupe_protocol", ~r/\bprotocol\b|\bschema\b/i},
    {"apps/troupe_core", ~r/\bharness\b|\bagents?\b|\bprovider|\bcompaction\b|\bturns?\b/i},
    {"clients/tui", ~r/\bTUI\b|\bterminal\b/},
    {"clients/gui", ~r/\bGUI\b|\bdesktop app\b|\bTauri\b/},
    {"clients/vscode", ~r/\bVS Code\b|\bextension\b/},
    {"charts/troupe", ~r/\bchart\b|\bHelm\b/i},
    {".github/workflows", ~r/\bworkflow\b|\bCI\b|\brelease\b/},
    {"docs", ~r/\bdocumentation\b|\bdocs\b/i}
  ]

  def main(_args) do
    files = tracked()
    known_files = MapSet.new(files)
    known_dirs = for file <- files, dir <- parents(file), into: MapSet.new(), do: dir

    logs =
      for {kind, log, dir} <- @logs, File.regular?(Path.join(@root, log)) do
        {kind, log, dir, log |> read() |> entries()}
      end

    if logs == [] do
      IO.puts("no decision log left to split")
      System.halt(0)
    end

    numbers =
      Map.new(@logs, fn {kind, _log, dir} ->
        from_log = for {^kind, _, _, entries} <- logs, entry <- entries, do: entry.number
        {kind, MapSet.new(from_log ++ existing_numbers(dir))}
      end)

    citations = citations(files, numbers)
    modules = modules(files)
    index = %{files: known_files, dirs: known_dirs, all: files, modules: modules}

    results = Enum.map(logs, fn log -> split(log, citations, index) end)

    IO.puts("")

    for {log, summary} <- results do
      IO.puts("#{log}: #{summary}")
    end

    if Enum.any?(results, fn {_log, summary} -> String.contains?(summary, "differ") end) do
      System.halt(1)
    end
  end

  # -- one log -----------------------------------------------------------------

  defp split({kind, log, dir, entries}, citations, index) do
    dates = first_dates(log)
    relations = relations(kind, entries)
    File.mkdir_p!(Path.join(@root, dir))

    outcomes =
      for entry <- entries do
        {paths, source} = paths(kind, entry, citations, index)

        front = %{
          number: entry.number,
          title: entry.title,
          # An entry no commit has yet is being added today.
          date: Map.get_lazy(dates, entry.number, fn -> Date.to_iso8601(Date.utc_today()) end),
          status: status(entry.number, relations),
          issue: issue(entry.text),
          supersedes: supersedes(entry.number, relations),
          paths: paths,
          gist: gist(entry.title)
        }

        {write(dir, entry, front), source, entry.number}
      end

    differ = for {:differs, _source, n} <- outcomes, do: n
    written = Enum.count(outcomes, &match?({:written, _, _}, &1))
    kept = Enum.count(outcomes, &match?({:kept, _, _}, &1))
    by_source = Enum.frequencies_by(outcomes, fn {_outcome, source, _n} -> source end)
    fallback = for {:written, :directory, n} <- outcomes, do: n

    summary =
      "#{length(entries)} entries, #{written} written, #{kept} already there; paths from " <>
        "citations #{Map.get(by_source, :cited, 0)}, named files #{Map.get(by_source, :named, 0)}, " <>
        "a directory #{Map.get(by_source, :directory, 0)}" <>
        if(fallback == [], do: "", else: " (#{Enum.join(fallback, ", ")})")

    if differ == [] do
      File.rm!(Path.join(@root, log))
      {log, summary <> "; removed"}
    else
      {log,
       summary <> "; kept, because these differ from their files: #{Enum.join(differ, ", ")}"}
    end
  end

  defp write(dir, entry, front) do
    case existing(dir, entry.number) do
      nil ->
        name = "#{pad(entry.number)}-#{slug(entry.title)}.md"
        File.write!(Path.join([@root, dir, name]), document(front, entry.body))
        :written

      path ->
        if body(File.read!(path)) == String.trim(entry.body), do: :kept, else: :differs
    end
  end

  defp document(front, body) do
    lines =
      [
        "number: #{front.number}",
        "title: #{yaml(front.title)}",
        front.date && "date: #{front.date}",
        "status: #{front.status}",
        front.issue && "issue: #{front.issue}",
        front.supersedes != [] && "supersedes: [#{Enum.join(front.supersedes, ", ")}]",
        "paths:",
        Enum.map(front.paths, &"  - #{yaml(&1)}"),
        "gist: #{yaml(front.gist)}"
      ]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)

    "---\n" <> Enum.join(lines, "\n") <> "\n---\n\n" <> String.trim(body) <> "\n"
  end

  defp body(document) do
    case String.split(document, ~r/\A---\r?\n.*?\r?\n---\r?\n/s, parts: 2) do
      ["", rest] -> String.trim(rest)
      _otherwise -> String.trim(document)
    end
  end

  defp existing(dir, number) do
    case Path.wildcard(Path.join([@root, dir, "#{pad(number)}-*.md"])) do
      [path | _] -> path
      [] -> nil
    end
  end

  defp existing_numbers(dir) do
    for path <- Path.wildcard(Path.join([@root, dir, "*.md"])),
        [n] <- [Regex.run(~r/^(\d+)-/, Path.basename(path), capture: :all_but_first)],
        do: String.to_integer(n)
  end

  # -- reading a log -------------------------------------------------------------

  # An entry starts at `N. **` at the margin and runs to the next one or the next heading.
  # The heading it is under is kept, as a hint of what it is about.
  def entries(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({"", nil, []}, fn line, {section, current, done} ->
      cond do
        Regex.match?(~r/^\d+\.\s+\*\*/, line) -> {section, [line], close(section, current, done)}
        String.starts_with?(line, "#") -> {line, nil, close(section, current, done)}
        current != nil -> {section, [line | current], done}
        true -> {section, nil, done}
      end
    end)
    |> then(fn {section, current, done} -> close(section, current, done) end)
    |> Enum.reverse()
    |> Enum.map(fn {section, lines} -> Map.put(entry(lines), :section, section) end)
  end

  defp close(_section, nil, done), do: done
  defp close(section, lines, done), do: [{section, Enum.reverse(lines)} | done]

  defp entry([first | rest]) do
    [_, number, marker] = Regex.run(~r/^(\d+)(\.\s+)/, first)
    indent = String.length(number <> marker)
    head = String.slice(first, indent..-1//1)
    text = Enum.join([head | Enum.map(rest, &dedent(&1, indent))], "\n")

    {start, 2} = :binary.match(text, "**")
    {close, 2} = :binary.match(text, "**", scope: {start + 2, byte_size(text) - start - 2})
    title = binary_part(text, start + 2, close - start - 2)
    after_title = binary_part(text, close + 2, byte_size(text) - close - 2)

    %{
      number: String.to_integer(number),
      title: title |> String.replace(~r/\s*\n\s*/, " ") |> String.trim() |> drop_full_stop(),
      body: after_title |> String.replace(~r/\A[ \t]+/, "") |> String.trim(),
      text: text
    }
  end

  defp dedent(line, indent) do
    spaces = byte_size(line) - byte_size(String.trim_leading(line, " "))
    binary_part(line, min(spaces, indent), byte_size(line) - min(spaces, indent))
  end

  defp drop_full_stop(title) do
    if String.ends_with?(title, ".") and not String.ends_with?(title, ".."),
      do: String.slice(title, 0..-2//1),
      else: title
  end

  # The day each number's first line was added, from the log's history: newest commit
  # first, so the oldest occurrence is the one left standing. `-m` because a few entries
  # were first written while resolving a merge, and appear in no other commit.
  defp first_dates(log) do
    args = ["log", "--follow", "-m", "-p", "--format=@@date %ad", "--date=short", "--", log]

    case System.cmd("git", args, cd: @root) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.reduce({nil, %{}}, fn
          "@@date " <> date, {_date, acc} ->
            {String.trim(date), acc}

          line, {date, acc} ->
            case Regex.run(~r/^\+(\d+)\.\s/, line, capture: :all_but_first) do
              [n] -> {date, Map.put(acc, String.to_integer(n), date)}
              nil -> {date, acc}
            end
        end)
        |> elem(1)

      {_out, status} ->
        IO.puts(:stderr, "git log exited #{status}; dates are left out")
        %{}
    end
  end

  # -- supersession -----------------------------------------------------------

  # {newer, older, :whole | :part} for each replacement an entry states.
  defp relations(kind, entries) do
    stated =
      for {{^kind, newer}, olders} <- @stated, {older, how} <- olders, do: {newer, older, how}

    found =
      Enum.flat_map(entries, fn %{number: n, text: text} ->
        part =
          for [older] <-
                Regex.scan(~r/[Ss]upersedes the [^.]{0,80}? of\s+(?:Decision\s+)?(\d+)/, text,
                  capture: :all_but_first
                ),
              do: {n, String.to_integer(older), :part}

        whole =
          for [older] <-
                Regex.scan(~r/[Ss]upersedes\s+(?:Decision\s+)?(\d+)/, text,
                  capture: :all_but_first
                ) ++
                  Regex.scan(~r/[Ee]ntry (\d+) is over/, text, capture: :all_but_first),
              do: {n, String.to_integer(older), :whole}

        # Said by the older one, about the newer.
        by_older =
          for [newer] <-
                Regex.scan(~r/[Ss]uperseded in part by Decision\s+(\d+)/, text,
                  capture: :all_but_first
                ),
              do: {String.to_integer(newer), n, :part}

        part ++ whole ++ by_older
      end)

    Enum.uniq_by(stated ++ found, fn {newer, older, _how} -> {newer, older} end)
  end

  defp status(number, relations) do
    if Enum.any?(relations, &match?({_newer, ^number, :whole}, &1)),
      do: "superseded",
      else: "accepted"
  end

  defp supersedes(number, relations) do
    for({^number, older, _how} <- relations, do: older) |> Enum.uniq() |> Enum.sort()
  end

  defp issue(text) do
    case Regex.run(~r/\b(?:[Ii]ssues?|[Pp]art of|[Ff]ixes)\s+#(\d+)/, text,
           capture: :all_but_first
         ) do
      [n] -> String.to_integer(n)
      nil -> nil
    end
  end

  # -- paths ------------------------------------------------------------------

  defp paths(kind, entry, citations, index) do
    cited = Map.get(citations, {kind, entry.number}, MapSet.new())

    cond do
      MapSet.size(cited) > 0 ->
        {cited |> MapSet.to_list() |> Enum.sort(), :cited}

      (named = named(kind, entry.text, index)) != [] ->
        {named, :named}

      true ->
        {[directory(kind, entry)], :directory}
    end
  end

  # Decision citations in every tracked text file but the excluded ones, as
  # %{{kind, number} => files}. `Decisions 669, 674 and 676`, a list broken over a comment's
  # lines included.
  defp citations(files, numbers) do
    cite =
      ~r/(?:\b(root|TUI|TUI's|daemon|daemon's)\s+)?\bDecisions?\s+(\d+(?:(?:\s*,\s*(?:and\s+|or\s+)?|\s+and\s+|\s+or\s+)(?:(?:#|\/\/|\*|--|%)+\s*)?\d+)*)/

    logs = for {_kind, log, _dir} <- @logs, do: log

    for file <- files,
        file not in logs,
        not String.starts_with?(file, @not_citations),
        text <- [text(file)],
        text != nil,
        [_, qualifier, list] <- Regex.scan(cite, text),
        [n] <- Regex.scan(~r/\d+/, list),
        number = String.to_integer(n),
        reduce: %{} do
      acc ->
        key = {cited_kind(qualifier, number, file, numbers), number}
        Map.update(acc, key, MapSet.new([file]), &MapSet.put(&1, file))
    end
  end

  defp cited_kind(qualifier, number, file, numbers) do
    cond do
      qualifier in ["TUI", "TUI's"] -> :tui
      qualifier in ["daemon", "daemon's"] and MapSet.member?(numbers.daemon, number) -> :daemon
      qualifier == "root" -> :root
      String.starts_with?(file, "clients/tui/") and MapSet.member?(numbers.tui, number) -> :tui
      true -> :root
    end
  end

  # The tracked files and directories an entry names: a path written out, a file name that
  # only one tracked file has, a path relative to the log's own directory, or a module in
  # backticks, as the file that defines it.
  defp named(kind, text, index) do
    spans = for [span] <- Regex.scan(~r/`([^`\n]+)`/, text, capture: :all_but_first), do: span

    words =
      for [word] <-
            Regex.scan(
              ~r/(?<![\w\/.-])([\w.-]+(?:\/[\w.-]+)*\.(?:md|ex|exs|ts|tsx|js|mjs|rs|ya?ml|json|ps1|sh|toml|py|zig|cmd))(?![\w\/])/,
              text,
              capture: :all_but_first
            ),
          do: word

    logs = for {_kind, log, _dir} <- @logs, do: log

    (Enum.flat_map(spans ++ words, &resolve(kind, &1, index)) ++
       Enum.flat_map(spans, &module_file(kind, &1, index)))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in logs or String.starts_with?(&1, @not_citations)))
    |> Enum.sort()
  end

  defp resolve(kind, candidate, index) do
    path =
      candidate
      |> String.trim()
      |> String.trim_trailing("/")
      |> String.replace_prefix("./", "")
      |> String.replace(~r/[.,;:)]+$/, "")

    home = Map.get(@home, kind)
    known? = &(MapSet.member?(index.files, &1) or MapSet.member?(index.dirs, &1))

    cond do
      path == "" or String.contains?(path, [" ", "*", "<", "$"]) -> []
      known?.(path) and String.contains?(path, "/") -> [path]
      home && known?.(Path.join(home, path)) -> [Path.join(home, path)]
      known?.(path) and Path.extname(path) != "" -> [path]
      Path.extname(path) == "" -> []
      true -> unique(Enum.filter(index.all, &ends_with_path?(&1, path)))
    end
  end

  defp ends_with_path?(file, path), do: file == path or String.ends_with?(file, "/" <> path)

  defp unique([one]), do: [one]
  defp unique(_none_or_many), do: []

  defp module_file(kind, span, index) do
    case Regex.run(~r/^((?:[A-Z]\w*\.)*[A-Z]\w*)(?:\.[a-z_]\w*[!?]?(?:\/\d+)?)?$/, span,
           capture: :all_but_first
         ) do
      [module] ->
        home = Map.get(@home, kind, "apps/")

        case Map.get(index.modules, module) do
          nil ->
            # `Ledger` for `Troupe.Plane.Ledger`, when only one module is called that.
            for(
              {name, files} <- index.modules,
              String.ends_with?(name, "." <> module),
              file <- files,
              do: file
            )
            |> prefer(home)
            |> unique()

          files ->
            prefer(files, home)
        end

      nil ->
        []
    end
  end

  defp prefer(files, home) do
    case Enum.filter(files, &String.starts_with?(&1, home)) do
      [] -> files
      preferred -> preferred
    end
  end

  defp modules(files) do
    for file <- files,
        Path.extname(file) in [".ex", ".exs"],
        text <- [text(file)],
        text != nil,
        [module] <- Regex.scan(~r/^\s*defmodule\s+([\w.]+)\s+do/m, text, capture: :all_but_first),
        reduce: %{} do
      acc -> Map.update(acc, module, [file], &Enum.uniq(&1 ++ [file]))
    end
  end

  defp directory(kind, _entry) when kind in [:tui, :daemon], do: Map.fetch!(@home, kind)

  # A word in the heading the entry was under, or in its title, counts five times one in
  # its body.
  defp directory(:root, entry) do
    count = fn pattern, text -> length(Regex.scan(pattern, text)) end

    {dir, score} =
      @areas
      |> Enum.map(fn {dir, pattern} ->
        {dir,
         5 * count.(pattern, entry.section <> "\n" <> entry.title) + count.(pattern, entry.body)}
      end)
      |> Enum.max_by(fn {_dir, score} -> score end)

    if score == 0, do: "apps", else: dir
  end

  # -- writing ------------------------------------------------------------------

  defp gist(title) do
    if String.length(title) <= 150, do: title, else: shorten(title)
  end

  # At the last sentence or clause that ends between 60 and 150 characters in; failing
  # that, at a word, with an ellipsis.
  defp shorten(title) do
    clause =
      Enum.find_value([". ", "; ", " — "], fn mark ->
        title
        |> positions(mark)
        |> Enum.filter(&(&1 >= 60 and &1 <= 150))
        |> List.last()
        |> case do
          nil -> nil
          at -> String.slice(title, 0, at)
        end
      end)

    clause ||
      title
      |> String.slice(0, 148)
      |> String.replace(~r/[\s,;:—-]+\S*$/u, "")
      |> Kernel.<>("…")
  end

  defp positions(text, mark) do
    text
    |> :binary.matches(mark)
    |> Enum.map(fn {byte, _len} -> String.length(binary_part(text, 0, byte)) end)
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.split()
    |> Enum.reduce_while("", fn word, acc ->
      next = if acc == "", do: word, else: acc <> "-" <> word
      if String.length(next) > 48 and acc != "", do: {:halt, acc}, else: {:cont, next}
    end)
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(4, "0")

  # A value as YAML reads it back unchanged: plain where that is safe, double-quoted where
  # a plain scalar would mean something else (`: `, ` #`, a leading indicator).
  defp yaml(value) do
    plain? =
      value != "" and
        not Regex.match?(~r/^[\s\-?:,\[\]{}#&*!|>'"%@`]/, value) and
        not String.contains?(value, [": ", " #", "\t"]) and
        not String.ends_with?(value, [":", " "]) and
        not Regex.match?(
          ~r/^(?:true|false|yes|no|on|off|null|~|y|n|[-+.\d][\d_.:eE+-]*)$/i,
          value
        )

    if plain?,
      do: value,
      else: ~s(") <> String.replace(value, ["\\", ~s(")], &("\\" <> &1)) <> ~s(")
  end

  # -- the repository -----------------------------------------------------------

  defp tracked do
    case System.cmd("git", ["ls-files", "-z"], cd: @root) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&File.regular?(Path.join(@root, &1)))

      {_out, status} ->
        raise "git ls-files exited #{status}; this needs a git checkout"
    end
  end

  defp parents(file) do
    case Path.dirname(file) do
      "." -> []
      dir -> [dir | parents(dir)]
    end
  end

  defp read(path), do: File.read!(Path.join(@root, path))

  defp text(file) do
    content = read(file)
    if String.valid?(content) and not String.contains?(content, <<0>>), do: content
  end
end

SplitDecisions.main(System.argv())
