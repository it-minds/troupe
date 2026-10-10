defmodule Troupe.Onboard.Instructions do
  @moduledoc """
  The instruction files other tools keep in a repository, as proposals for Troupe's own
  (Decision 827; issue #516, slice 2): what they say, once, in the files sessions read.

  - **`CLAUDE.md`, `GEMINI.md` and Copilot's `.github/copilot-instructions.md`** are
    other tools' names for a directory's `AGENTS.md` (Copilot's at the root only, as
    Copilot reads it, Decision 806), and so is Claude Code's `.claude/CLAUDE.md` at the
    root. Their substance becomes one proposal for the `AGENTS.md` in the same directory
    (`target: :workspace`): what is there kept as it is, byte for byte, and what each
    file says that it does not, added after it, in that order (`CLAUDE.md`,
    `.claude/CLAUDE.md`, `GEMINI.md`, Copilot's). The first file is the proposal's
    `source` and the others its `also_from`, so a change to any of them is drift.
  - **The person's own.** `<config>/CLAUDE.md` and `<config>/GEMINI.md`, which Troupe
    read as its config directory's `AGENTS.md` until the readers were retired, and Claude
    Code's `~/.claude/CLAUDE.md` become one proposal for `<config>/AGENTS.md`
    (`target: :user`, named from the home directory, `~/...`), merged the same way. A
    file that is not really in the home directory (a config directory kept elsewhere) is
    skipped, saying so. `CLAUDE.local.md` is the person's own and usually not committed,
    so it is never proposed into a repository's file: it is skipped, with how to move it.
  - **Merge, don't duplicate.** A file is read as Markdown units: a paragraph, a list
    item, a fenced block, a table, a heading. A unit the directory's `AGENTS.md` (or its
    `.agents/AGENTS.md`, or a file before it in the proposal) already says is left out,
    and said means one of two things, both conservative: the same text, spaces aside, or
    the same rule as `troupe instructions check` calls a duplicate (a paragraph or list
    item of five words or more, compared without case, code marks, emphasis or a final
    period; `Troupe.Instructions.Check.Text`). Nothing else is judged the same, so a
    reworded rule is proposed again and the person reads the diff; a file's own repeats
    are its own. A unit added keeps the heading it was under, written before it. A line
    that only imports the `AGENTS.md` being written (`@AGENTS.md`) is left out, and a
    first heading that names the other tool's file (`# CLAUDE.md`) is written
    `# AGENTS.md`, or left out when there is a file already. When nothing is left to add,
    nothing is proposed, and the file is listed as skipped, saying so.
  - **Rules.** Cursor's `.cursor/rules/*.mdc` (the root's, and a directory's, whose globs
    are rewritten from the root: `src/**` under `web/` is `web/src/**`, an always rule
    there `web/**`), its legacy root `.cursorrules` (always applied), and Copilot's
    `.github/instructions/*.instructions.md` (`applyTo` as `globs`, `**` as always)
    become `.troupe/rules/<name>.md` (`target: :repo`): Markdown with the front matter
    Decision 809 read, `description`, `globs` (a list) and `alwaysApply`, meaning what it
    meant there, and the body. A key no rule has is left out with a note. Names are made
    lowercase, with dashes; a nested rule's is its directory's then its own
    (`web-style`); two that come out the same are told apart by a number.

  Nothing here writes, and the same files give the same proposals. A file that is a link
  out of the workspace is not read, and one that is the directory's `AGENTS.md` under
  another name gives nothing to add; both are listed as skipped, as is everything else
  found and not proposed, with why.

  The files are found under the workspace as `troupe instructions check` finds them: what
  `.gitignore` hides, `node_modules`, a repository inside this one and every hidden
  directory but `.github` and `.cursor` are not entered; the root's own files are looked
  for by name whatever `.gitignore` says, since their tools read them anyway.
  """

  @behaviour Troupe.Onboard.Source

  alias Troupe.{Gitignore, Paths, Workspace}
  alias Troupe.Instructions.Check.Text
  alias Troupe.Protocol.AgentDefinition

  # Other tools' names for a directory's `AGENTS.md`, in the order they are added.
  @aliases ["CLAUDE.md", "GEMINI.md"]
  @claude_dir ".claude/CLAUDE.md"
  @local "CLAUDE.local.md"
  @copilot ".github/copilot-instructions.md"
  @order ["CLAUDE.md", @claude_dir, "GEMINI.md", @copilot]
  @copilot_rules ".github/instructions"
  @copilot_ext ".instructions.md"
  @cursor_rules ".cursor/rules"
  @legacy ".cursorrules"

  # The hidden directories a search enters, for the files above.
  @entered ~w(.github .cursor)

  # A rule's own front matter, as Decision 809 reads it.
  @rule_keys ~w(description globs alwaysApply)

  @typedoc "One file onboarding may write, and what it came from."
  @type proposal :: Troupe.Onboard.Source.proposal()

  @doc "Whether the workspace's root has any of the files this source reads: a look, not a read."
  @spec found?(Path.t()) :: boolean()
  @impl Troupe.Onboard.Source
  def found?(workspace) do
    (@aliases ++ [@claude_dir, @copilot, @legacy, @copilot_rules, @cursor_rules])
    |> Enum.any?(&File.exists?(Path.join(workspace, &1)))
  end

  @doc """
  The proposals for the instruction files in `workspace`: the `AGENTS.md` files first,
  the root's then each directory's, then the rules, by path, then the person's own
  `AGENTS.md`. `opts`: `home` and `config_dir`, the person's, for a test.
  """
  @spec proposals(Path.t(), keyword()) :: [proposal()]
  @impl Troupe.Onboard.Source
  def proposals(workspace, opts \\ []), do: survey(workspace, opts).proposals

  @doc "Every file found that gave no proposal, and why."
  @spec skipped(Path.t(), keyword()) :: [%{source: String.t(), reason: String.t()}]
  @impl Troupe.Onboard.Source
  def skipped(workspace, opts \\ []), do: survey(workspace, opts).skipped

  @doc "`proposals/2` and `skipped/2` from one look at the files."
  @spec survey(Path.t(), keyword()) :: %{proposals: [proposal()], skipped: [map()]}
  def survey(workspace, opts \\ []) do
    root = Path.expand(workspace)
    {own, own_skips} = own(opts)

    {proposals, skipped} =
      case Workspace.real_path(root) do
        {:ok, real} -> survey(root, real, find(root))
        {:error, _reason} -> {[], []}
      end

    %{
      proposals: Enum.sort_by(proposals ++ own, &{target_rank(&1.target), &1.path}),
      skipped: Enum.sort_by(skipped ++ own_skips, &{&1.source, &1.reason})
    }
  end

  defp target_rank(:workspace), do: 0
  defp target_rank(:repo), do: 1
  defp target_rank(:user), do: 2

  defp survey(root, real, found) do
    {inside, outside} = Enum.split_with(found, fn {_kind, path} -> inside?(root, real, path) end)

    outside =
      for {_kind, path} <- outside,
          do: skip(path, "it is a link to outside the workspace, and is not read")

    {locals, inside} = Enum.split_with(inside, fn {kind, _path} -> kind == :local end)

    locals =
      for {_kind, path} <- locals,
          do:
            skip(
              path,
              "not onboarded: CLAUDE.local.md is your own and usually not committed, so it " <>
                "is not proposed into a file that is; move what it says into your config " <>
                "directory's AGENTS.md by hand, or keep it"
            )

    {files, rules} =
      Enum.split_with(inside, fn {kind, _path} -> kind in [:alias, :claude_dir, :copilot] end)

    {agents_md, agents_md_skips} = agents_md(root, real, files)
    {rule_files, rule_skips} = rules(root, rules)
    {agents_md ++ rule_files, outside ++ locals ++ agents_md_skips ++ rule_skips}
  end

  ## Finding

  defp find(root) do
    ignore = Gitignore.load(root)

    (walk(root, "", ignore) ++ at_root(root))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&candidate/1)
  end

  defp walk(root, rel, ignore) do
    dir = if rel == "", do: root, else: Path.join(root, rel)

    case File.ls(dir) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&visit(root, rel, &1, ignore))
      {:error, _reason} -> []
    end
  end

  defp visit(root, rel, name, ignore) do
    path = if rel == "", do: name, else: rel <> "/" <> name

    if name in [".git", "node_modules"] or Gitignore.ignored?(ignore, path),
      do: [],
      else: entry(root, path, name, ignore)
  end

  # A directory is entered unless it is hidden (but for the two that hold these files) or
  # another repository; a file, or a link, is a name to look at. A link is not followed.
  defp entry(root, path, name, ignore) do
    full = Path.join(root, path)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} ->
        cond do
          String.starts_with?(name, ".") and name not in @entered -> []
          File.exists?(Path.join(full, ".git")) -> []
          true -> walk(root, path, ignore)
        end

      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
        [path]

      _other ->
        []
    end
  end

  # The root's own files by name, whatever `.gitignore` says of them.
  defp at_root(root) do
    files =
      Enum.filter(
        @aliases ++ [@claude_dir, @local, @copilot, @legacy],
        &file?(Path.join(root, &1))
      )

    listed =
      for dir <- [@copilot_rules, @cursor_rules],
          {:ok, names} <- [File.ls(Path.join(root, dir))],
          name <- names,
          file?(Path.join([root, dir, name])),
          do: dir <> "/" <> name

    files ++ listed
  end

  defp file?(path),
    do: match?({:ok, %File.Stat{type: t}} when t in [:regular, :symlink], File.lstat(path))

  defp candidate(path) do
    case kind(path, Path.basename(path), parent(path)) do
      nil -> []
      kind -> [{kind, path}]
    end
  end

  defp kind(@claude_dir, _name, _dir), do: :claude_dir
  defp kind(_path, name, _dir) when name in @aliases, do: :alias
  defp kind(_path, @local, _dir), do: :local
  defp kind(_path, @legacy, _dir), do: :legacy

  defp kind(path, name, dir) do
    cond do
      path == @copilot or String.ends_with?(path, "/" <> @copilot) -> :copilot
      under?(dir, @copilot_rules) and String.ends_with?(name, @copilot_ext) -> :copilot_rule
      true -> rule_kind(name, dir)
    end
  end

  defp rule_kind(name, dir) do
    cond do
      String.downcase(Path.extname(name)) != ".mdc" -> nil
      under?(dir, @cursor_rules) -> :cursor_rule
      deeper?(dir) -> :deep_rule
      true -> nil
    end
  end

  defp under?(dir, suffix), do: dir == suffix or String.ends_with?(dir, "/" <> suffix)

  defp deeper?(dir),
    do:
      String.starts_with?(dir, @cursor_rules <> "/") or
        String.contains?(dir, "/" <> @cursor_rules <> "/")

  ## AGENTS.md

  # One proposal per directory that has another tool's name for its `AGENTS.md`; Copilot's
  # file counts at the root only.
  defp agents_md(root, real, files) do
    {copilot_nested, files} =
      Enum.split_with(files, fn {kind, path} -> kind == :copilot and path != @copilot end)

    {hidden, files} = Enum.split_with(files, fn {kind, path} -> hidden?(owner(kind, path)) end)

    skips =
      for(
        {_kind, path} <- copilot_nested,
        do: skip(path, "not onboarded: Copilot reads its file at the repository root only")
      ) ++
        for {_kind, path} <- hidden,
            do: skip(path, "not onboarded: no session reads an AGENTS.md in a hidden directory")

    {proposals, more} =
      files
      |> Enum.group_by(fn {kind, path} -> owner(kind, path) end, &elem(&1, 1))
      |> Enum.sort()
      |> Enum.map(fn {dir, paths} -> directory(root, real, dir, order(dir, paths)) end)
      |> Enum.unzip()

    {Enum.concat(proposals), skips ++ Enum.concat(more)}
  end

  defp owner(:alias, path), do: parent(path)
  defp owner(_kind, _path), do: ""

  defp hidden?(dir), do: dir |> String.split("/") |> Enum.any?(&String.starts_with?(&1, "."))

  # `CLAUDE.md`, then `.claude/CLAUDE.md`, then `GEMINI.md`, then Copilot's.
  defp order(dir, paths) do
    Enum.sort_by(paths, fn path ->
      here = if dir == "", do: path, else: String.replace_prefix(path, dir <> "/", "")
      {Enum.find_index(@order, &(&1 == here)) || 9, path}
    end)
  end

  defp directory(root, real, dir, sources) do
    agents = join(dir, "AGENTS.md")
    file = Path.join(root, agents)

    if File.exists?(file) and not inside?(root, real, agents) do
      outside = "#{agents} is a link to outside the workspace, and is not written"
      {[], Enum.map(sources, &skip(&1, outside))}
    else
      dot = join(dir, ".agents/AGENTS.md")

      spot = %{
        target: :workspace,
        path: agents,
        shown: agents,
        file: file,
        existing: read_inside(root, real, agents),
        also: read_inside(root, real, dot),
        also_shown: dot
      }

      sources = Enum.map(sources, &{&1, Path.join(root, &1)})
      sources(spot, sources)
    end
  end

  # The other tools' files for one `AGENTS.md`, each `{name, file}`: those that are that
  # file under another name give nothing, the rest are read and merged.
  defp sources(spot, sources) do
    {same, sources} =
      Enum.split_with(sources, fn {_name, file} -> same_file?(file, spot.file) end)

    renamed = "it is #{spot.shown} under another name, so there is nothing to add"

    {read, unread} =
      sources
      |> Enum.map(fn {name, file} -> read_source(name, file) end)
      |> Enum.split_with(&is_tuple/1)

    {proposal, skips} = merge(spot, read)
    {proposal, Enum.map(same, fn {name, _file} -> skip(name, renamed) end) ++ unread ++ skips}
  end

  # `{source, file, bytes}`, or why not, as a skipped entry.
  defp read_source(source, file) do
    case File.read(file) do
      {:ok, bytes} ->
        if String.trim(bytes) == "", do: skip(source, "it is empty"), else: {source, file, bytes}

      {:error, reason} ->
        skip(source, "it cannot be read: #{:file.format_error(reason)}")
    end
  end

  defp merge(_spot, []), do: {[], []}

  defp merge(spot, read) do
    known = [spot.existing, spot.also] |> Enum.reject(&is_nil/1) |> Enum.map(&known/1) |> union()

    {added, _known} =
      Enum.map_reduce(read, known, fn {source, file, bytes}, known ->
        # Merging when something is already there, the file's or an earlier source's.
        merging? = spot.existing != nil or known.started?
        {text, notes} = additions(source, file, lf(bytes), known, merging?, spot)
        known = union([known, known(lf(bytes))])
        {{source, bytes, text, notes}, %{known | started?: known.started? or text != ""}}
      end)

    if Enum.all?(added, fn {_s, _b, text, _n} -> text == "" end) do
      said = if spot.also, do: "#{spot.shown} or #{spot.also_shown}", else: spot.shown

      {[],
       for(
         {source, _b, _t, _n} <- added,
         do: skip(source, "everything it says is in #{said} already")
       )}
    else
      {[proposal(spot, added)], []}
    end
  end

  defp proposal(spot, added) do
    [{source, bytes, _text, _notes} | rest] = added
    existing = spot.existing

    parts =
      if(existing, do: [existing |> lf() |> String.trim_trailing()], else: []) ++
        for({_s, _b, text, _n} <- added, text != "", do: text)

    content = Enum.join(parts, "\n\n") <> "\n"
    content = if existing && String.contains?(existing, "\r\n"), do: crlf(content), else: content

    notes =
      Enum.flat_map(added, fn
        {other, _b, "", _notes} -> ["#{other} adds nothing: everything it says is said already."]
        {_s, _b, _text, notes} -> notes
      end)

    %{
      target: spot.target,
      path: spot.path,
      content: content,
      source: source,
      source_hash: sha256(bytes),
      also_from: for({s, b, _t, _n} <- rest, do: %{source: s, source_hash: sha256(b)}),
      notes: notes
    }
  end

  # What one file adds, as text, and the notes saying what was left out or changed.
  defp additions(source, file, text, known, merging?, spot) do
    {lines, imports} = without_self_imports(text, Path.dirname(file), spot.file)
    {lines, title} = retitle(lines, Path.basename(file), merging?)
    text = Enum.join(lines, "\n")
    units = units(text)
    {kept, dropped} = Enum.split_with(units, &(&1.kind == :heading or not said?(&1, known)))

    added =
      cond do
        Enum.all?(kept, &(&1.kind == :heading)) -> ""
        dropped == [] -> text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim()
        true -> rebuild(kept, merging?)
      end

    notes =
      Enum.map(
        imports,
        &"The line `#{&1}` of #{source} is left out: it imports the file it would be written into."
      ) ++
        title_note(source, title, merging?) ++
        moved_note(source, file, text, spot) ++ dropped_note(source, dropped)

    {added, notes}
  end

  defp title_note(_source, nil, _merging?), do: []

  defp title_note(source, title, false),
    do: ["The title `#{title}` of #{source} is written `# AGENTS.md`."]

  defp title_note(source, title, true),
    do: ["The title `#{title}` of #{source} is left out: what it adds goes after what is there."]

  # A file from another directory than the AGENTS.md it goes into: its `@` imports are
  # read from where they land.
  defp moved_note(source, file, text, spot) do
    if Path.dirname(file) != Path.dirname(spot.file) and text =~ ~r/(?:^|\s)@[\w.~-]*[\/.]\w/m,
      do: [
        "An @ import in #{source} is read from beside #{spot.shown} once it is there, not from beside #{source}."
      ],
      else: []
  end

  defp dropped_note(_source, []), do: []

  defp dropped_note(source, [_one]),
    do: ["1 paragraph or list item of #{source} is left out: it is said already."]

  defp dropped_note(source, dropped),
    do: [
      "#{length(dropped)} paragraphs or list items of #{source} are left out: they are said already."
    ]

  # A line that is only an `@` import of the file being written.
  defp without_self_imports(text, from, agents_file) do
    {imports, lines} =
      text |> String.split("\n") |> Enum.split_with(&self_import?(&1, from, agents_file))

    {lines, Enum.map(imports, &String.trim/1)}
  end

  defp self_import?(line, from, agents_file) do
    case Regex.run(~r/^\s*@(\S+)\s*$/, line) do
      [_all, spec] -> same_path?(Path.expand(spec, from), agents_file)
      nil -> false
    end
  end

  # The first heading, when it is a title naming the other tool's file: `# AGENTS.md` in a
  # new file, and left out of an addition to one, which has its own.
  defp retitle(lines, name, merging?) do
    names = [String.downcase(name), String.downcase(Path.rootname(name))]

    with i when is_integer(i) <- Enum.find_index(lines, &(String.trim(&1) != "")),
         line = Enum.at(lines, i),
         [_all, title] <- Regex.run(~r/^#\s+(.+?)\s*#*\s*$/, line),
         true <- String.downcase(title) in names do
      if merging?,
        do: {List.delete_at(lines, i), String.trim(line)},
        else: {List.replace_at(lines, i, "# AGENTS.md"), String.trim(line)}
    else
      _no_title -> {lines, nil}
    end
  end

  # The units kept, each under the heading it was under, written once before the first of
  # them; a file's title (a level-one heading) only when nothing is there before it.
  defp rebuild(kept, merging?) do
    {pieces, _last} =
      Enum.flat_map_reduce(kept, nil, fn
        %{kind: :heading}, last ->
          {[], last}

        unit, last ->
          heading = unit.heading

          if heading != nil and heading != last and not (merging? and heading.level == 1),
            do: {[heading, unit], heading},
            else: {[unit], last}
      end)

    pieces
    |> Enum.chunk_every(2, 1)
    |> Enum.map_join(fn
      [a, b] ->
        text(a) <>
          if(a.kind == :item and b.kind == :item and a.block == b.block, do: "\n", else: "\n\n")

      [a] ->
        text(a)
    end)
  end

  defp text(unit), do: Enum.join(unit.lines, "\n")

  ## Units

  # Markdown as units, each with its lines as written, the heading it is under, and the
  # block it belongs to (list items of one list share one).
  defp units(text) do
    state = %{units: [], cur: nil, fence: nil, block: 0, heading: nil}

    text
    |> String.split("\n")
    |> Enum.reduce(state, &line/2)
    |> close()
    |> Map.fetch!(:units)
    |> Enum.reverse()
  end

  defp line(line, %{fence: fence} = state) when is_binary(fence) do
    state = add(state, line)

    if Regex.match?(~r/^\s*#{Regex.escape(fence)}/, line),
      do: %{close(state) | fence: nil},
      else: state
  end

  defp line(line, state) do
    case line_kind(line) do
      {:fence, fence} -> state |> close() |> start(:code, line) |> Map.put(:fence, fence)
      :blank -> state |> close() |> next_block()
      {:heading, level} -> heading(state, line, level)
      :table -> table(state, line)
      :other -> state |> close() |> start(:other, line) |> close() |> next_block()
      :item -> item(state, line)
      :text -> text_line(state, line)
    end
  end

  # What a line starts, as Markdown has it: a fence, a heading, a table's row, a rule or
  # HTML line, a list item, or text.
  defp line_kind(line) do
    cond do
      fence = Regex.run(~r/^\s*(```|~~~)/, line) ->
        {:fence, List.last(fence)}

      String.trim(line) == "" ->
        :blank

      marks = Regex.run(~r/^\s{0,3}(\#{1,6})(?:\s|$)/, line) ->
        {:heading, String.length(List.last(marks))}

      line =~ ~r/^\s*\|/ ->
        :table

      line =~ ~r/^\s{0,3}([-*_])(\s*\1){2,}\s*$/ ->
        :other

      line =~ ~r/^\s*</ ->
        :other

      line =~ ~r/^\s*(?:[-*+]|\d+[.)])\s+/ ->
        :item

      true ->
        :text
    end
  end

  defp heading(state, line, level) do
    unit = %{kind: :heading, lines: [line], level: level, heading: nil, block: state.block}
    state = close(state)
    %{state | units: [unit | state.units], heading: unit, block: state.block + 1}
  end

  defp table(%{cur: %{kind: :table}} = state, line), do: add(state, line)
  defp table(state, line), do: state |> close() |> start(:table, line)

  # Items of one list share a block; a list after anything else starts one.
  defp item(%{cur: %{kind: :item}} = state, line), do: state |> close() |> start(:item, line)
  defp item(state, line), do: state |> close() |> next_block() |> start(:item, line)

  # A line of text continues a paragraph or an item, as Markdown's lazy lines do.
  defp text_line(%{cur: %{kind: kind}} = state, line) when kind in [:para, :item],
    do: add(state, line)

  defp text_line(state, line), do: state |> close() |> next_block() |> start(:para, line)

  defp start(state, kind, line),
    do: %{
      state
      | cur: %{kind: kind, lines: [line], level: nil, heading: state.heading, block: state.block}
    }

  defp add(%{cur: cur} = state, line), do: %{state | cur: %{cur | lines: [line | cur.lines]}}

  defp close(%{cur: nil} = state), do: state

  defp close(%{cur: cur} = state),
    do: %{state | units: [%{cur | lines: Enum.reverse(cur.lines)} | state.units], cur: nil}

  defp next_block(state), do: %{state | block: state.block + 1}

  ## The person's own

  # The person's own instruction files, `<config>/CLAUDE.md` and `<config>/GEMINI.md`
  # (Troupe's config directory's other names for its `AGENTS.md`, until the readers were
  # retired) and Claude Code's `~/.claude/CLAUDE.md`, as one proposal for
  # `<config>/AGENTS.md`. Each is named from the home directory, as a `:user` source must
  # be, and one that is not really in it is skipped.
  defp own(opts) do
    home = opts |> Keyword.get_lazy(:home, &System.user_home!/0) |> Path.expand()
    config = opts |> Keyword.get_lazy(:config_dir, &Paths.config_dir/0) |> Path.expand()

    files =
      [
        Path.join(config, "CLAUDE.md"),
        Path.join(config, "GEMINI.md"),
        Path.join(home, @claude_dir)
      ]
      |> Enum.filter(&file?/1)

    with [_ | _] <- files,
         {:ok, real_home} <- Workspace.real_path(home),
         {:ok, real_config} <- Workspace.real_path(config) do
      own(files, real_home, config, real_config)
    else
      _none -> {[], []}
    end
  end

  defp own(files, real_home, config, real_config) do
    agents = Path.join(config, "AGENTS.md")
    shown = Paths.display(agents)
    {named, away} = files |> Enum.map(&home_name(&1, real_home)) |> Enum.split_with(&is_tuple/1)

    cond do
      named == [] ->
        {[], away}

      File.exists?(agents) and not under_real?(agents, real_config) ->
        outside = "#{shown} is a link to outside your config directory, and is not written"
        {[], away ++ Enum.map(named, fn {name, _file} -> skip(name, outside) end)}

      true ->
        spot = %{
          target: :user,
          path: "AGENTS.md",
          shown: shown,
          file: agents,
          existing: if(File.regular?(agents), do: read_text(agents)),
          also: nil,
          also_shown: nil
        }

        {proposals, skips} = sources(spot, named)
        {proposals, away ++ skips}
    end
  end

  # `{"~/...", file}` for a file really in the home directory, or why not.
  defp home_name(file, real_home) do
    with {:ok, real} <- Workspace.real_path(file),
         true <- under_real?(real, real_home) do
      rest =
        real
        |> String.slice(String.length(real_home) + 1, String.length(real))
        |> String.replace("\\", "/")

      {"~/" <> rest, file}
    else
      _elsewhere ->
        skip(
          Paths.display(file),
          "not onboarded: it is not in your home directory, where onboarding takes your own files from"
        )
    end
  end

  defp read_text(file) do
    case File.read(file) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  ## Said already

  # What a file says, as the two keys a unit is compared by: its text, spaces aside, and
  # the rules `troupe instructions check` compares files by.
  defp known(text) do
    exact = for unit <- units(text), unit.kind != :heading, into: MapSet.new(), do: exact(unit)
    rules = for {_line, rule} <- Text.read(text).rules, into: MapSet.new(), do: rule
    %{exact: exact, rules: rules, started?: false}
  end

  defp union(sets) do
    Enum.reduce(sets, %{exact: MapSet.new(), rules: MapSet.new(), started?: false}, fn set, acc ->
      %{
        exact: MapSet.union(acc.exact, set.exact),
        rules: MapSet.union(acc.rules, set.rules),
        started?: acc.started? or set.started?
      }
    end)
  end

  defp said?(unit, known) do
    MapSet.member?(known.exact, exact(unit)) or
      (unit.kind in [:para, :item] and rule_said?(unit, known))
  end

  defp rule_said?(unit, known) do
    case Text.read(text(unit)).rules do
      [{_line, rule}] -> MapSet.member?(known.rules, rule)
      _other -> false
    end
  end

  defp exact(unit) do
    unit.lines
    |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/\s+/, " ")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  ## Rules

  defp rules(root, files) do
    {placed, skips} =
      Enum.reduce(files, {[], []}, fn {kind, path} = file, {placed, skips} ->
        case placement(kind, path) do
          {:ok, owner} -> {placed ++ [{file, owner}], skips}
          {:skip, reason} -> {placed, skips ++ [skip(path, reason)]}
        end
      end)

    {proposals, more} =
      placed
      |> Enum.sort_by(fn {{kind, path}, owner} -> {owner != "", rank(kind), path} end)
      |> Enum.map_reduce({%{}, []}, fn {{kind, path}, owner}, {taken, skipped} ->
        case rule(root, kind, path, owner, taken) do
          {:ok, proposal, name} -> {[proposal], {Map.put(taken, name, path), skipped}}
          {:skip, reason} -> {[], {taken, skipped ++ [skip(path, reason)]}}
        end
      end)

    {Enum.concat(proposals), skips ++ elem(more, 1)}
  end

  defp rank(:cursor_rule), do: 0
  defp rank(:legacy), do: 1
  defp rank(:copilot_rule), do: 2

  defp placement(:cursor_rule, path), do: {:ok, up(path, 3)}

  defp placement(:legacy, path) do
    if parent(path) == "",
      do: {:ok, ""},
      else: {:skip, "not onboarded: Cursor reads .cursorrules at the repository root only"}
  end

  defp placement(:copilot_rule, path) do
    if up(path, 3) == "",
      do: {:ok, ""},
      else:
        {:skip, "not onboarded: Copilot reads .github/instructions at the repository root only"}
  end

  defp placement(:deep_rule, _path),
    do:
      {:skip,
       "not onboarded: onboarding brings in the rules directly in .cursor/rules, not in a folder under it"}

  defp rule(root, kind, path, owner, taken) do
    case File.read(Path.join(root, path)) do
      {:ok, bytes} -> rule_from(kind, path, owner, bytes, taken)
      {:error, reason} -> {:skip, "it cannot be read: #{:file.format_error(reason)}"}
    end
  end

  defp rule_from(kind, path, owner, bytes, taken) do
    {fields, body} = front(kind, bytes |> lf() |> String.trim_leading("﻿"))

    with :ok <- if(body == "", do: {:skip, "it has nothing but its front matter"}, else: :ok),
         {:ok, name, name_notes} <- name(kind, path, owner, taken) do
      {meta, meta_notes} = meta(kind, fields, owner)

      proposal = %{
        target: :repo,
        path: "rules/#{name}.md",
        content: render_rule(meta) <> body <> "\n",
        source: path,
        source_hash: sha256(bytes),
        also_from: [],
        notes: meta_notes ++ name_notes
      }

      {:ok, proposal, name}
    end
  end

  # When a rule applies, as Decision 809 reads Cursor's front matter, Copilot's `applyTo`
  # read as globs, and a nested rule's from the root.
  defp meta(:legacy, _fields, _owner),
    do:
      {%{description: nil, globs: [], always: true},
       ["Cursor's .cursorrules applied always, which the rule says with alwaysApply: true."]}

  defp meta(:cursor_rule, fields, owner) do
    meta = %{
      description: description(fields),
      globs: globs(fields["globs"]),
      always: String.downcase(scalar(fields["alwaysApply"])) == "true"
    }

    {meta, nested_notes} = nested(meta, owner)
    {meta, extra_notes(fields, @rule_keys) ++ nested_notes ++ manual_note(meta)}
  end

  defp meta(:copilot_rule, fields, _owner) do
    globs = globs(fields["applyTo"])
    everything? = globs != [] and Enum.all?(globs, &(&1 in ["**", "**/*", "*"]))

    meta = %{
      description: description(fields),
      globs: if(everything?, do: [], else: globs),
      always: everything?
    }

    notes =
      cond do
        everything? ->
          [
            "applyTo: #{Enum.join(globs, ", ")} applies to every file, which the rule says with alwaysApply: true."
          ]

        globs != [] ->
          ["applyTo is written as globs."]

        meta.description != nil ->
          [
            "It has no applyTo: it is listed by its description, for the agent to read when that fits."
          ]

        true ->
          []
      end

    {meta, extra_notes(fields, ~w(applyTo description)) ++ notes ++ manual_note(meta)}
  end

  # A nested rule was read once the session worked under its directory, its globs from
  # there: from `.troupe/rules/` they are written from the root.
  defp nested(meta, ""), do: {meta, []}

  defp nested(%{always: true} = meta, owner),
    do:
      {%{meta | always: false, globs: [owner <> "/**"]},
       [
         "alwaysApply under #{owner}/ applied once the session worked there, which globs: #{owner}/** says from the root."
       ]}

  defp nested(%{globs: [_ | _] = globs} = meta, owner) do
    globs = Enum.map(globs, &from_root(owner, &1))

    {%{meta | globs: globs},
     ["Its globs were from #{owner}/, and are written from the root: #{Enum.join(globs, ", ")}."]}
  end

  defp nested(%{description: d} = meta, owner) when is_binary(d),
    do:
      {meta,
       [
         "It was listed once the session worked under #{owner}/; from .troupe/rules/ it is listed in every session."
       ]}

  defp nested(meta, _owner), do: {meta, []}

  # A glob from a directory as a glob from the root, as Decision 809 matches one: one with
  # a `/` is a path from the directory, one without a file's name in any directory below.
  defp from_root(owner, glob) do
    glob = glob |> String.trim_leading("./") |> String.trim_leading("/")
    glob = if String.ends_with?(glob, "/"), do: glob <> "**", else: glob

    if String.contains?(glob, "/"),
      do: owner <> "/" <> glob,
      else: owner <> "/**/" <> glob
  end

  defp manual_note(%{always: false, globs: [], description: nil}),
    do: [
      "It has no alwaysApply, globs or description, so a session never joins it by itself: give it one, or leave it out."
    ]

  defp manual_note(_meta), do: []

  defp extra_notes(fields, keys) do
    for key <- fields |> Map.keys() |> Enum.sort(),
        key not in keys,
        do: "#{key} is not carried: a rule's front matter is description, globs and alwaysApply."
  end

  defp render_rule(meta) do
    lines =
      [
        meta.description && "description: #{Jason.encode!(meta.description)}",
        meta.globs != [] && "globs: [#{Enum.map_join(meta.globs, ", ", &Jason.encode!/1)}]",
        meta.always && "alwaysApply: true"
      ]
      |> Enum.filter(& &1)

    if lines == [], do: "", else: "---\n" <> Enum.join(lines, "\n") <> "\n---\n"
  end

  # The rule's name: its file's, a nested one's directory's before it, as a name may be
  # (lowercase letters, digits and dashes), and one more than the last taken when two
  # come out the same.
  defp name(kind, path, owner, taken) do
    base = base_name(kind, path)
    wanted = if owner == "", do: base, else: String.replace(owner, "/", "-") <> "-" <> base
    slug = slug(wanted)

    if AgentDefinition.valid_name?(slug) do
      name = free(slug, taken)
      {:ok, name, name_notes(name, slug, wanted, taken)}
    else
      {:skip, "not onboarded: its name gives no rule name onboarding can write"}
    end
  end

  defp base_name(:legacy, _path), do: "cursorrules"

  defp base_name(:copilot_rule, path),
    do: path |> Path.basename() |> String.replace_suffix(@copilot_ext, "")

  defp base_name(:cursor_rule, path), do: path |> Path.basename() |> Path.rootname()

  defp name_notes(name, slug, _wanted, taken) when name != slug,
    do: ["Named #{name}: #{slug} is #{taken[slug]}'s."]

  defp name_notes(_name, slug, wanted, _taken) when slug != wanted,
    do: ["Named #{slug}: a rule's name is lowercase letters, digits and dashes."]

  defp name_notes(_name, _slug, _wanted, _taken), do: []

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> String.trim("-")
  end

  defp free(slug, taken) do
    if Map.has_key?(taken, slug),
      do:
        Enum.find(Stream.iterate(2, &(&1 + 1)), &(not Map.has_key?(taken, "#{slug}-#{&1}")))
        |> then(&"#{slug}-#{&1}"),
      else: slug
  end

  ## Front matter, as Decision 809 reads it

  # A rule's front matter and its body. Read a line per key, as Cursor writes it and YAML
  # would not always read it (`globs: *.ts` is an alias to YAML); Copilot's is YAML, which
  # this reads the same.
  defp front(:legacy, text), do: {%{}, String.trim(text)}

  defp front(_kind, text) do
    case String.split(text, "\n") do
      [first | rest] ->
        with "---" <- String.trim(first),
             {front, [_close | body]} <- Enum.split_while(rest, &(String.trim(&1) != "---")) do
          {keys(front), body |> Enum.join("\n") |> String.trim()}
        else
          _none -> {%{}, String.trim(text)}
        end
    end
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

  defp description(fields) do
    case scalar(fields["description"]) do
      "" -> nil
      description -> description
    end
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
    # A quoted list of globs, as Copilot's `applyTo: "**/*.ts,**/*.tsx"`, is one string.
    value = lines |> Enum.join(" ") |> unquote_value()

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

  ## Paths

  defp inside?(root, real, path) do
    case Workspace.real_path(Path.join(root, path)) do
      {:ok, resolved} ->
        key = Workspace.compare_key(resolved)
        String.starts_with?(key, Workspace.compare_key(real) <> "/")

      {:error, _reason} ->
        false
    end
  end

  defp same_file?(file, other), do: File.exists?(other) and same_path?(file, other)

  # Whether `path` is really under `real` (a real path).
  defp under_real?(path, real) do
    case Workspace.real_path(path) do
      {:ok, resolved} ->
        String.starts_with?(Workspace.compare_key(resolved), Workspace.compare_key(real) <> "/")

      {:error, _reason} ->
        false
    end
  end

  defp same_path?(a, b) do
    with {:ok, a} <- Workspace.real_path(a),
         {:ok, b} <- Workspace.real_path(b) do
      Workspace.compare_key(a) == Workspace.compare_key(b)
    else
      _ -> false
    end
  end

  # A file of the workspace's that is really inside it, or `nil`.
  defp read_inside(root, real, path) do
    with true <- File.regular?(Path.join(root, path)),
         true <- inside?(root, real, path),
         {:ok, text} <- File.read(Path.join(root, path)) do
      text
    else
      _ -> nil
    end
  end

  defp parent(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  defp up(path, 0), do: path
  defp up(path, n), do: path |> parent() |> up(n - 1)

  defp join("", name), do: name
  defp join(dir, name), do: dir <> "/" <> name

  defp skip(source, reason), do: %{source: source, reason: reason}

  defp lf(text), do: String.replace(text, "\r\n", "\n")
  defp crlf(text), do: String.replace(text, "\n", "\r\n")

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
