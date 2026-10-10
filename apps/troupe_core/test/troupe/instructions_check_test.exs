defmodule Troupe.Instructions.CheckTest do
  @moduledoc """
  `troupe instructions check`'s findings (issue #123, Decisions 810 and 828), on fixtures:
  a contradiction between scopes, a path that is not there, a command whose program is not
  on the PATH, a rule said twice, a repository with none of them, and the cases each
  detector passes over rather than guess; Troupe's rules checked and other tools' files
  not. The PATH is a stand-in throughout, so what is installed here changes nothing.
  """

  use ExUnit.Case, async: true

  alias Troupe.Instructions.Check

  @everywhere [executable?: &__MODULE__.everywhere/1]

  def everywhere(_program), do: true

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-check-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{repo: Path.expand(repo)}
  end

  describe "contradictions" do
    test "the root's `npm test` and frontend/AGENTS.md's `pnpm test` are one, on the nearer file's line",
         %{repo: repo} do
      write!(repo, "AGENTS.md", "# Tests\n\nRun `npm test` before you push.\n")
      write!(repo, "frontend/AGENTS.md", "# Frontend\n\nRun `pnpm test` here.\n")

      assert [finding] = findings(repo)

      assert finding == %{
               path: Path.join(repo, "frontend/AGENTS.md"),
               line: 3,
               kind: :contradiction,
               message: "how to run the tests: `pnpm test` here, `npm test` in AGENTS.md:3"
             }

      assert {text, 1} = Check.run(repo, @everywhere)

      assert text ==
               "frontend/AGENTS.md:3: contradiction: how to run the tests: `pnpm test` here, " <>
                 "`npm test` in AGENTS.md:3\n\n1 finding in 2 instruction files.\n"
    end

    test "commands in fenced blocks, with wrappers and a package manager's options, count too",
         %{repo: repo} do
      write!(repo, "AGENTS.md", """
      Build it:

      ```sh
      mise exec -- npm run build
      ```
      """)

      write!(repo, "web/AGENTS.md", """
      ```
      pnpm -C web build --prod
      ```
      """)

      assert [%{path: path, line: 2, kind: :contradiction, message: message}] = findings(repo)
      assert path == Path.join(repo, "web/AGENTS.md")

      assert message ==
               "how to build: `pnpm -C web build --prod` here, `mise exec -- npm run build` in AGENTS.md:4"
    end

    test "different ecosystems, a command in common, siblings and one scope are no contradiction",
         %{repo: repo} do
      write!(
        repo,
        "AGENTS.md",
        "Run `mix test` for the server, and `npm test` or `pnpm test` for the web.\n"
      )

      # Another ecosystem: two parts of a repository, not a disagreement.
      write!(repo, "api/AGENTS.md", "Run `cargo test`.\n")
      # A command the root names too.
      write!(repo, "web/AGENTS.md", "Run `pnpm test`.\n")
      # Siblings never apply to the same work.
      write!(repo, "a/AGENTS.md", "Run `yarn lint`.\n")
      write!(repo, "b/AGENTS.md", "Run `bun lint`.\n")
      # A file and what it imports are one scope.
      write!(repo, "c/AGENTS.md", "Run `yarn build`. @more.md\n")
      write!(repo, "c/more.md", "Or `bun run build`.\n")

      assert findings(repo) == []
    end

    test "a scope is held to the nearest one around it that names the subject", %{repo: repo} do
      write!(repo, "AGENTS.md", "Use `npm test`.\n")
      write!(repo, "web/AGENTS.md", "Use `pnpm test`.\n")
      write!(repo, "web/app/AGENTS.md", "Use `pnpm test --watch`.\n")
      write!(repo, "web/app/deep/AGENTS.md", "Nothing about tests here at all.\n")

      assert [%{path: path, kind: :contradiction}] = findings(repo)
      assert path == Path.join(repo, "web/AGENTS.md")
    end

    test "the person's own file applies everywhere, so the root's disagreement with it is one" do
      sources = [
        source(:user, nil, "/config/AGENTS.md", "Always `pnpm lint` first.\n"),
        source(:root, nil, "/repo/AGENTS.md", "\n\nRun `npm run lint`.\n")
      ]

      assert [%{path: "/repo/AGENTS.md", line: 3, message: message}] =
               Check.findings(sources, [root: "/repo", exists?: fn _ -> true end] ++ @everywhere)

      assert message =~ "`npm run lint` here, `pnpm lint` in "
    end
  end

  describe "paths" do
    test "a path in a span or a link that is not there, from the file's directory or the root",
         %{repo: repo} do
      write!(repo, "docs/here.md", "")
      write!(repo, "web/src/app.ts", "")

      write!(repo, "AGENTS.md", """
      Read `docs/here.md` and `docs/gone.md` first.
      The [guide](docs/missing-guide.md) and the [other](docs/here.md#top) one.
      Code lives in `lib/`, and `./scripts/build.sh` builds it.
      See `docs/gone.md` again, and @docs/gone-import.md
      """)

      write!(repo, "web/AGENTS.md", "Start at `src/app.ts`, `docs/here.md` and `src/main.ts`.\n")

      assert [
               {"AGENTS.md", 1, "`docs/gone.md` does not exist"},
               {"AGENTS.md", 2, "`docs/missing-guide.md` does not exist"},
               {"AGENTS.md", 3, "`lib/` does not exist"},
               {"AGENTS.md", 3, "`./scripts/build.sh` does not exist"},
               {"AGENTS.md", 4, "`@docs/gone-import.md` imports a file that does not exist"},
               {"web/AGENTS.md", 1, "`src/main.ts` does not exist"}
             ] = for(f <- findings(repo), do: {Path.relative_to(f.path, repo), f.line, f.message})
    end

    # D99: a nested `.agents/AGENTS.md`, or a rule in a nested `.troupe/rules`, is about its
    # directory, as its scope is, so a path it names is looked for from there too.
    test "a path in web/.agents/AGENTS.md or web/.troupe/rules is resolved from web/", %{
      repo: repo
    } do
      write!(repo, "docs/guide.md", "")
      write!(repo, "web/AGENTS.md", "Web.\n")

      write!(
        repo,
        "web/.agents/AGENTS.md",
        "Read [the guide](../docs/guide.md), not [this](../docs/gone.md).\n"
      )

      write!(
        repo,
        "web/.troupe/rules/style.md",
        "---\nalwaysApply: true\n---\nSee [the guide](../docs/guide.md) and [that](../docs/old.md).\n"
      )

      assert [
               {"web/.agents/AGENTS.md", 1, "`../docs/gone.md` does not exist"},
               {"web/.troupe/rules/style.md", 4, "`../docs/old.md` does not exist"}
             ] = for(f <- findings(repo), do: {Path.relative_to(f.path, repo), f.line, f.message})
    end

    test "what only might be a path is passed over", %{repo: repo} do
      write!(repo, "docs/here.md", "")
      write!(repo, "lib/troupe/client/link.ex", "")
      write!(repo, ".gitignore", "/_build/\n")

      write!(repo, "AGENTS.md", """
      Branch from `origin/main`, never `acme/widgets`'s `feat/x`; send `application/json`.
      A bare `CONTRIBUTING.md`, a page at `example.com/docs/x.md`,
      `<config>/AGENTS.md`, `~/.config/x.md`, `/etc/hosts`, `docs/*.md`, `$HOME/x.md`.
      Links out: [site](https://example.com/x.md), [mail](mailto:a@example.com), [here](#top).
      A line reference, `docs/here.md:12`, is the file.
      Outside the repository: `../../elsewhere/x.md`.
      In `lib/troupe/`, `client/link.ex` talks to the daemon; a build writes `_build/dev/`.

      ```sh
      cat docs/nowhere.md
      ```
      """)

      assert findings(repo) == []
    end
  end

  describe "commands" do
    test "a program not on the PATH, once per file, from spans and shell blocks", %{repo: repo} do
      write!(repo, "AGENTS.md", """
      Run `pnpm test`, then `pnpm build`, then `mix check`.

      ```bash
      export FOO=1
      cd web && FOO=2 zzz-tool build --all   # the build
      ls -la | grep x
      ```

      ```powershell
      Set-Location web
      $env:FOO = "1"
      .\\scripts\\install.ps1
      ```
      """)

      missing = MapSet.new(["pnpm", "zzz-tool", "export", "cd", "ls", "grep", "Set-Location"])
      found = findings(repo, executable?: &(not MapSet.member?(missing, &1)))

      assert [
               {1, "`pnpm` is not on the PATH (`pnpm test`)"},
               {5, "`zzz-tool` is not on the PATH (`FOO=2 zzz-tool build --all`)"}
             ] = for(f <- found, do: {f.line, f.message})
    end

    test "a word that is not a command is not looked for", %{repo: repo} do
      write!(repo, "AGENTS.md", """
      Set `go` to true, colour it `black`, and run `mytool sync`.

      ```
      zzz-tool run
      ```

      ```json
      {"scripts": {"test": "zzz-tool"}}
      ```

      ```console
      $ npm test
      zzz-tool output that is not a command
      ```
      """)

      assert [%{line: 12, message: "`npm` is not on the PATH (`npm test`)"}] =
               findings(repo,
                 executable?: &(&1 not in ["npm", "zzz-tool", "go", "black", "mytool"])
               )
    end
  end

  describe "duplicates" do
    test "a rule said again in another file points back at the first", %{repo: repo} do
      write!(repo, "AGENTS.md", """
      # Rules

      - Never push straight to the main branch.
      - Keep it short.

      Every pull request needs a test that failed before
      the change and passes after it.
      """)

      write!(repo, "web/AGENTS.md", """
      # Rules

      * **Never** push straight to the `main` branch
      - Keep it short.

      Every pull request needs a test that failed before the change and passes after it.

      Every pull request needs a test that failed before the change and passes after it.
      """)

      assert [
               {3, "the same rule as AGENTS.md:3"},
               {6, "the same rule as AGENTS.md:6"}
             ] = for(f <- findings(repo), do: {f.line, f.message})
    end

    test "another tool's file the loader skipped is not read, so it repeats nothing", %{
      repo: repo
    } do
      rules = "Never push straight to the main branch, ever.\n"
      write!(repo, "AGENTS.md", rules)
      write!(repo, "CLAUDE.md", rules)

      assert findings(repo) == []
    end
  end

  describe "the files and the exit status" do
    # Decisions 810 and 828: the files the loader reads, `.troupe/rules` among them, and not
    # the other tools' files it lists as skipped.
    test "Troupe's rules are checked, and other tools' files, not read, are not", %{repo: repo} do
      gone = "Read [the notes](docs/gone.md) first.\n"
      write!(repo, "AGENTS.md", "Run `npm test`.\n")
      write!(repo, ".troupe/rules/web.md", "---\nglobs: web/**\n---\n" <> gone)
      write!(repo, "CLAUDE.md", "Run `yarn test`.\n" <> gone)
      write!(repo, "web/CLAUDE.md", "Run `pnpm test`.\n")
      write!(repo, ".cursor/rules/old.mdc", "---\nalwaysApply: true\n---\n" <> gone)
      write!(repo, ".cursorrules", gone)
      write!(repo, "web/index.ts", "")

      assert Check.run(repo, @everywhere) ==
               {".troupe/rules/web.md:4: path: `docs/gone.md` does not exist\n\n" <>
                  "1 finding in 2 instruction files.\n", 1}
    end

    test "a clean repository passes, and says which files it read", %{repo: repo} do
      write!(repo, "docs/guide.md", "")
      write!(repo, "AGENTS.md", "Read [the guide](docs/guide.md), and run `npm test`.\n")
      write!(repo, "web/AGENTS.md", "Run `npm test -- --watch` while you work on the page.\n")

      assert Check.run(repo, @everywhere) ==
               {"no findings in 2 instruction files: AGENTS.md, web/AGENTS.md\n", 0}
    end

    test "--json is the same as one object", %{repo: repo} do
      write!(repo, "AGENTS.md", "Run `npm test`.\n")
      write!(repo, "web/AGENTS.md", "Run `yarn test`.\n")

      assert {json, 1} = Check.run(repo, [json: true] ++ @everywhere)

      assert %{
               "workspace" => ^repo,
               "root" => ^repo,
               "files" => [
                 %{"file" => "AGENTS.md", "scope" => "root"},
                 %{"file" => "web/AGENTS.md", "scope" => "nested"}
               ],
               "findings" => [
                 %{
                   "file" => "web/AGENTS.md",
                   "line" => 1,
                   "kind" => "contradiction",
                   "message" =>
                     "how to run the tests: `yarn test` here, `npm test` in AGENTS.md:1"
                 }
               ]
             } = Jason.decode!(json)

      write!(repo, "web/AGENTS.md", "Run `npm test`, quietly.\n")
      assert {json, 0} = Check.run(repo, [json: true] ++ @everywhere)
      assert %{"findings" => []} = Jason.decode!(json)
    end

    test "a workspace that cannot be read exits 2", %{repo: repo} do
      gone = Path.join(repo, "nowhere")
      assert {"cannot read the workspace " <> _, 2} = Check.run(gone, @everywhere)

      write!(repo, "a-file", "")
      assert {json, 2} = Check.run(Path.join(repo, "a-file"), [json: true] ++ @everywhere)
      assert %{"error" => "cannot read the workspace " <> _} = Jason.decode!(json)
    end

    test "no instruction files is nothing to find", %{repo: repo} do
      assert {"no instruction files reach a session in " <> _, 0} = Check.run(repo, @everywhere)
    end

    test "what .gitignore hides and a repository inside this one are not worked in",
         %{repo: repo} do
      write!(repo, ".gitignore", "/vendor/\n")
      write!(repo, "AGENTS.md", "Run `npm test`.\n")
      write!(repo, "vendor/lib/AGENTS.md", "Run `pnpm test`.\n")
      write!(repo, "sub/.git", "gitdir: elsewhere\n")
      write!(repo, "sub/AGENTS.md", "Run `yarn test`.\n")

      assert {"no findings in 1 instruction file: AGENTS.md\n", 0} = Check.run(repo, @everywhere)
    end

    test "a workspace below the root reads the root's file too, and names files from the root",
         %{repo: repo} do
      write!(repo, "AGENTS.md", "Run `npm test`.\n")
      write!(repo, "web/AGENTS.md", "Run `pnpm test`.\n")

      assert {text, 1} = Check.run(Path.join(repo, "web"), @everywhere)
      assert text =~ "web/AGENTS.md:1: contradiction: "
    end
  end

  defp findings(repo, opts \\ []) do
    %{root: root, sources: sources, elsewhere?: elsewhere?} = Check.sources(repo)

    Check.findings(
      sources,
      Keyword.merge([root: root, elsewhere?: elsewhere?] ++ @everywhere, opts)
    )
  end

  defp source(scope, where, path, content),
    do: %{path: path, scope: scope, where: where, unfollowed: [], content: content}

  defp write!(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end
end
