defmodule Troupe.OnboardTest.Listed do
  @moduledoc """
  A source that proposes what `<workspace>/.other/proposals.json` lists, each with the
  sha256 of the file it names (or the `source_hash` the list gives): the stand-in for a
  real source (C26's agents and commands) in every test here.
  """

  @behaviour Troupe.Onboard.Source

  @impl true
  def proposals(workspace, opts) do
    workspace
    |> Path.join(".other/proposals.json")
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn p ->
      %{
        target: String.to_existing_atom(p["target"] || "repo"),
        path: p["path"],
        content: p["content"],
        source: p["source"],
        source_hash: p["source_hash"] || hash(workspace, p["source"], opts),
        notes: p["notes"] || []
      }
      |> also_from(p["also_from"], workspace, opts)
    end)
  end

  # What `.other/skipped.json` lists, when it is there.
  @impl true
  def skipped(workspace, _opts) do
    case File.read(Path.join(workspace, ".other/skipped.json")) do
      {:ok, text} -> for s <- Jason.decode!(text), do: %{source: s["source"], reason: s["reason"]}
      {:error, _} -> []
    end
  end

  defp also_from(proposal, nil, _workspace, _opts), do: proposal

  defp also_from(proposal, also, workspace, opts) do
    Map.put(
      proposal,
      :also_from,
      for(
        a <- also,
        do: %{
          source: a["source"],
          source_hash: a["source_hash"] || hash(workspace, a["source"], opts)
        }
      )
    )
  end

  defp hash(workspace, source, opts) do
    file =
      case source do
        "~/" <> rest -> Path.join(opts[:home], rest)
        source -> Path.join(workspace, source)
      end

    case File.read(file) do
      {:ok, bytes} -> :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      {:error, _} -> String.duplicate("0", 64)
    end
  end
end

defmodule Troupe.OnboardTest.Broken do
  @moduledoc "A source that raises, as a source with a bug would."
  @behaviour Troupe.Onboard.Source

  @impl true
  def proposals(_workspace, _opts), do: raise("the other tool's file is not what I expected")
end

