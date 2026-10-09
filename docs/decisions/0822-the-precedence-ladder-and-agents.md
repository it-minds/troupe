---
number: 822
title: Configuration is taken from the highest step of one ladder, built-ins, a pod's bundle, `.agents/`, `AGENTS.md`, the person's `<config>/`, the repository's `.troupe/`, and `.agents/` is read as `.agents/skills` and `.agents/AGENTS.md` only
date: 2026-10-09
status: accepted
issue: 516
paths:
  - apps/troupe_core/lib/troupe/skills/local.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - docs/user/configuration.md
  - apps/troupe_core/test/troupe/ladder_test.exs
  - apps/troupe_core/test/troupe/skills/local_test.exs
  - apps/troupe_core/test/troupe/instructions_test.exs
  - apps/troupe_gateway/test/troupe/gateway/context_test.exs
  - apps/troupe_gateway/test/troupe/gateway/local_sources_test.exs
symbols:
  - Troupe.Skills.Local.resolve/2
  - Troupe.Skills.Local.agents_home/1
  - Troupe.Instructions.load/3
  - Troupe.Instructions.repository_root/1
gist: "Ladder: .agents/ < AGENTS.md < <config>/ < .troupe/; a hidden skill is listed skipped with why; .agents/ is skills + AGENTS.md only, confined by real path"
---

Issue #516, its first slice. The maintainer decided that other tools' configuration
stops being read at runtime: it is brought in once, into Troupe's own files, and a session
reads only those (`.troupe/` and the person's `<config>/`) and the two conventions that
belong to no one tool, `AGENTS.md` and `.agents/`, Troupe's own winning where they
conflict. That needs the order written down once and kept in one place, and `.agents/`,
which Troupe did not read at all, read.

- **What `.agents/` is.** There is no ratified standard (#516's research). What has real
  adoption is `.agents/skills/`: a directory of skill folders, each with a `SKILL.md`,
  scanned from the working directory up to the repository root, with `~/.agents/skills`
  as the user level; Codex reads it and other tools reach it by a link. Commands have
  folded into skills across the tools, so there is no `.agents/commands/` worth reading.
  A broader draft (`dotagentsprotocol.com`, marked DRAFT, dated 2026-02-24) proposes one
  directory for `AGENTS.md`, a system prompt, MCP configuration, model configuration,
  skills and subagents; that is inferred from the site, not a ratified specification,
  and sources disagree on where the user level lives. The maintainer's choice (#516's
  second decision): **`.agents/` means `.agents/skills/` and `.agents/AGENTS.md`, and
  nothing else.** The rest of the draft (a system prompt, MCP, models, subagents under
  `.agents/`) is not implemented, nor is a `~/.agents/AGENTS.md`; a later decision can
  take them up if the draft is ratified.
- **The ladder**, lowest first: Troupe's built-ins; a profile's bundle, on a pod;
  `.agents/`; `AGENTS.md`, the root's then each directory's on the way to the work;
  the person's `<config>/`; the repository's `.troupe/`. What has a name (an agent, a
  skill, a command, an MCP server) comes from the highest step that has it; instruction
  files all apply, the higher later in the prompt and kept whole first. Written once, in
  `docs/user/configuration.md` ("Which one wins"), and enforced where each kind is
  merged: `Troupe.Skills.Local.resolve/2` for a person's and a repository's skills (with
  the bundle beneath, in `Troupe.Skills.available/3`), `Troupe.Agent.Definitions.load/2`
  for agents, `Troupe.Instructions.load/3` for instruction files. The bundle's line is
  Decision 826's: on a pod the bundle's agents and skills beat the repository's
  `.agents/` and `.troupe/` unless the profile allows the repository's.
- **`.agents/skills` is a layer, read in place.** Below Troupe's own two
  (`<config>/skills`, `.troupe/skills`, Decision 700): `~/.agents/skills` lowest
  (`user_agents`), then each `.agents/skills` from the repository root down to the
  workspace (`agents`), the nearest highest, the root being the one the instruction files
  are read up to (`Troupe.Instructions.repository_root/1`: the nearest directory with a
  `.git`, or the workspace). Never written: a person brings a skill into Troupe's own
  layers with `skills.add` as before, and onboarding is slice 3's. The directories
  outside the workspace are read roots of the session, so a skill's files can be read
  where they are, as a linked root's are. Not chosen: copying `.agents/skills` into
  `.troupe/skills` (a second copy that goes stale, and a write nobody asked for); reading
  `.agents/skills` below the workspace as the conversation works there (skills are
  offered when the session starts, and the convention scans up, not down); `~/.agents`
  above the repository's (the person's own layer is below the repository's everywhere
  else, `<config>/` under `.troupe/`).
