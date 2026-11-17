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
symbols:
  - Troupe.Skills.Local.resolve/2
  - Troupe.Skills.Local.agents_home/1
  - Troupe.Instructions.load/3
  - Troupe.Instructions.repository_root/1
gist: "Ladder: .agents/ < AGENTS.md < <config>/ < .troupe/; a hidden skill is listed skipped with why; .agents/ is skills + AGENTS.md only, confined by real path"
---

- **What `.agents/` is.** The maintainer's choice (#516's second decision): **`.agents/`
  means `.agents/skills/` and `.agents/AGENTS.md`, and nothing else.**
- **The ladder**, lowest first: Troupe's built-ins; a profile's bundle, on a pod;
  `.agents/`; `AGENTS.md`, the root's then each directory's on the way to the work; the
  person's `<config>/`; the repository's `.troupe/`. What has a name (an agent, a skill, a
  command, an MCP server) comes from the highest step that has it; instruction files all
  apply, the higher later in the prompt and kept whole first.
- **`.agents/skills` is a layer, read in place.** Below Troupe's own two
  (`<config>/skills`, `.troupe/skills`, Decision 700): `~/.agents/skills` lowest
  (`user_agents`), then each `.agents/skills` from the repository root down to the
  workspace (`agents`), the nearest highest, the root being the one the instruction files
  are read up to (`Troupe.Instructions.repository_root/1`: the nearest directory with a
  `.git`, or the workspace). Not chosen: copying `.agents/skills` into `.troupe/skills` (a
  second copy that goes stale, and a write nobody asked for); reading `.agents/skills`
  below the workspace as the conversation works there (skills are offered when the session
  starts, and the convention scans up, not down); `~/.agents` above the repository's (the
  person's own layer is below the repository's everywhere else, `<config>/` under
  `.troupe/`).
- **A name lost is listed, with why.** `resolve/2` answers what is offered and every skill
  the layers hold and do not offer, in ladder order: `skipped`, with `skipped: <dir> is
  used` naming the directory of the one offered, when a higher step has the name (between
  Troupe's two layers, and a layer's link against its own directory, too, as they always
  shadowed); `skipped` with `not a skill name` for an `.agents/skills` folder no skill may
  be called; `outside` for one not read.
- **Confined by real path**, as instruction files are (Decision 798): a repository's
  `.agents/skills` is held to the repository root and `~/.agents/skills` to `~/.agents`.
  An `.agents/skills` that is a link out is listed once, with no name, and not looked
  into, so not even the names of what is there are said; a skill folder or a `SKILL.md`
  linked out is `outside` and its front matter is never read, nor its directory made a
  read root.
- **`.agents/AGENTS.md` is an instruction file of its directory.** In the repository root
  and in each directory on the way to where the session works (798's directories), read
  right before that directory's own file (the alias chosen there) and in its scope, so it
  is the farther of the two and the directory's own wins where they disagree; in the
  budget it is a scope of its own, cut before the directory's own file.
- **The person's own `<config>/AGENTS.md` stays first.** Instruction files have no name to
  lose, and Decisions 706 and 798 read the person's own file first, below the
  repository's, as every other tool reads its user-level file: it is about every
  repository, and the repository's is about this one, so where they disagree the
  repository's wins and the budget keeps it whole first.
