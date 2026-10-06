defmodule Troupe.InstructionsTest do
  @moduledoc """
  The instruction files a repository carries (Decisions 706 and 798): which are read and
  in what order, the directories the conversation worked in, which alias wins in a
  directory and which are named as skipped, what an `@import` brings and where it stops,
  how the budget is shared with the nearest kept whole, where the repository root is,
  and how the digest follows the content. The loader alone; a real session's prompt is
  `instructions_prompt_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Instructions
  alias Troupe.LLM.{Message, ToolResult, ToolUse}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-instr-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, repo: Path.expand(repo)}
  end

  test "the root's file, then one per directory down to the workspace, nearest last", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "root rule")
    write!(repo, "frontend/AGENTS.md", "frontend rule")
    write!(repo, "frontend/app/AGENTS.md", "app rule")
    write!(repo, "backend/AGENTS.md", "not on the path")

    loaded = Instructions.load(Path.join(repo, "frontend/app"), config())

    assert files(loaded, repo) == [
             {:root, "AGENTS.md"},
             {:nested, "frontend/AGENTS.md"},
             {:nested, "frontend/app/AGENTS.md"}
           ]

    assert List.last(loaded.files).scope == :brief

    assert loaded.used ==
             String.length("root rule") + String.length("frontend rule") +
               String.length("app rule")

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "# Instruction files"
    assert [_head, root, frontend, app] = String.split(prompt, "Contents of ")
    assert root =~ "(repository root):\nroot rule"
    assert frontend =~ "(nearer: frontend/):\nfrontend rule"
    assert app =~ "(nearer: frontend/app/):\napp rule"
    refute prompt =~ "not on the path"
  end

  test "in one directory the first alias is read and the rest are named as skipped", %{repo: repo} do
    write!(repo, "CLAUDE.md", "claude's")
    write!(repo, "AGENTS.md", "agents'")
    write!(repo, ".github/copilot-instructions.md", "copilot's")
    write!(repo, "lib/GEMINI.md", "gemini's")
    write!(repo, "lib/.github/copilot-instructions.md", "copilot's again")
    write!(repo, "lib/x/.github/copilot-instructions.md", "copilot's alone")

    loaded = Instructions.load(Path.join(repo, "lib/x"), config())

    assert [
             %{
               scope: :root,
               text: "agents'",
               skipped: ["CLAUDE.md", ".github/copilot-instructions.md"]
             },
             %{scope: :nested, text: "gemini's", skipped: [".github/copilot-instructions.md"]},
             %{scope: :nested, text: "copilot's alone", skipped: []},
             %{scope: :brief}
           ] = loaded.files

    assert Instructions.aliases() == [
             "AGENTS.md",
             "CLAUDE.md",
             "GEMINI.md",
             ".github/copilot-instructions.md"
           ]

    prompt = Instructions.to_prompt(loaded)
    refute prompt =~ "claude's"
    assert prompt =~ "gemini's"
  end

  test "the budget keeps the nearest whole first and says what it cut", %{repo: repo} do
    write!(repo, "AGENTS.md", String.duplicate("r", 100))
    write!(repo, "a/AGENTS.md", String.duplicate("m", 100))
    write!(repo, "a/b/AGENTS.md", String.duplicate("n", 100))

    loaded = Instructions.load(Path.join(repo, "a/b"), config(instructions_max_chars: 150))

    assert [
             %{scope: :root, status: :dropped, chars: 0, trimmed: 100, text: ""},
             %{scope: :nested, status: :trimmed, chars: 50, trimmed: 50, text: text},
             %{scope: :nested, status: :whole, chars: 100, trimmed: 0},
             %{scope: :brief}
           ] = loaded.files

    assert text == String.duplicate("m", 50)
    assert loaded.budget == 150
    assert loaded.used == 150

    prompt = Instructions.to_prompt(loaded)

    assert prompt =~
             "(repository root): left out, the instructions budget of 150 characters was spent on nearer files."

    assert prompt =~ String.duplicate("m", 50) <> "\n\n(cut here: 50 more characters"
    assert prompt =~ String.duplicate("n", 100)

    provenance = Instructions.provenance(loaded)
    assert provenance["budget"] == 150
    assert provenance["used"] == 150

    assert Enum.map(provenance["files"], &{&1["status"], &1["chars"], &1["trimmed"], &1["share"]}) ==
             [
               {"dropped", 0, 100, 0.0},
               {"trimmed", 50, 50, 0.333},
               {"whole", 100, 0, 0.667},
               {"absent", 0, 0, 0.0}
             ]
  end

  # Decision 798: where the session works is its workspace and the directory of every file
  # its conversation read, edited or wrote.
  test "a file the conversation worked on brings the file of each directory on its way", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "root rule")
    write!(repo, "frontend/AGENTS.md", "frontend rule")
    write!(repo, "frontend/app/CLAUDE.md", "app rule")
    write!(repo, "backend/AGENTS.md", "backend rule")
    write!(repo, "docs/AGENTS.md", "not worked in")

    focus = [
      "frontend/app/main.ts",
      Path.join(repo, "backend/lib/server.ex"),
      "../elsewhere/AGENTS.md"
    ]

    loaded = Instructions.load(repo, config(), focus)

    assert files(loaded, repo) == [
             {:root, "AGENTS.md"},
             {:nested, "backend/AGENTS.md"},
             {:nested, "frontend/AGENTS.md"},
             {:nested, "frontend/app/CLAUDE.md"}
           ]

    assert Path.join(repo, "backend/lib") in loaded.searched
    refute Path.expand(Path.join(repo, "../elsewhere")) in loaded.searched

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "(nearer: frontend/app/):\napp rule"
    refute prompt =~ "not worked in"
    assert Instructions.load(repo, config()).digest != loaded.digest
  end

  test "the conversation's focus is the files it read, edited or wrote" do
    conversation = [
      Message.user("go"),
      Message.assistant([
        %ToolUse{id: "1", name: "read_file", input: %{"path" => "a/x.ex"}},
        %ToolUse{id: "2", name: "grep", input: %{"pattern" => "x", "path" => "b"}}
      ]),
      Message.tool_results([
        %ToolResult{tool_use_id: "1", content: "x"},
        %ToolResult{tool_use_id: "2", content: "y"}
      ]),
      Message.assistant([
        %ToolUse{id: "3", name: "edit_file", input: %{"path" => "c/y.ex"}},
        %ToolUse{id: "4", name: "write_file", input: %{"path" => "a/x.ex"}}
      ])
    ]

    assert Instructions.focus(conversation) == ["a/x.ex", "c/y.ex"]
    assert Instructions.focus([]) == []
  end

  test "an @import is read right after the file that names it, from its directory, once", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", """
    # Rules
    See @docs/style.md, then @docs/style.md again, and @.github/review.md.
    Mail someone@example.com or ask @alice.
    `@docs/quoted.md` is code, and so is this:
    ```
    @docs/fenced.md
    ```
    """)

    write!(repo, "docs/style.md", "Style: tabs. See @../docs/terms.md")
    write!(repo, "docs/terms.md", "Terms.")
    write!(repo, ".github/review.md", "Review.")
    write!(repo, "docs/quoted.md", "never read")
    write!(repo, "docs/fenced.md", "never read")

    loaded = Instructions.load(repo, config())
    root = Path.join(repo, "AGENTS.md")
    style = Path.join(repo, "docs/style.md")

    assert [
             %{scope: :root, path: ^root, imported_by: nil, unfollowed: []},
             %{
               scope: :root,
               path: ^style,
               imported_by: ^root,
               text: "Style: tabs. See @../docs/terms.md"
             },
             %{scope: :root, text: "Terms.", imported_by: ^style},
             %{scope: :root, text: "Review.", imported_by: ^root},
             %{scope: :brief}
           ] = loaded.files

    prompt = Instructions.to_prompt(loaded)
    assert prompt =~ "Contents of #{style} (repository root, imported by #{root}):\nStyle: tabs."
    refute prompt =~ "never read"

    assert [_root, %{"imported_by" => ^root, "scope" => "root", "size" => 34} | _] =
             Instructions.provenance(loaded)["files"]
  end

  test "imports stop five deep, at a cycle and at the repository's edge, and say so", %{
    base: base,
    repo: repo
  } do
    write!(repo, "AGENTS.md", "@one.md @gone/missing.md @../outside.md @~/secret.md")
    write!(repo, "one.md", "@two.md")
    write!(repo, "two.md", "@three.md")
    write!(repo, "three.md", "@four.md")
    write!(repo, "four.md", "@five.md")
    write!(repo, "five.md", "@six.md @one.md")
    write!(repo, "six.md", "too deep")
    write!(base, "outside.md", "the world outside")

    loaded = Instructions.load(repo, config())
    [agents | imported] = Enum.reject(loaded.files, &(&1.scope == :brief))

    assert agents.unfollowed == [
             %{import: "gone/missing.md", reason: :missing},
             %{import: "../outside.md", reason: :outside},
             %{import: "~/secret.md", reason: :outside}
           ]

    assert Enum.map(imported, &Path.basename(&1.path)) ==
             ["one.md", "two.md", "three.md", "four.md", "five.md"]

    assert List.last(imported).unfollowed == [
             %{import: "six.md", reason: :depth},
             %{import: "one.md", reason: :cycle}
           ]

    prompt = Instructions.to_prompt(loaded)
    refute prompt =~ "too deep"
    refute prompt =~ "the world outside"

    assert %{"unfollowed" => [%{"import" => "gone/missing.md", "reason" => "missing"} | _]} =
             hd(Instructions.provenance(loaded)["files"])
  end

  test "a file and its imports are one scope: the nearer scope is kept whole first", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "@a.md " <> String.duplicate("r", 94))
    write!(repo, "a.md", String.duplicate("a", 100))
    write!(repo, "x/AGENTS.md", String.duplicate("n", 100))

    loaded = Instructions.load(repo, config(instructions_max_chars: 150), ["x/f.ex"])
    root = Path.join(repo, "AGENTS.md")

    assert [
             %{scope: :root, status: :trimmed, chars: 50, trimmed: 50},
             %{scope: :root, status: :dropped, chars: 0, trimmed: 100, imported_by: ^root},
             %{scope: :nested, status: :whole, chars: 100},
             %{scope: :brief}
           ] = loaded.files
  end

  test "without a .git the workspace is the root; a .git file, a worktree's, is one too", %{
    base: base
  } do
    plain = Path.join(base, "plain")
    write!(plain, "AGENTS.md", "plain")
    write!(plain, "sub/AGENTS.md", "sub")
    loaded = Instructions.load(Path.join(plain, "sub"), config())
    assert files(loaded, Path.expand(plain)) == [{:root, "sub/AGENTS.md"}]
    assert Path.expand(Path.join(plain, "sub")) in loaded.searched

    worktree = Path.join(base, "worktree")
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: elsewhere\n")
    write!(worktree, "AGENTS.md", "the branch's own")
    loaded = Instructions.load(Path.join(worktree, "deep"), config())
    assert files(loaded, Path.expand(worktree)) == [{:root, "AGENTS.md"}]
  end

  test "the digest follows the content, and the brief is listed with its own budget", %{
    repo: repo
  } do
    write!(repo, "AGENTS.md", "one")
    first = Instructions.load(repo, config())
    assert Instructions.load(repo, config()).digest == first.digest

    write!(repo, "AGENTS.md", "two")
    assert Instructions.load(repo, config()).digest != first.digest

    write!(repo, ".troupe/memory.md", "## Overview\nA brief.\n")
    with_brief = Instructions.load(repo, config(memory_max_chars: 3))
    assert with_brief.digest != first.digest

    assert %{scope: :brief, status: :trimmed, budget: 3, size: size, hash: "sha256:" <> _} =
             List.last(with_brief.files)

    assert size == byte_size("## Overview\nA brief.\n")
    assert Instructions.to_prompt(with_brief) =~ "# Project brief"
    assert Instructions.to_prompt(with_brief) =~ "(brief truncated)"

    off = Instructions.load(repo, config(memory: false))
    assert %{scope: :brief, status: :disabled, chars: 0, text: ""} = List.last(off.files)
    refute Instructions.to_prompt(off) =~ "# Project brief"
  end

  test "an empty workspace has nothing but the brief's line, and no prompt block", %{repo: repo} do
    loaded = Instructions.load(repo, config())
    assert [%{scope: :brief, status: :absent, chars: 0}] = loaded.files
    assert loaded.used == 0
    assert Instructions.to_prompt(loaded) == ""
  end

  # The brief lives in the repository's main checkout, which is a question for `git`, and
  # this read comes before every model call: the path is asked for once, not once for the
  # path, once for the text and once for what the budget cut.
  test "reading the brief asks git where the repository is once", %{repo: repo} do
    write!(repo, ".troupe/memory.md", "## Overview\nA brief.\n")

    {loaded, gits} = gits(fn -> Instructions.load(repo, config()) end)
    assert %{files: [%{scope: :brief, status: :whole}]} = loaded
    assert gits == 1
  end

  # How many times `fun` ran `git` in this process: every one goes through the reaper, and a
  # tracer beside the test counts the calls (a process is not its own tracer).
  defp gits(fun) do
    Code.ensure_loaded!(Troupe.Reaper)
    assert :erlang.trace_pattern({Troupe.Reaper, :run, 3}, true, [:local]) == 1
    on_exit(fn -> :erlang.trace_pattern({Troupe.Reaper, :run, 3}, false, [:local]) end)
    tracer = spawn_link(fn -> count_gits(0) end)

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    result = fun.()
    :erlang.trace(self(), false, [:call])

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, {:count, self()})
    assert_receive {:gits, count}
    {result, count}
  end

  defp count_gits(count) do
    receive do
      {:trace, _pid, :call, {Troupe.Reaper, :run, [_cwd, ["git" | _args], _opts]}} ->
        count_gits(count + 1)

      {:trace, _pid, :call, _other} ->
        count_gits(count)

      {:count, from} ->
        send(from, {:gits, count})
    end
  end

  defp write!(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp config(overrides \\ []), do: struct!(Troupe.Config, overrides)

  defp files(loaded, root) do
    for f <- loaded.files, f.scope != :brief, do: {f.scope, Path.relative_to(f.path, root)}
  end
end