- **A name lost is listed, with why.** `resolve/2` answers what is offered and every
  skill the layers hold and do not offer, in ladder order: `skipped`, with
  `skipped: <dir> is used` naming the directory of the one offered, when a higher step
  has the name (between Troupe's two layers, and a layer's link against its own
  directory, too, as they always shadowed); `skipped` with `not a skill name` for an
  `.agents/skills` folder no skill may be called; `outside` for one not read.
  `skills.list` answers them as `skipped` beside `skills`, additive (its result is not in
  the committed schema), so nobody debugs a skill that was never offered. As `/context`
  does for instruction files (Decision 806), in words, not codes.
- **Confined by real path**, as instruction files are (Decision 798): a repository's
  `.agents/skills` is held to the repository root and `~/.agents/skills` to `~/.agents`.
  An `.agents/skills` that is a link out is listed once, with no name, and not looked
  into, so not even the names of what is there are said; a skill folder or a `SKILL.md`
  linked out is `outside` and its front matter is never read, nor its directory made a
  read root. `.troupe/skills` is not confined here: that is #512, folded into slice 3.
- **`.agents/AGENTS.md` is an instruction file of its directory.** In the repository
  root and in each directory on the way to where the session works (798's directories),
  read right before that directory's own file (the alias chosen there) and in its scope,
  so it is the farther of the two and the directory's own wins where they disagree; in
  the budget it is a scope of its own, cut before the directory's own file. It is no
  alias: it hides nothing and nothing hides it. Its imports are followed from the
  repository, as any repository file's are; one really outside the repository, through a
  linked `.agents`, is `outside` and not read. `context.get`, the `instructions_loaded`
  event and `/context` name it with its directory's scope (`.agents/AGENTS.md (root)`);
  no new scope, so no client changes. `troupe instructions check` checks it, since it
  checks the loader's files (Decision 810). Not in the person's own `<config>`, whose
  file is `<config>/AGENTS.md`.
- **The person's own `<config>/AGENTS.md` stays first.** #516's ladder puts `<config>/`
  above `AGENTS.md`, and for everything with a name that holds. Instruction files have no
  name to lose, and Decisions 706 and 798 read the person's own file first, below the
  repository's, as every other tool reads its user-level file: it is about every
  repository, and the repository's is about this one, so where they disagree the
  repository's wins and the budget keeps it whole first. This slice leaves that order as
  it is and says so in the ladder; moving the person's file after the repository's is a
  change to 706's and 798's order, and the budget's, for the maintainer to make or not.
- **Not in this slice.** Retiring `CLAUDE.md`, `GEMINI.md` and Copilot's file (slice 6);
  onboarding and the writer (slice 3); other tools' agents and commands (slice 4); the
  pod rule's detail (Decision 826); the terminal UI's `/mcp` page naming the new layers
  (it shows an unknown layer as `session`) and the desktop app's.
- **Proof:** `Troupe.LadderTest` (a step at a time: an agent from a built-in, then the
  bundle's, then `<config>/agents`, then `.troupe/agents`; one skill name in
  `~/.agents/skills`, the root's `.agents/skills`, the workspace's, `<config>/skills` and
  `.troupe/skills`, peeled from the top, each time the highest offered and every one below
  skipped naming it; the instruction files in order, the person's own first and the
  brief last, and a budget that keeps a directory's `AGENTS.md` whole and cuts its
  `.agents/AGENTS.md`), `Troupe.Skills.LocalTest` (`.agents/skills` offered, nearest
  first up to the root, `~/.agents/skills` below, a directory off the way not read;
  `.troupe/skills` beating `.agents` with the loser skipped and why; a skill, a whole
  `.agents/skills` and a `~/.agents` skill linked out listed as `outside`, not read and
  not read roots), `Troupe.InstructionsTest` (`.agents/AGENTS.md` at the root and nested,
  before the directory's own, in the prompt and the provenance; a linked-out `.agents`
  not read), `Troupe.Gateway.ContextTest` (`context.get` names it with its scope, and a
  linked-out one as `outside`) and `Troupe.Gateway.LocalSourcesTest` (`skills.list` with
  the `agents` layer and the skipped entry). The first two, and the context test, failed
  on the chunk's tip: no `.agents` skill was offered and `.agents/AGENTS.md` was not read.
