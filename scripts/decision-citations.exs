# No change adds a decision number to code: the code says why in its own words.
#
#     elixir scripts/decision-citations.exs                  # against origin/main
#     elixir scripts/decision-citations.exs --base REV       # against REV
#
# A comment that says `Decision 646` sends its reader out of the code into a document, and
# makes the document's number something hundreds of comments depend on: a decision that is
# renumbered, merged or superseded rots them, and nothing fails. Documentation depends on
# code, never the other way round (#422). A decision names the paths it governs in its
# front matter, and the code states its own invariant where it applies ("this check is
# fenced by the epoch; moving it after the write reopens the window"), so a reader who
# never opens `docs/` still learns why the line is there.
#
# The citations already in the code stay until their file is touched for another reason,
# so this checks a change, not the tree. It compares each changed code file (by extension,
# below) with the same file at the merge base of REV and HEAD, as it is in the working
# tree, untracked files that are not ignored included, and fails when the new text cites a
# decision number more often than the old one did: `Decision 12`, `TUI Decision 60`,
# `decision 7`, and each number of `Decisions 815 and 863`. A comment that is rewrapped or
# moved within its file keeps its count and passes; one carried to another file is a new
# citation there. Documents are not checked: they may name decisions, and code.
#
# Exits non-zero naming each file, the numbers it cites more often and the lines that
# cite them.

defmodule DecisionCitations do
  @root Path.expand("..", __DIR__)

  @code ~w(.ex .exs .heex .eex .ts .tsx .js .mjs .cjs .rs .css)

  # path => why it may name decision numbers. The tools that read, write and test
  # decision files handle the numbers as data.
  @exempt %{
    "scripts/decision-citations.exs" => "this check; its own examples",
    "scripts/split-decisions.exs" => "turns the old logs into decision files",
    "apps/troupe_protocol/lib/mix/tasks/troupe.decisions.ex" => "checks and lists decisions",
    "apps/troupe_protocol/test/mix/tasks/troupe.decisions_test.exs" =>
      "the decision tools' tests, fixtures with numbers"
  }

  # `Decision 12`, `decisions 815 and 863`, `Decisions 706, 798, 806 and 828`, and the same
  # wrapped across comment lines: the gaps may hold comment markers.
  @citation ~r{\bdecisions?(?:\s|\#|//|\*)+\d+(?:(?:\s|\#|//|\*)*(?:,\s*and|,|and|&)(?:\s|\#|//|\*)*\d+)*}i

  def main(args) do
    base =
      case args do
        [] -> "origin/main"
        ["--base", rev] -> rev
        _ -> usage()
      end

    from = merge_base(base)
    files = changed(from)

    found =
      files
      |> Enum.filter(fn {_old, new} -> code?(new) and not Map.has_key?(@exempt, new) end)
      |> Enum.flat_map(fn {old, new} ->
        case added(from, old, new) do
          [] -> []
          numbers -> [{new, numbers}]
        end
      end)

    case found do
      [] ->
        IO.puts(
          "decision-citations: #{length(files)} file(s) changed since #{base}, none adds a decision number to code"
        )

      _ ->
        for {file, numbers} <- found, {number, more, lines} <- numbers do
          IO.puts(
            :stderr,
            "#{file}: cites decision #{number} #{times(more)} more than before (line #{Enum.join(lines, ", ")})"
          )
        end

        IO.puts(:stderr, """

        #{length(found)} file(s) add a decision number to code.

        Say the invariant where it applies, in the code's own words: what holds, and what
        breaks if the line changes. A decision names the code it governs in its own front
        matter (`paths`, `symbols`), so the reference points from the document to the code
        (docs/developer/conventions.md, "Comments, decisions and messages").
        """)

        System.halt(1)
    end
  end

  defp usage do
    IO.puts(:stderr, "usage: elixir scripts/decision-citations.exs [--base REV]")
    System.halt(2)
  end

  defp times(1), do: "once"
  defp times(n), do: "#{n} times"

  defp code?(path), do: Path.extname(path) in @code

  # [{number, how many more, [line]}] for the numbers `new` cites more often than `old` did.
  defp added(from, old, new) do
    case File.read(Path.join(@root, new)) do
      {:ok, text} ->
        before = if old, do: show(from, old) |> citations() |> count(), else: %{}
        now = citations(text)

        now
        |> count()
        |> Enum.flat_map(fn {number, n} ->
          more = n - Map.get(before, number, 0)
          lines = for {^number, line} <- now, uniq: true, do: line
          if more > 0, do: [{number, more, lines}], else: []
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp count(citations), do: citations |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

  # [{number, line}], one for each number a citation names, on the line the number is on.
  defp citations(text) do
    for [{start, length}] <- Regex.scan(@citation, text, return: :index, capture: :first),
        match = binary_part(text, start, length),
        [{at, digits}] <- Regex.scan(~r/\d+/, match, return: :index) do
      number = match |> binary_part(at, digits) |> String.to_integer()
      line = text |> binary_part(0, start + at) |> String.split("\n") |> length()
      {number, line}
    end
  end

  defp merge_base(base) do
    case git(["merge-base", base, "HEAD"]) do
      {out, 0} ->
        String.trim(out)

      {_out, _} ->
        IO.puts(
          :stderr,
          "git merge-base #{base} HEAD failed. Fetch the base first, or name another with " <>
            "--base (CI checks out two commits and passes HEAD^1)."
        )

        System.halt(2)
    end
  end

  # [{path at the merge base or nil, path now}] for each file added, changed or renamed since
  # `from`, in the working tree, and each untracked file that is not ignored.
  defp changed(from) do
    {out, 0} = git(["diff", "--name-status", "-z", "-M", "--diff-filter=AMR", from])

    tracked =
      out
      |> String.split(<<0>>, trim: true)
      |> pairs([])

    {out, 0} = git(["ls-files", "--others", "--exclude-standard", "-z"])
    untracked = for path <- String.split(out, <<0>>, trim: true), do: {nil, path}

    Enum.uniq(tracked ++ untracked)
  end

  defp pairs([], acc), do: Enum.reverse(acc)
  defp pairs(["A", path | rest], acc), do: pairs(rest, [{nil, path} | acc])
  defp pairs(["M", path | rest], acc), do: pairs(rest, [{path, path} | acc])
  defp pairs(["R" <> _, old, new | rest], acc), do: pairs(rest, [{old, new} | acc])

  defp show(from, path) do
    case git(["show", "#{from}:#{path}"]) do
      {out, 0} -> out
      _ -> ""
    end
  end

  # stderr stays apart: git warns there about line endings, and the output is parsed.
  defp git(args), do: System.cmd("git", args, cd: @root)
end

DecisionCitations.main(System.argv())
