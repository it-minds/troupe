---
number: 829
title: A workspace's `.troupe/agents`, `commands`, `workflows` and `skills` are read only where they really are inside it, and what its `skills.json` includes from outside the repository is read, and is a read root, only once the workspace is trusted
date: 2026-10-10
status: accepted
issue: 519
paths:
  - apps/troupe_core/lib/troupe/workspace.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/commands/local.ex
  - apps/troupe_core/lib/troupe/workflow.ex
  - apps/troupe_core/lib/troupe/skills/local.ex
  - apps/troupe_core/lib/troupe/skills.ex
symbols:
  - Troupe.Workspace.within?/2
  - Troupe.Workspace.files_within/3
  - Troupe.Skills.Local.resolve/2
  - Troupe.Skills.Local.roots/2
  - Troupe.Skills.Local.held/3
  - Troupe.Skills.roots/2
  - Troupe.Skills.skipped/3
  - Troupe.Commands.Local.skipped/1
  - Troupe.Workflow.skipped/1
gist: ".troupe/{agents,commands,workflows,skills} held to the workspace by real path, links out listed, not read; a skills.json include outside the repo waits for trust"
---

Issues #519 and #512's reading half (a workspace's `.troupe/` held to the workspace), and
D99's unreadable `SKILL.md`.

- **The edge is the workspace, the directory that holds `.troupe`.** The four directories,
  and each file in them, are read only where they really are inside it, links and
  junctions followed (`Troupe.Workspace.within?/2`, `files_within/3`); in a git worktree
  the main checkout's committed agents and skills are held to the checkout. Not the
  repository root, which instruction files use: `.troupe/` belongs to the directory it is
  in, as #512 says. A link that stays inside (an agent file linked to another in the
  workspace) is read as before.
- **Trusted or not.** A `.troupe/agents` or `.troupe/skills` linked out of a trusted
  workspace is not read either. Reaching outside is what `skills.json`'s `include` is for,
  and that waits for trust (below); one door to watch, not two.
- **Not read, and said.** A file linked out is listed with its name and `not read: outside
  the workspace` (`outside the main checkout` for the checkout's); a directory linked out
  whole is one entry with no name and is not looked into, so not even the names of what is
  there are said (822's rule).
- **A `skills.json` include outside the repository waits for trust.** Inside the
  repository (`Troupe.Instructions.repository_root/1`) an include is read as the
  repository's own files are, held to the repository. Outside, its skills are offered and
  it is a read root only once the workspace is trusted (`trusted_workspaces`, Decision
  686); until then it is listed as `outside`, saying so and naming `troupe config trust`,
  is not looked into, and adds no read root, so `read_file` of a file under it answers
  `outside_workspace`, and reaching it takes a tool that asks (`shell`). The person's own
  `<config>/skills.json` and `<config>/skills` have no edge: the person wrote them.
- **Why trust, rather than never.** An include outside the repository is a read root by
  another name, and 686 already makes `read_roots` in a workspace's `config.yaml` a
  trusted key: trusting a workspace is how a person says its files may widen what is read,
  so the include waits for the same word. Not chosen: a question per include, as a
  workspace's MCP server gets (700); a skill's files are read at every turn by every
  agent, a question there would be asked of whoever is attached at the wrong moment, and
  the trust list is already the answer for "what may this workspace make readable".
- **The stamp.** The session decides once, as it starts, as it does for a workspace's
  agents (825): trusted when local and on `trusted_workspaces`, never on a pod.
- **An unreadable `SKILL.md`** is listed as `unreadable`, with the error, in every layer:
  one reader (`Skills.Local`'s, which A26 wrote for `.agents/skills`) now reads every
  layer, so the person's own `<config>/skills` and links list a folder no skill may be
  called as `skipped` too, where they were dropped silently, and an unreadable manifest
  there no longer crashes the listing.
