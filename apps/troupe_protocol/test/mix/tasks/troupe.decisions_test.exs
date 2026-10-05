defmodule Mix.Tasks.Troupe.DecisionsTest do
  @moduledoc """
  The decisions are a file each, checked and looked up by `mix troupe.decisions`
  (issue #437, Decision 790).

  What CI fails on (a duplicate number, a missing field, a glob that matches nothing, a
  front matter YAML would read otherwise), what `--for` lists, the repository's own
  decisions passing, and `scripts/split-decisions.exs` turning a log into files, against
  a log appended to after the split as well.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Troupe.Decisions

  @moduletag :tmp_dir

  @root Path.expand("../../../../..", __DIR__)
  @elixir System.find_executable("elixir") || "elixir"

  defp decision(dir, log \\ "", name, front, body \\ "Why, at length.\n") do
    path = Path.join([dir, "docs/decisions", log, name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\n" <> front <> "---\n\n" <> body)
  end

  defp front(number, extra \\ "") do
    """
    number: #{number}
    title: Decision #{number} decides something
    date: 2026-10-05
    status: accepted
    paths:
      - lib/a.ex
    gist: What not to undo
    """ <> extra
  end

  defp code(dir, path \\ "lib/a.ex") do
    File.mkdir_p!(Path.join(dir, Path.dirname(path)))
    File.write!(Path.join(dir, path), "# code\n")
  end

  defp messages(dir), do: dir |> Decisions.check() |> Enum.map(fn {_file, message} -> message end)

  describe "--check" do
    test "a file with every field, whose paths match, passes", %{tmp_dir: dir} do
      code(dir)
      decision(dir, "0001-one.md", front(1))

      assert Decisions.check(dir) == []
      assert capture_io(fn -> Decisions.run(["--check", "--root", dir]) end) =~ "1 in 1 logs"
    end

    test "a number used twice in one log fails; the same number in two logs does not",
         %{tmp_dir: dir} do
      code(dir)
      decision(dir, "0001-one.md", front(1))
      decision(dir, "tui", "0001-one.md", front(1))
      assert Decisions.check(dir) == []

      decision(dir, "0001-again.md", front(1))

      assert [{"docs/decisions/0001-one.md", "number 1 is docs/decisions/0001-again.md's too"}] =
               Decisions.check(dir)

      assert_raise Mix.Error, ~r/1 problem/, fn ->
        capture_io(:stderr, fn -> Decisions.run(["--check", "--root", dir]) end)
      end
    end

    test "a missing field fails, naming it", %{tmp_dir: dir} do
      code(dir)
      decision(dir, "0001-one.md", String.replace(front(1), "gist: What not to undo\n", ""))
      decision(dir, "0002-two.md", String.replace(front(2), "date: 2026-10-05\n", ""))

      assert messages(dir) == ["missing gist", "missing date"]
    end

    test "a paths glob that matches nothing fails; one that matches passes", %{tmp_dir: dir} do
      code(dir)
      code(dir, "lib/deep/b.ex")
      decision(dir, "0001-one.md", front(1, "") |> String.replace("lib/a.ex", "lib/**/b.ex"))
      decision(dir, "0002-two.md", front(2) |> String.replace("lib/a.ex", "lib/gone.ex"))

      assert messages(dir) == ["paths: lib/gone.ex matches nothing"]
    end

    test "a value YAML would read otherwise fails; quoted, it passes", %{tmp_dir: dir} do
      code(dir)
      title = &String.replace(front(&1), "title: Decision #{&1} decides something", &2)

      decision(dir, "0001-one.md", title.(1, "title: `x` is decided"))
      decision(dir, "0002-two.md", title.(2, "title: a cap: the tightest refuses"))
      decision(dir, "0003-three.md", title.(3, "title: issue #12 is decided"))
      decision(dir, "0004-four.md", title.(4, "title: 12"))
      decision(dir, "0005-five.md", title.(5, ~s(title: "`x` is decided: \\"really\\" #12")))
      decision(dir, "0006-six.md", title.(6, "title: 'it''s decided: a cap'"))
      # MkDocs ends a front matter at a line that ends `...`.
      decision(dir, "0007-seven.md", String.replace(front(7), "What not to undo", "and so on..."))

      assert [
               {"docs/decisions/0001-one.md", "title: `x` is decided starts with" <> _},
               {"docs/decisions/0002-two.md", "title: a cap: the tightest refuses has `: `" <> _},
               {"docs/decisions/0003-three.md", "title: YAML reads ` #` as the start" <> _},
               {"docs/decisions/0004-four.md", "title: YAML reads 12 as something" <> _},
               {"docs/decisions/0007-seven.md", "line 8 of the front matter ends with" <> _}
             ] = Decisions.check(dir)

      {decisions, _problems} = Decisions.load(dir)
      titles = decisions |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["`x` is decided: \"really\" #12", "it's decided: a cap"]
    end

    test "the file name carries the number, four digits and a slug", %{tmp_dir: dir} do
      code(dir)
      decision(dir, "0001-one.md", front(2))
      decision(dir, "3-three.md", front(3))

      assert messages(dir) == [
               "number is 2, and the file name says 1",
               "a decision's file is named <four-digit number>-<slug>.md, in lower case"
             ]
    end

    test "lists, written either way, and optional fields", %{tmp_dir: dir} do
      code(dir)
      code(dir, "lib/b.ex")

      decision(dir, "0002-two.md", """
      number: 2
      title: Two
      date: 2026-10-05
      status: superseded by 3  # in full
      issue: 437
      supersedes: [1]
      paths:
      - lib/a.ex
      - "lib/b.ex"
      gist: >-
        Folded over
        two lines
      """)

      assert {[decision], []} = Decisions.load(dir)
      assert decision.paths == ["lib/a.ex", "lib/b.ex"]
      assert decision.supersedes == [1]
      assert decision.issue == 437
      assert decision.gist == "Folded over two lines"
      assert decision.status == "superseded by 3"
    end

    test "the repository's own decisions pass" do
      assert Decisions.check(@root) == []
    end
  end

  describe "--for" do
    setup %{tmp_dir: dir} do
      code(dir)
      code(dir, "lib/sub/c.ex")

      decision(
        dir,
        "0001-old.md",
        front(1, "supersedes: []\n") |> String.replace("accepted", "superseded")
      )

      decision(
        dir,
        "0002-new.md",
        front(2, "supersedes: [1]\n") |> String.replace("lib/a.ex", "lib/")
      )

      decision(dir, "0003-part.md", front(3) |> String.replace("lib/a.ex", "lib/sub/c.ex"))

      decision(
        dir,
        "0004-later.md",
        front(4, "supersedes: [3]\n") |> String.replace("lib/a.ex", "lib/sub")
      )

      decision(dir, "tui", "0001-tui.md", front(1) |> String.replace("2026-10-05", "2026-09-01"))
      :ok
    end

    test "a file is governed by the decisions naming it and the directories above it",
         %{tmp_dir: dir} do
      {decisions, []} = Decisions.load(dir)
      ids = &(decisions |> Decisions.governing(dir, &1) |> Enum.map(fn d -> d.id end))

      assert ids.("lib/a.ex") == ["2", "1", "tui/1"]
      assert ids.("lib/sub/c.ex") == ["4", "3", "2"]
      assert ids.("lib/sub") == ["4", "3", "2"]
      assert ids.("lib") == ["4", "3", "2", "1", "tui/1"]
      assert ids.("docs") == []
    end

    test "prints each one's number, mark and gist, newest first", %{tmp_dir: dir} do
      out =
        capture_io(fn -> Decisions.run(["--root", dir, "--for", Path.join(dir, "lib/a.ex")]) end)

      assert out =~ "lib/a.ex: 3 decisions, newest first"
      assert out =~ ~r/  2 +What not to undo\n +docs\/decisions\/0002-new.md/
      assert out =~ ~r/  1 +\[superseded by 2\] What not to undo/
      assert out =~ ~r/  tui\/1 +What not to undo/

      out =
        capture_io(fn ->
          Decisions.run(["--root", dir, "--for", Path.join(dir, "lib/sub/c.ex")])
        end)

      assert out =~ ~r/  3 +\[partly superseded by 4\] What not to undo/

      assert capture_io(fn -> Decisions.run(["--root", dir, "--for", Path.join(dir, "docs")]) end) =~
               "docs: no decision names it"
    end
  end

  describe "scripts/split-decisions.exs" do
    test "a log becomes a file per entry, and an entry appended later becomes one more",
         %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "scripts"))

      File.cp!(
        Path.join(@root, "scripts/split-decisions.exs"),
        Path.join(dir, "scripts/split-decisions.exs")
      )

      code(dir, "lib/plane.ex")

      File.write!(
        Path.join(dir, "lib/plane.ex"),
        "# The ledger is the record (Decisions 12 and\n# 14).\n"
      )

      File.write!(Path.join(dir, "DECISIONS.md"), """
      # Decisions

      ## A section

      12. **The ledger is the record, not a cache.** Written first, read back after a
          restart.

          - a list in the body,
            kept as it was.

      14. **One more: `lib/plane.ex` says so.** Issue #7. This supersedes Decision 12.
      """)

      git!(dir, ["init", "--quiet"])
      git!(dir, ["add", "."])

      git!(dir, [
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.test",
        "commit",
        "--quiet",
        "-m",
        "log"
      ])

      assert {_out, 0} = split!(dir)
      refute File.exists?(Path.join(dir, "DECISIONS.md"))

      [twelve] = Path.wildcard(Path.join(dir, "docs/decisions/0012-*.md"))
      assert Path.basename(twelve) == "0012-the-ledger-is-the-record-not-a-cache.md"

      assert File.read!(twelve) =~ """
             title: The ledger is the record, not a cache
             """

      assert File.read!(twelve) =~ "status: superseded\npaths:\n  - lib/plane.ex\n"

      assert File.read!(twelve) =~
               "---\n\nWritten first, read back after a\nrestart.\n\n- a list in the body,\n  kept as it was.\n"

      [fourteen] = Path.wildcard(Path.join(dir, "docs/decisions/0014-*.md"))
      assert File.read!(fourteen) =~ ~s(title: "One more: `lib/plane.ex` says so"\n)
      assert File.read!(fourteen) =~ "issue: 7\nsupersedes: [12]\n"
      assert Decisions.check(dir) == []

      # A branch cut before the split appended to the log: its entry becomes a file, and the
      # files already there stay as they are.
      File.write!(twelve, File.read!(twelve) |> String.replace("lib/plane.ex", "lib/"))

      File.write!(Path.join(dir, "DECISIONS.md"), """
      12. **The ledger is the record, not a cache.** Written first, read back after a
          restart.

          - a list in the body,
            kept as it was.

      15. **A later one.** About `lib/plane.ex`.
      """)

      assert {_out, 0} = split!(dir)
      assert File.read!(twelve) =~ "  - lib/\n"
      assert [_fifteen] = Path.wildcard(Path.join(dir, "docs/decisions/0015-*.md"))
      refute File.exists?(Path.join(dir, "DECISIONS.md"))

      # One whose body differs from its file's is named, and the log stays.
      File.write!(Path.join(dir, "DECISIONS.md"), "15. **A later one.** Said otherwise.\n")
      assert {out, 1} = split!(dir)
      assert out =~ "differ from their files: 15"
      assert File.exists?(Path.join(dir, "DECISIONS.md"))
    end
  end

  defp split!(dir) do
    System.cmd(@elixir, ["scripts/split-decisions.exs"], cd: dir, stderr_to_stdout: true)
  end

  defp git!(dir, args) do
    assert {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
