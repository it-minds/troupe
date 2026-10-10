---
number: 828
title: A session reads no other tool's file at run time, CLAUDE.md, GEMINI.md, Copilot's and Cursor's rules and opencode's settings among them; each instruction file found is listed as not read, and Troupe's own rules are `.troupe/rules/*.md`
date: 2026-10-10
status: accepted
issue: 516
supersedes: [683, 706, 806, 809]
paths:
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/instructions/check.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/open_code.ex
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - clients/tui/lib/troupe/cli/config_setup.ex
  - install.sh
  - install.ps1
  - docs/user/configuration.md
  - apps/troupe_core/test/troupe/instructions_test.exs
  - apps/troupe_core/test/troupe/instructions_prompt_test.exs
  - apps/troupe_core/test/troupe/instructions_check_test.exs
  - apps/troupe_core/test/troupe/config_providers_test.exs
  - apps/troupe_gateway/test/troupe/gateway/context_test.exs
  - clients/tui/test/troupe/context_command_test.exs
  - clients/tui/test/troupe/config_setup_test.exs
symbols:
  - Troupe.Instructions.load/3
  - Troupe.Instructions.Check.sources/1
  - Troupe.Config.resolve/3
  - Troupe.Config.ModelSettings.import_opencode/1
gist: "No run-time read of CLAUDE.md, GEMINI.md, Copilot's, Cursor's or opencode's files; each found is listed skipped; rules are .troupe/rules/*.md"
---

Issue #516, its sixth slice. The maintainer decided that other tools' configuration stops
being read at run time: it is brought into Troupe's own files once (`troupe onboard`,
Decision 823), and a session reads only those, `AGENTS.md` and `.agents/` (Decision 822).
For this wave the maintainer also decided the two things #516 left open for this slice:
**Cursor's rules are onboarded too**, not read in place (#516's first decision, against
its recommendation), and **the readers go now**, with no release of warning and no key to
keep the old reading (its fifth). Two run-time readers were left, and this removes both.

**What a person upgrading sees.** A repository whose agents' instructions are in a
`CLAUDE.md`, a `GEMINI.md`, `.github/copilot-instructions.md`, `.cursorrules` or
`.cursor/rules/*.mdc` no longer has them in any session's prompt until `troupe onboard` is
run there (or the person moves them into `AGENTS.md` and `.troupe/rules/` by hand).
`/context` lists each such file as `not read: run troupe onboard`, and the session's
first start in such a workspace says what `troupe onboard` would propose (Decision 827).
A machine that reached a model only through opencode's `opencode.jsonc` and `auth.json`
has no provider until opencode's providers are copied into `config.yaml`: `troupe config`
and `troupe setup` offer the copy on a machine with no settings, and `troupe-daemon config
import-opencode` makes it.

