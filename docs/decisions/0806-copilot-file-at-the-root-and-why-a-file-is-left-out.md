---
number: 806
title: Copilot's instruction file is read at the repository root only, and every instruction file left out says why, in words, in `context.get` and the session's log
date: 2026-10-06
status: accepted
issue: 123
supersedes: [706]
paths:
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/test/troupe/instructions_test.exs
  - apps/troupe_core/test/troupe/instructions_prompt_test.exs
  - apps/troupe_gateway/test/troupe/gateway/context_test.exs
symbols:
  - Troupe.Instructions.load/3
  - Troupe.Instructions.provenance/1
gist: "Copilot's file counts at the repo root only (elsewhere listed as skipped); a file left out carries `reason` in words, null for one read"
---

Issue #123, D78's first and fifth items. Decision 706 made `AGENTS.md`, `CLAUDE.md`,
`GEMINI.md` and `.github/copilot-instructions.md` one file under four names in every
directory, and 798 kept it. That is true of the first three, whose tools read them in
nested directories too, and not of the fourth: Copilot reads
`.github/copilot-instructions.md` at the repository root and nowhere else. So a nested
one, a package in a monorepo that was once a repository of its own or a vendored
checkout, reached Troupe's prompt where Copilot never reads it. And `context.get` said
of a file it did not read only a status, which the TUI printed as a bare "0".

- **Copilot's file at the root only.** At the repository root it is the fourth alias,
  as before: read when it is the only name there, skipped behind the others. In any
  other directory it is not an alias at all: it hides nothing, and it is listed as
  `skipped` with `not read: Copilot's file counts only at the root`, so nobody debugs a
  file that was never loaded. Not read from the person's own `<config>` either, and
  listed the same way if one is there: Copilot's file is a repository's, and the
  person's own file is `<config>/AGENTS.md`. Not chosen: reading it nested as well
  (706's), which reads what Copilot does not; dropping it everywhere, which leaves a
  repository with only a Copilot file with nothing. This is the part of 706 it
  supersedes. The maintainer's choice.
- **A reason, in words.** Every file in `context.get` and in the `instructions_loaded`
  event carries `reason`: null for a file that reached the prompt (and the brief when it
  is `absent` or `disabled`), and for one left out, why, in the words a person reads:
  `not read: outside the repository` (`outside the config directory` for the person's
  own file, Decision 798's edge), `skipped: AGENTS.md is used in this directory`, `not
  read: Copilot's file counts only at the root`, `left out: the budget was spent on
  nearer files`. Words rather than codes, so that every client says the same thing
  without a table of its own to keep in step with this one; `status` stays the code a
  program branches on.
- **A skipped alias is a file of its own.** Each alias the first name hid is listed
  right after that file and what it imports, with `status: skipped`, `size` and `chars`
  0 and `hash` null, as an `outside` file is, and its reason naming the first: `is used`
  when that one was read, `comes first` when it was not (a link out, which still hides
  the others, Decision 798). The first file's `skipped` keeps naming them, since a v1
  field is never dropped or retyped, and a client that reads only it is right as it
  was. A skipped file is not counted as read: an `@` import may still bring it in.
- **An import not followed keeps its code.** `unfollowed[].reason` is v1's already
  (`missing`, `outside`, `depth`, `cycle`) and is not retyped; `/context` puts it in
  words (TUI Decision 148).
- **Additive to v1.** A new key on each file, a new `status` value and new entries in
  `files`. Neither the result of `context.get` nor the event's `files` items are in the
  committed schema, and `mix troupe.schema.diff` finds nothing.
- **Proof:** `Troupe.InstructionsTest` (a root Copilot file read, a nested one alone
  and one beside an `AGENTS.md` listed as skipped with the reason and not in the
  prompt; aliases listed after the file read, each with `is used`; behind a link out,
  `comes first`; the reasons for `outside` and `dropped`, in the provenance too),
  `Troupe.InstructionsPromptTest` (a nested Copilot file on the way to a file the turn
  read is not in the next turn's prompt, and the event lists it as skipped with the
  reason; the person's own file outside `<config>` and the repository's outside the
  repository, each with its reason) and `Troupe.Gateway.ContextTest` (the alias with
  its reason, a nested Copilot file as skipped with its reason, an outside file's
  reason, over the protocol). The Copilot test failed on the chunk's tip with the
  nested file read into the prompt.