defmodule Troupe.OnboardTest do
  @moduledoc """
  `Troupe.Onboard` (issue #516, slice 3; Decision 823): the one writer of onboarded files,
  confined to the workspace's `.troupe/` and the person's config directory by real path,
  recording `imported_from`, `imported_hash` and `imported_at`; the plan that proposes only
  what changed; a declined proposal that leaves nothing behind; and drift in `troupe
  instructions check`.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definition
  alias Troupe.Instructions.Check
  alias Troupe.Onboard
  alias Troupe.OnboardTest.{Broken, Listed}

  @now "2026-10-09T12:00:00Z"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-onboard-#{System.unique_integer([:positive])}")
    dirs = Map.new(~w(workspace config home state), &{String.to_atom(&1), Path.join(base, &1)})
    Enum.each(Map.values(dirs), &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(base) end)

    opts = [
      sources: [Listed],
      config_dir: dirs.config,
      home: dirs.home,
      state_dir: dirs.state,
      now: @now
    ]

    Map.merge(dirs, %{base: base, opts: opts})
  end

  @agent "---\ndescription: Reviews a change\ntools: [read_file]\n---\nYou review code.\n"

  describe "plan, accept and decline" do
    test "a new agent is proposed as a diff, written with its provenance, and a second run proposes nothing",
         ctx do
      write!(ctx.workspace, ".claude/agents/reviewer.md", "---\nname: reviewer\n---\nReview.\n")

      listed!(ctx, [
        %{path: "agents/reviewer.md", content: @agent, source: ".claude/agents/reviewer.md"}
      ])

      assert %{proposals: [item], refused: [], unchanged: 0, declined: 0} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert item.status == :new
      assert item.shown == ".troupe/agents/reviewer.md"
      assert item.diff =~ "+ description: Reviews a change"
      assert item.diff =~ ~s(+ imported_from: ".claude/agents/reviewer.md")
      refute File.exists?(Path.join(ctx.workspace, ".troupe")), "a plan writes nothing"

      assert {:ok, %{action: :created}} = Onboard.accept(item, ctx.workspace, ctx.opts)

      written = File.read!(Path.join(ctx.workspace, ".troupe/agents/reviewer.md"))
      hash = sha256(File.read!(Path.join(ctx.workspace, ".claude/agents/reviewer.md")))

      assert written ==
               "---\ndescription: Reviews a change\ntools: [read_file]\n" <>
                 ~s(imported_from: ".claude/agents/reviewer.md"\n) <>
                 ~s(imported_hash: "#{hash}"\n) <>
                 ~s(imported_at: "#{@now}"\n) <>
                 "imported_version: #{Onboard.version()}\n" <>
                 "---\nYou review code.\n"

      # Troupe reads it as the agent it is: the provenance keys are not configuration.
      assert {:ok, %{description: "Reviews a change", tools: ["read_file"]}} =
               Definition.parse("reviewer", written, :project)

      assert %{proposals: [], unchanged: 1} = Onboard.plan(ctx.workspace, ctx.opts)
    end

    test "a declined proposal leaves nothing behind, and is not asked about again until its source changes",
         ctx do
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      write!(ctx.workspace, ".claude/agents/b.md", "B\n")

      listed!(ctx, [
        %{path: "agents/a.md", content: "a\n", source: ".claude/agents/a.md"},
        %{path: "agents/b.md", content: "b\n", source: ".claude/agents/b.md"}
      ])

      assert %{proposals: [a, b]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert {:ok, _} = Onboard.accept(a, ctx.workspace, ctx.opts)
      assert :ok = Onboard.decline(b, ctx.opts)

      assert File.ls!(Path.join(ctx.workspace, ".troupe/agents")) == ["a.md"]

      assert files_under(Path.join(ctx.workspace, ".troupe")) == [
               ".troupe/agents/a.md",
               ".troupe/onboarded.json"
             ]

      assert File.ls!(ctx.config) == []

      assert %{proposals: [], unchanged: 1, declined: 1} = Onboard.plan(ctx.workspace, ctx.opts)

      # `--all` asks again.
      assert %{proposals: [%{shown: ".troupe/agents/b.md"}], declined: 0} =
               Onboard.plan(ctx.workspace, [all: true] ++ ctx.opts)

      # A changed source is a new question.
      write!(ctx.workspace, ".claude/agents/b.md", "B, changed\n")

      assert %{proposals: [%{shown: ".troupe/agents/b.md"}]} =
               Onboard.plan(ctx.workspace, ctx.opts)
    end

    test "a changed source is offered as a diff against the file, which stays as it is until accepted",
         ctx do
      write!(ctx.workspace, ".claude/commands/ship.md", "ship it\n")

      proposal = %{
        path: "commands/ship.md",
        content: "Ship it.\n",
        source: ".claude/commands/ship.md"
      }

      listed!(ctx, [proposal])

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)
      before = File.read!(Path.join(ctx.workspace, ".troupe/commands/ship.md"))

      write!(ctx.workspace, ".claude/commands/ship.md", "ship it, carefully\n")
      listed!(ctx, [%{proposal | content: "Ship it, carefully.\n"}])

      assert %{proposals: [changed]} =
               Onboard.plan(ctx.workspace, [now: "2026-10-10T08:00:00Z"] ++ ctx.opts)

      assert changed.status == :changed
      assert changed.was == ".claude/commands/ship.md"
      assert changed.diff =~ "- Ship it."
      assert changed.diff =~ "+ Ship it, carefully."
      assert changed.diff =~ ~s(+ imported_at: "2026-10-10T08:00:00Z")
      assert File.read!(Path.join(ctx.workspace, ".troupe/commands/ship.md")) == before

      assert {:ok, %{action: :replaced}} = Onboard.accept(changed, ctx.workspace, ctx.opts)
      assert File.read!(Path.join(ctx.workspace, ".troupe/commands/ship.md")) == changed.content
    end

    test "a person's own edit to an onboarded file stands while its source is unchanged", ctx do
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      listed!(ctx, [%{path: "agents/a.md", content: "a\n", source: ".claude/agents/a.md"}])

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)

      file = Path.join(ctx.workspace, ".troupe/agents/a.md")
      File.write!(file, String.replace(File.read!(file), "a\n", "a, as we run it here\n"))

      assert %{proposals: [], unchanged: 1} = Onboard.plan(ctx.workspace, ctx.opts)
    end

    test "a file that changed after it was shown is not overwritten", ctx do
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      listed!(ctx, [%{path: "agents/a.md", content: "a\n", source: ".claude/agents/a.md"}])

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      write!(ctx.workspace, ".troupe/agents/a.md", "written by hand meanwhile\n")

      assert {:error, reason} = Onboard.accept(item, ctx.workspace, ctx.opts)
      assert reason =~ ".troupe/agents/a.md changed since it was shown"

      assert File.read!(Path.join(ctx.workspace, ".troupe/agents/a.md")) ==
               "written by hand meanwhile\n"
    end

    test "a file onboarding did not write is offered as a replacement, never taken over silently",
         ctx do
      write!(ctx.workspace, ".troupe/agents/a.md", "mine\n")
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      listed!(ctx, [%{path: "agents/a.md", content: "a\n", source: ".claude/agents/a.md"}])

      assert %{proposals: [%{status: :changed, was: nil, diff: diff}]} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert diff =~ "- mine"
      assert File.read!(Path.join(ctx.workspace, ".troupe/agents/a.md")) == "mine\n"
    end

    test "a JSON file records its provenance in onboarded.json beside it, and AGENTS.md does too",
         ctx do
      write!(ctx.workspace, ".mcp.json", ~s({"mcpServers": {}}))
      write!(ctx.home, ".claude/CLAUDE.md", "Be brief.\n")

      listed!(ctx, [
        %{path: "mcp.json", content: ~s({"mcpServers": {}}\n), source: ".mcp.json"},
        %{
          target: "user",
          path: "AGENTS.md",
          content: "Be brief.\n",
          source: "~/.claude/CLAUDE.md"
        }
      ])

      assert %{proposals: [mcp, agents]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert {:ok, _} = Onboard.accept(mcp, ctx.workspace, ctx.opts)
      assert {:ok, _} = Onboard.accept(agents, ctx.workspace, ctx.opts)

      assert File.read!(Path.join(ctx.workspace, ".troupe/mcp.json")) == ~s({"mcpServers": {}}\n)
      assert File.read!(Path.join(ctx.config, "AGENTS.md")) == "Be brief.\n"

      assert %{
               "files" => %{
                 "mcp.json" => %{"imported_from" => ".mcp.json", "imported_at" => @now}
               }
             } =
               Jason.decode!(File.read!(Path.join(ctx.workspace, ".troupe/onboarded.json")))

      assert %{"files" => %{"AGENTS.md" => %{"imported_from" => "~/.claude/CLAUDE.md"}}} =
               Jason.decode!(File.read!(Path.join(ctx.config, "onboarded.json")))

      assert %{proposals: [], unchanged: 2} = Onboard.plan(ctx.workspace, ctx.opts)
    end

    test "a source that fails is refused by name and the others are still asked", ctx do
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      listed!(ctx, [%{path: "agents/a.md", content: "a\n", source: ".claude/agents/a.md"}])

      assert %{proposals: [_a], refused: [%{reason: reason}]} =
               Onboard.plan(ctx.workspace, Keyword.put(ctx.opts, :sources, [Broken, Listed]))

      assert reason =~
               "Troupe.OnboardTest.Broken failed: the other tool's file is not what I expected"
    end

    test "the files a source found and proposed nothing for are passed on with their reasons",
         ctx do
      listed!(ctx, [])

      write!(
        ctx.workspace,
        ".other/skipped.json",
        Jason.encode!([
          %{source: ".claude/agents/Bad Name.md", reason: "its name is not one Troupe can take"}
        ])
      )

      assert %{proposals: [], refused: [], skipped: [skipped]} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert skipped == %{
               source: ".claude/agents/Bad Name.md",
               reason: "its name is not one Troupe can take"
             }
    end

    test "a file made from other files too records each, and a change to any is a new proposal and drift",
         ctx do
      write!(ctx.workspace, ".git/HEAD", "ref: refs/heads/main\n")
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      write!(ctx.workspace, ".claude/settings.json", ~s({"permissions": {"allow": ["Read"]}}))

      listed!(ctx, [
        %{
          path: "agents/a.md",
          content: "---\ndescription: a\n---\na\n",
          source: ".claude/agents/a.md",
          also_from: [%{source: ".claude/settings.json"}]
        }
      ])

      assert %{proposals: [item]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert {:ok, _} = Onboard.accept(item, ctx.workspace, ctx.opts)

      settings = sha256(File.read!(Path.join(ctx.workspace, ".claude/settings.json")))
      written = File.read!(Path.join(ctx.workspace, ".troupe/agents/a.md"))

      assert written =~
               ~s(imported_also: [{"from":".claude/settings.json","hash":"#{settings}"}]\n)

      assert %{proposals: [], unchanged: 1} = Onboard.plan(ctx.workspace, ctx.opts)

      write!(
        ctx.workspace,
        ".claude/settings.json",
        ~s({"permissions": {"allow": ["Read", "Bash"]}})
      )

      assert %{proposals: [%{status: :changed, diff: diff}]} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert diff =~ "- imported_also:"

      check = [executable?: fn _ -> true end, config_dir: ctx.config, home: ctx.home]
      assert {out, 1} = Check.run(ctx.workspace, check)

      assert out =~
               ".troupe/agents/a.md:6: drift: imported with `.claude/settings.json`, which has " <>
                 "changed since; `troupe onboard` shows what changed\n"

      refute out =~ "imported from `.claude/agents/a.md`"

      # A hash that is not the file's, and a file outside the workspace, are refused.
      write!(ctx.base, "elsewhere.json", "{}")

      assert [%{reason: wrong}, %{reason: outside}] =
               refusals(ctx, [
                 %{
                   path: "agents/b.md",
                   content: "b",
                   source: ".claude/agents/a.md",
                   also_from: [
                     %{source: ".claude/settings.json", source_hash: String.duplicate("b", 64)}
                   ]
                 },
                 %{
                   path: "agents/c.md",
                   content: "c",
                   source: ".claude/agents/a.md",
                   also_from: [%{source: "../elsewhere.json"}]
                 }
               ])

      assert wrong == "its hash of `.claude/settings.json` is not that file's sha256 as it is now"
      assert outside == "`../elsewhere.json` is outside the workspace"
    end
  end

  describe "the two roots" do
    test "a path outside them, or naming a file onboarding does not write, is refused and nothing is written",
         ctx do
      write!(ctx.workspace, "src.md", "s\n")
      write!(ctx.home, ".claude/agents/a.md", "A\n")

      refused =
        refusals(ctx, [
          %{path: "../escape.md", content: "x", source: "src.md"},
          %{path: "agents/../../escape.md", content: "x", source: "src.md"},
          %{path: "/tmp/escape.md", content: "x", source: "src.md"},
          %{path: "~/escape.md", content: "x", source: "src.md"},
          %{path: "agents\\a.md", content: "x", source: "src.md"},
          %{path: "config.yaml", content: "auto_approve: true\n", source: "src.md"},
          %{path: "config.local.yaml", content: "x", source: "src.md"},
          %{path: "memory.md", content: "x", source: "src.md"},
          %{path: "onboarded.json", content: "{}", source: "src.md"},
          %{path: "agents/Not A Name.md", content: "x", source: "src.md"},
          %{path: "AGENTS.md", content: "x", source: "src.md"},
          %{
            target: "user",
            path: "credentials.json",
            content: "{}",
            source: "~/.claude/agents/a.md"
          },
          %{target: "user", path: "config.yaml", content: "x", source: "~/.claude/agents/a.md"}
        ])

      repo =
        "commands/<name>.md, rules/<name>.md, skills/<name>/..., workflows/<name>.json and mcp.json"

      assert Enum.map(refused, & &1.reason) == [
               "`../escape.md` has an empty, `.` or `..` part",
               "`agents/../../escape.md` has an empty, `.` or `..` part",
               "`/tmp/escape.md` is not relative: a path is relative to .troupe/ or to your config directory",
               "`~/escape.md` is not relative: a path is relative to .troupe/ or to your config directory",
               "`agents\\a.md` has a backslash: write it with /",
               "`config.yaml` is not a file onboarding writes: it writes agents/<name>.md, " <>
                 repo,
               "`config.local.yaml` is not a file onboarding writes: it writes agents/<name>.md, " <>
                 repo,
               "`memory.md` is not a file onboarding writes: it writes agents/<name>.md, " <> repo,
               "`onboarded.json` is not a file onboarding writes: it writes agents/<name>.md, " <>
                 repo,
               "`agents/Not A Name.md` is not a file onboarding writes: it writes agents/<name>.md, " <>
                 repo,
               "`AGENTS.md` is not a file onboarding writes: it writes agents/<name>.md, " <> repo,
               "`credentials.json` is not a file onboarding writes: it writes agents/<name>.md, " <>
                 "commands/<name>.md, skills/<name>/..., workflows/<name>.json and mcp.json, " <>
                 "and your own AGENTS.md",
               "`config.yaml` is not a file onboarding writes: it writes agents/<name>.md, " <>
                 "commands/<name>.md, skills/<name>/..., workflows/<name>.json and mcp.json, " <>
                 "and your own AGENTS.md"
             ]

      assert nothing_written?(ctx)
    end

    test "a repository's file goes into the repository and the person's own into their config, never across",
         ctx do
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      write!(ctx.home, ".claude/agents/b.md", "B\n")
      write!(ctx.base, "elsewhere/c.md", "C\n")

      refused =
        refusals(ctx, [
          %{target: "user", path: "agents/a.md", content: "a", source: ".claude/agents/a.md"},
          %{target: "repo", path: "agents/b.md", content: "b", source: "~/.claude/agents/b.md"},
          %{target: "repo", path: "agents/c.md", content: "c", source: "../elsewhere/c.md"},
          %{target: "repo", path: "agents/d.md", content: "d", source: ".claude/agents/none.md"},
          %{
            target: "repo",
            path: "agents/e.md",
            content: "e",
            source: ".claude/agents/a.md",
            source_hash: String.duplicate("a", 64)
          }
        ])

      assert Enum.map(refused, & &1.reason) == [
               "`.claude/agents/a.md` does not start with ~/: a file written into your config " <>
                 "directory comes from your home directory",
               "`~/.claude/agents/b.md` is in your home directory: a file written into the " <>
                 "repository's .troupe/ comes from the repository",
               "`../elsewhere/c.md` is outside the workspace",
               "`.claude/agents/none.md` is not there",
               "its hash of `.claude/agents/a.md` is not that file's sha256 as it is now"
             ]

      assert nothing_written?(ctx)
    end

    test "a .troupe, or an agents directory in it, that links out is not written through", ctx do
      write!(ctx.workspace, ".claude/agents/a.md", "A\n")
      outside = Path.join(ctx.base, "outside")
      File.mkdir_p!(outside)
      listed!(ctx, [%{path: "agents/a.md", content: "a\n", source: ".claude/agents/a.md"}])

      :ok = File.ln_s(outside, Path.join(ctx.workspace, ".troupe"))

      assert %{proposals: [], refused: [%{reason: reason}]} =
               Onboard.plan(ctx.workspace, ctx.opts)

      assert reason =~
               "`agents/a.md` resolves to #{outside}/agents/a.md, outside the workspace's .troupe/"

      File.rm!(Path.join(ctx.workspace, ".troupe"))
      File.mkdir_p!(Path.join(ctx.workspace, ".troupe"))
      :ok = File.ln_s(outside, Path.join(ctx.workspace, ".troupe/agents"))
      assert %{refused: [%{reason: reason}]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert reason =~ "outside the workspace's .troupe/"

      # Inside the workspace but not .troupe/ is outside too.
      File.rm!(Path.join(ctx.workspace, ".troupe/agents"))

      :ok =
        File.ln_s(
          Path.join(ctx.workspace, ".claude/agents"),
          Path.join(ctx.workspace, ".troupe/agents")
        )

      assert %{refused: [%{reason: reason}]} = Onboard.plan(ctx.workspace, ctx.opts)
      assert reason =~ "outside the workspace's .troupe/"

      assert File.ls!(outside) == []
      assert File.read!(Path.join(ctx.workspace, ".claude/agents/a.md")) == "A\n"
    end

    test "a source that links out of the workspace is refused", ctx do
      write!(ctx.base, "secret.txt", "s\n")
      File.mkdir_p!(Path.join(ctx.workspace, ".claude/agents"))

      :ok =
        File.ln_s(
          Path.join(ctx.base, "secret.txt"),
          Path.join(ctx.workspace, ".claude/agents/a.md")
        )

      assert [%{reason: "`.claude/agents/a.md` is outside the workspace"}] =
               refusals(ctx, [%{path: "agents/a.md", content: "a", source: ".claude/agents/a.md"}])
    end
  end

  describe "drift in troupe instructions check" do
    test "an onboarded file whose source changed, or went, is a finding with its line; an unchanged one is not",
         ctx do
      write!(ctx.workspace, ".git/HEAD", "ref: refs/heads/main\n")
      write!(ctx.workspace, "AGENTS.md", "# Rules\n\nKeep every change small.\n")
      write!(ctx.workspace, ".claude/agents/reviewer.md", "R\n")
      write!(ctx.workspace, ".mcp.json", "{}")
      write!(ctx.home, ".claude/agents/mine.md", "M\n")

      listed!(ctx, [
        %{path: "agents/reviewer.md", content: @agent, source: ".claude/agents/reviewer.md"},
        %{path: "mcp.json", content: "{}\n", source: ".mcp.json"},
        %{
          target: "user",
          path: "agents/mine.md",
          content: "m\n",
          source: "~/.claude/agents/mine.md"
        }
      ])

      %{proposals: items} = Onboard.plan(ctx.workspace, ctx.opts)
      Enum.each(items, &({:ok, _} = Onboard.accept(&1, ctx.workspace, ctx.opts)))

      check = [executable?: fn _ -> true end, config_dir: ctx.config, home: ctx.home]

      assert {out, 0} = Check.run(ctx.workspace, check)
      assert out =~ "no findings in 1 instruction file and 3 onboarded files"

      write!(ctx.workspace, ".claude/agents/reviewer.md", "R, changed\n")
      File.rm!(Path.join(ctx.workspace, ".mcp.json"))
      write!(ctx.home, ".claude/agents/mine.md", "M, changed\n")

      assert {out, 1} = Check.run(ctx.workspace, check)

      assert out =~
               ".troupe/agents/reviewer.md:5: drift: imported from `.claude/agents/reviewer.md`, " <>
                 "which has changed since; `troupe onboard` shows what changed\n"

      assert out =~
               ".troupe/mcp.json:1: drift: imported from `.mcp.json`, which is not there any more\n"

      assert out =~
               "#{Troupe.Paths.display(Path.join(ctx.config, "agents/mine.md"))}:3: drift: " <>
                 "imported from `~/.claude/agents/mine.md`, which has changed since"

      assert out =~ "3 findings in 1 instruction file and 3 onboarded files."

      assert {json, 1} = Check.run(ctx.workspace, [json: true] ++ check)
      decoded = Jason.decode!(json)
      assert Enum.count(decoded["findings"], &(&1["kind"] == "drift")) == 3

      assert %{
               "file" => ".troupe/agents/reviewer.md",
               "imported_from" => ".claude/agents/reviewer.md"
             } =
               Enum.find(decoded["onboarded"], &(&1["file"] == ".troupe/agents/reviewer.md"))
    end

    test "a recorded source outside the workspace is passed over, and a hand-written file has no record",
         ctx do
      write!(ctx.base, "elsewhere.md", "E\n")

      write!(ctx.workspace, ".troupe/agents/a.md", """
      ---
      imported_from: "../elsewhere.md"
      imported_hash: "#{String.duplicate("0", 64)}"
      ---
      a
      """)

      write!(ctx.workspace, ".troupe/agents/b.md", "---\ndescription: mine\n---\nb\n")

      assert %{files: [%{path: "agents/a.md"}], findings: findings} =
               Onboard.drift(ctx.workspace, config_dir: ctx.config, home: ctx.home)

      # The record is not followed out; it is only an older onboarding's, which it says.
      assert [%{kind: :outdated}] = findings
    end
  end

  ## Helpers

  defp listed!(ctx, proposals) do
    list =
      Enum.map(proposals, fn p ->
        p |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end) |> Map.put_new("target", "repo")
      end)

    write!(ctx.workspace, ".other/proposals.json", Jason.encode!(list))
  end

  defp refusals(ctx, proposals) do
    listed!(ctx, proposals)
    assert %{proposals: [], refused: refused} = Onboard.plan(ctx.workspace, ctx.opts)
    assert length(refused) == length(proposals)
    refused
  end

  defp nothing_written?(ctx) do
    not File.exists?(Path.join(ctx.workspace, ".troupe")) and File.ls!(ctx.config) == [] and
      File.ls!(ctx.state) == []
  end

  defp files_under(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, Path.dirname(dir)))
  end

  defp write!(dir, relative, contents) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