- **The instruction files (supersedes the aliases of 706 and 806).** One name is read in a
  directory: `AGENTS.md`, beside `.agents/AGENTS.md` (822), in the person's own
  `<config>`, the repository root and each directory on the way to where the session
  works (798). `CLAUDE.md` and `GEMINI.md`, which 706 read as aliases wherever they were,
  and Copilot's `.github/copilot-instructions.md`, which 806 read at the root, are no
  longer read anywhere: each one found in one of those directories is listed in
  `context.get`, the `instructions_loaded` event and `/context` as `skipped`, with
  `reason` `not read: run troupe onboard`, its `size`, `chars` and `hash` empty, and
  nothing of it read, a link's target included. A Copilot file below the root keeps
  806's reason, `not read: Copilot's file counts only at the root`, because it never
  counted and onboarding does not take it. Nothing hides anything any more, so a file's
  `skipped` is always `[]`; the field stays, since a v1 field is never dropped, and a
  client that reads only it is right. `@CLAUDE.md` written in an `AGENTS.md` is still an
  import the person asked for, and is followed as any import is (798).
- **Rules (supersedes 809's place, keeps its meaning).** `.troupe/rules/*.md` is read
  where `.cursor/rules/*.mdc` was: at the repository root and in each directory on the way
  to where the session works, after the directory's `AGENTS.md`, in name order, only the
  files directly in it. Its front matter is the one 809 read from an `.mdc`
  (`description`, `globs` as a list or a comma-separated string, `alwaysApply`), and means
  what it meant there: an always rule joins every prompt; a `globs` rule joins from the
  turn after a file it matches is worked on, the globs taken from the directory that holds
  `.troupe`; a description-only rule is listed by its description and not joined; one
  with none is `inactive`. Confined by real path as before: a rule, a `.troupe/rules` or a
  whole `.troupe` that is really outside the repository is `outside`, a directory listed
  once and not looked into. The budget, `applies`, `reason` and `rule` are 809's. Not in
  the person's `<config>`, as 809 had it. `.troupe/rules/` is what the instruction files'
  onboarding source writes (`rules/<name>.md`, Decision 827). The legacy `.cursorrules`,
  which 809 joined as an always rule, and every `.cursor/rules/*.mdc` are now listed as
  `skipped`, `not read: run troupe onboard`, and a `.cursor/rules` linked out of the
  repository is still listed once as `outside` and not looked into. Not chosen: reading
  `.cursor/rules` in place and
  `.troupe/rules` beside it (#516's recommendation, overruled), which keeps a format Troupe
  does not own read at every turn; a `<config>/rules` for the person, which nothing
  writes.
- **A file that cannot be read is listed (D84, D99).** One found in a directory, an
  `AGENTS.md`, an `.agents/AGENTS.md` or a rule, that is there and cannot be read was
  logged and left out of `context.get`. It is now listed with the new `status`
  `unreadable` and `reason` `not read: <why>` (`permission denied`), nothing of it in the
  prompt. An import that cannot be read is still `missing` on its importer.
- **An `.agents` directory has no file of its own.** A session that worked on a file
  under `.agents/` walked `.agents` as a directory on the way and read its `AGENTS.md` a
  second time, as that directory's own, beside its parent's `.agents/AGENTS.md` (822).
  It is read once, as the parent's. Found by `troupe instructions check`, which works on
  every file.
- **`troupe instructions check` follows the loader (810, unchanged).** It checks what the
  loader reads, so `.troupe/rules` are checked and the files listed as skipped are not.
  A path written in `<dir>/.agents/AGENTS.md`, or in a rule in `<dir>/.troupe/rules`, is
  looked for from `<dir>`, the directory the file is about, as well as from its own
  directory and the root (D99: a nested one was called missing); 810's preference for a
  missed finding over a false one is why the file's own directory stays a base.
- **opencode's settings (supersedes 683's premise).** `Troupe.Config.resolve/3` no
  longer reads `opencode.jsonc` or `auth.json`: a configuration with no key of its own has
  no opencode providers and no opencode default model, `config.get`'s `api_key_source`
  is never `opencode` and its `overrides` name no opencode fallback, no setting's `layer`
  is `opencode`, and `troupe config`'s report no longer names opencode's path. What reads
  them is the one-time copy, `Troupe.Config.ModelSettings.import_opencode/1`, called by
  `config.import` (`troupe config`'s first run), the first run's `reuse: opencode`
  (`setup.answer`, in the terminal UI and the desktop app) and `troupe-daemon config
  import-opencode` (the installers); and `Troupe.Setup.detect/0`, which looks to offer
  that copy. `troupe config` now asks the daemon what opencode declares (`setup.get`'s
  `detected`) instead of what a session would use, offers the copy saying Troupe does not
  read opencode's settings, and a no goes on to the other ways to a model; the installers
  say the same and go on to `troupe config` after a no. opencode's agents, commands and
  MCP servers were never read at run time; onboarding (824) and `/mcp import` (820) copy
  them.
- **Not in this slice.** The first session's proposal and the instruction files'
  onboarding source and the librarian's prompt (Decision 827); Copilot's
  `.github/instructions/*.instructions.md`, never read, which onboarding takes; a file
  already onboarded still saying `run troupe onboard` (it does not read
  `.troupe/onboarded.json`); the desktop app's and VS Code's labels for a model `from
  opencode`, which no daemon now sends.
- **Proof.** `Troupe.InstructionsTest` (each other tool's file, at the root and nested,
  listed as skipped with the reason and none of it in the prompt; Copilot's nested file
  with 806's reason; an unreadable `AGENTS.md` and `.agents/AGENTS.md` listed; `.agents`
  read once when the session works under it; each kind of rule in `.troupe/rules`, its
  globs' forms, a nested one, linked out, the budget), `Troupe.InstructionsPromptTest`
  (a repository with only another tool's file reaches no prompt and the event says to run
  `troupe onboard`; the three kinds of rule in a real session),
  `Troupe.Instructions.CheckTest` (`.troupe/rules` checked and the skipped files not; a
  path in a nested `.agents/AGENTS.md` and a nested rule resolved from their directory),
  `Troupe.ConfigProvidersTest` (no
  opencode provider, default, warning, ladder entry or report line with no key of its
  own), `Troupe.Config.ModelSettingsTest` (nothing of opencode's before the copy, the
  copy as before), `Troupe.Gateway.ContextTest` (`context.get` lists a `CLAUDE.md`, a
  Cursor rule and an unreadable `.agents/AGENTS.md`), and the TUI's `ContextCommandTest`
  and `ConfigSetupTest`. On the chunk's tip ten of the loader's and the config's tests
  failed: a `CLAUDE.md` was read, `.troupe/rules` were not, an unreadable file was not
  listed, and opencode's providers and default model were the configuration's; the check's
  `.agents` test failed with the paths called missing, and the loader's with the file
  read twice.
