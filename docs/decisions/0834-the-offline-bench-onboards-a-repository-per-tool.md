---
number: 834
title: "The offline bench onboards a repository for each other tool, accepting every proposal and a new AGENTS.md, then holds a task that only the onboarded instructions can make come out right"
date: 2026-10-10
status: accepted
issue: 516
paths:
  - apps/troupe_core/lib/troupe/bench/onboarding.ex
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/lib/troupe/bench/runner.ex
  - apps/troupe_core/lib/troupe/bench/model.ex
  - apps/troupe_core/priv/bench/budgets.json
  - apps/troupe_core/test/troupe/bench_onboarding_test.exs
  - docs/developer/bench.md
symbols:
  - Troupe.Bench.Onboarding
  - Troupe.Bench.Onboarding.onboard/1
  - Troupe.Bench.Model.prompt_text/1
gist: "A bench fixture per tool, onboarded whole; the note holds only if the rule reached the prompt; nothing written or the rule lost fails"
---

Issue #516's slice 8, as the removal of the other tools' readers (Decision 828) leaves it:
a session reads no other tool's file, so whether a repository's instructions still reach a
prompt depends on onboarding alone (Decisions 823, 824, 827). Nothing held that. A change
to an onboarding source that dropped a rule, or wrote nothing, would pass every check CI
runs, and the person would find out from an agent ignoring their house rules.

- **A scenario per tool, in the offline suite.** `Troupe.Bench.Onboarding` adds
  `onboard_claude_code`, `onboard_opencode`, `onboard_cursor` and `onboard_copilot` to
  `troupe bench` (Decision 772), so CI's offline bench, `scripts/ci`, the installed `troupe
  bench` and `troupe doctor --bench` (Decision 821, now nine lines) all run them, against the
  scripted model, with no provider. Each fixture holds that tool's files only, and one house
  rule: "Every file you write starts with the line `# kept by <tool>'s rule`". Claude Code:
  `CLAUDE.md`, an agent, a command, and the person's `CLAUDE.local.md`. opencode: a primary
  agent in `.opencode/agents/`, `opencode.json` with a subagent and a disabled one, a
  command. Cursor: an always-applied rule, a rule for `docs/**`, and one in a folder under
  `.cursor/rules`. Copilot: `.github/copilot-instructions.md` and an `applyTo` file.
- **Onboarding as a person who says yes to everything.** Before the session starts, the
  scenario's `prepare` runs `Troupe.Onboard.plan/2` over the workspace and
  `Troupe.Onboard.accept/3` on every proposal, the new `AGENTS.md` among them, which `troupe
  onboard --yes` never creates (Decision 827): the bench answers that question yes, as the
  person at a terminal would, since proving the instructions arrive is the point. Not
  `troupe onboard` itself, which is the terminal UI's and cannot be called from the harness;
  its plan and its writes are these two functions. Onboarding is given the run's own config
  directory and a home directory of its own, so `~/.claude/CLAUDE.md` and the person's
  config are never read, and the real clock for `imported_at`, which no prompt carries.
- **A task only the onboarded instructions make come out right.** The scripted model's
  first step reads the request (`Troupe.Bench.Model.prompt_text/1`: the system prompt and
  each message's text, so the turn context of `system_prompt: stable`, Decision 815, counts
  too), and writes `note.txt` under the rule's line when it finds the rule and without it
  when it does not. The outcome is the file under the rule. So the outcome holds exactly when
  the rule reached the prompt: a rule the scripted model can see, as the live `follow_up`'s
  check sees whether a model kept "the root's rule" (Decision 815).
- **opencode's rule is in an agent.** opencode's own instruction file is `AGENTS.md`, which
  Troupe reads as it is, so there is nothing of opencode's to onboard there; what is
  opencode's alone is its agents. The rule is in a primary agent's prompt and the session
  starts on that agent (the scenario's `agent`), as a person who picks it in opencode would
  in Troupe. opencode's `instructions` key (more files to read as instructions) is not
  onboarded today; a fixture with one would fail here, which is the bench doing its job,
  and that mapping is #516's follow-up, not this slice's.
- **The measures.** `instruction_bytes`: what the instructions took of the first request's
  system prompt, the scratch workspace's path written `<workspace>` as everywhere in the
  bench; the instruction files' section, and for a session on an agent the workspace
  defines, that agent's prompt before it. `files_written`: the files onboarding wrote.
  `files_left_out`: the tool's files it found and did not bring in, skipped or refused, and
  any write that failed. A check, `onboarded`: onboarding wrote something and every write it
  tried succeeded. Budgets in `priv/bench/budgets.json`, maxima as all are: the bytes with
  about a tenth of headroom, the counts exact (`docs/developer/bench.md`'s rule). A fixture
  whose onboarding writes nothing fails `onboarded` and its outcome; one whose onboarding
  loses the rule fails its outcome; one that writes more files, leaves more out, or puts
  more in the prompt fails its budget. The first numbers: 519, 120, 507 and 484 bytes; 3, 3,
  2 and 2 files written; 1, 1, 1 and 0 left out.
- **No "before" measure.** The issue first drew prompt bytes before onboarding and after.
  Before, every fixture's instructions take nothing (Decision 828 lists the files as not
  read), so a "before" column is zero by construction and can never move. That the rule
  does not reach the prompt without onboarding is a test instead.
- **Two fields on a scenario, offline only.** `prepare` (a function of the run's
  `workspace`, `home`, `config_dir` and `state_dir`, run once the files are written and
  before the session starts, answering the marks the measure reads) and `agent` (the agent
  the session starts on). The live runner does not read them; its scenarios have neither.
- **Not changed.** On a machine a worker runs on (`TROUPE_WORKER_AUTOSTART=true`) onboarding
  refuses (Decision 826), so these four scenarios fail there with that sentence as their
  error. The bench is not run on a pod; giving it a way past the pod rule would be a second
  door through it.
- **Proof.** `Troupe.BenchOnboardingTest`: the four scenarios pass, each outcome held, the
  `onboarded` check, the counts; `instruction_bytes` equals what `Troupe.Instructions` makes
  of the onboarded files (and the opencode agent's prompt), read again in a scratch
  directory; without onboarding the Claude Code fixture's note does not hold (the
  reproduction, which on the chunk's tip passed while the bench had no onboarding scenario);
  with no source registered the scenario fails `onboarded` and its outcome; with a source
  that loses the rule it fails its outcome. `Troupe.BenchTest` (the suite's nine names, every
  budget measured, two runs the same JSON), and the terminal UI's `bench_cli_test.exs` and
  `doctor_test.exs`. And the installed `troupe bench` and `troupe doctor --bench`, on the pull
  request.
