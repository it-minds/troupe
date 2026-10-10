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
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - apps/troupe_core/test/troupe/troupe_dir_test.exs
  - apps/troupe_core/test/troupe/skills/local_test.exs
  - apps/troupe_gateway/test/troupe/gateway/agents_trust_test.exs
  - apps/troupe_gateway/test/troupe/gateway/local_sources_test.exs
  - PROTOCOL.md
  - docs/user/configuration.md
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
D99's unreadable `SKILL.md`. Instruction files, Cursor rules and the brief are judged
where they really are (Decisions 798, 809) and so are `.agents/skills` (822), but a
workspace's own `.troupe/` directories were not: `Troupe.Agent.Definitions`,
`Troupe.Commands.Local`, `Troupe.Workflow` and `Troupe.Skills.Local` read whatever a file
or the directory linked to, so a cloned repository whose `.troupe/agents/x.md` pointed at
a file elsewhere on the machine put that file into a prompt that goes to a provider. And a
workspace's `.troupe/skills.json` could name any directory (`"include": ["~"]`), which
`Skills.Local.roots/2` made a read root of the session, so `read_file`, which runs without
asking, could read anything under it: a repository widened what the agent reads to the
whole machine, with no question. Both reproduced on the chunk's tip; an unreadable
`.troupe/skills/*/SKILL.md` crashed the listing (`File.read!` in
`Troupe.Protocol.Bundle.list_skills_in/1`) and one in `.agents/skills` was dropped silently.

- **The edge is the workspace, the directory that holds `.troupe`.** The four directories,
  and each file in them, are read only where they really are inside it, links and
  junctions followed (`Troupe.Workspace.within?/2`, `files_within/3`); in a git worktree
  the main checkout's committed agents and skills are held to the checkout. This is the
  brief's edge (798's `Memory.inside?/1`), the nearest thing `.troupe/` already had. Not
  the repository root, which instruction files use: `.troupe/` belongs to the directory it
  is in, as #512 says. A link that stays inside (an agent file linked to another in the
  workspace) is read as before.
- **Trusted or not.** A `.troupe/agents` or `.troupe/skills` linked out of a trusted
  workspace is not read either. Reaching outside is what `skills.json`'s `include` is
  for, and that waits for trust (below); one door to watch, not two.
- **Not read, and said.** A file linked out is listed with its name and `not read: outside
  the workspace` (`outside the main checkout` for the checkout's); a directory linked out
  whole is one entry with no name and is not looked into, so not even the names of what is
  there are said (822's rule). Where: `agents.list` gains `skipped` (additive), `skills.list`
  lists the skill as `outside`, and the session's `files_skipped` event, which already
  carried agents and skills (826), now carries commands and workflows too (`kind`
  `command`, `workflow`), since neither has a listing of its own. A workflow linked out is
  not offered by `workflows.list` and `Workflow.load/2` gives the default for it as for a
  missing one, with a warning in the daemon's log; holding the file to the workspace also
  stops a `workflow` name with `..` in it from reading a file outside it.
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
  so the include waits for the same word. Never would break the use 700 wrote the
  workspace's `skills.json` for: `skills.add` with `link` and the workspace scope writes
  exactly such an include (`~/.claude/skills` into a repository a person works in), and
  with trust that keeps working after one `troupe config trust`. The cost: a person who
  linked a directory into an untrusted workspace loses those skills until they trust it,
  and `skills.list` says so. Not chosen: a question per include, as a workspace's MCP
  server gets (700); a skill's files are read at every turn by every agent, a question
  there would be asked of whoever is attached at the wrong moment, and the trust list is
  already the answer for "what may this workspace make readable".
- **The stamp.** The session decides once, as it starts, as it does for a workspace's
  agents (825): trusted when local and on `trusted_workspaces`, never on a pod. It is
  stamped on the session's `Troupe.Workspace` (`trusted?`, false unless someone vouches,
  so a workspace made anywhere else is not), because the skills are read again at every
  turn by the system prompt and the tool list of every agent, and every agent and tool
  carries the workspace. `Skills.available/4`, `tools/4`, `prompt_section/4`,
  `skipped/3`, `roots/2` and `Skills.Local.resolve/2` take `trusted: true`; anything else
  is untrusted. `skills.list` judges by the user's file, as `agents.list` does. Trust is
  read when the session starts, so a workspace trusted mid-session reads the include in
  the next one.
- **An unreadable `SKILL.md`** is listed as `unreadable`, with the error, in every layer:
  one reader (`Skills.Local`'s, which A26 wrote for `.agents/skills`) now reads every
  layer, so the person's own `<config>/skills` and links list a folder no skill may be
  called as `skipped` too, where they were dropped silently, and an unreadable manifest
  there no longer crashes the listing.
- **Proof:** `Troupe.TroupeDirTest` (an agent, command, workflow and skill file linked out,
  and each directory linked out whole, not read and listed; a link inside read; a
  `SKILL.md` linked out; an unreadable `SKILL.md` in `.troupe/skills` and `.agents/skills`
  listed; an untrusted `"include": ["~"]` no read root, `read_file` of a path under the
  home refused, the include listed with the command; trusted, a read root and past the
  edge; on a pod, none; an include inside the repository read untrusted; `files_skipped`
  carrying all four kinds and the include; a worktree's checkout with committed links out,
  not read, and its `.troupe/skills` linked out no read root), `Troupe.Skills.LocalTest`
  (a workspace link of `~/.claude/skills` read only with trust),
  `Troupe.Gateway.AgentsTrustTest` (`agents.list`'s `skipped`) and
  `Troupe.Gateway.LocalSourcesTest` (`skills.list` before and after the user's file trusts
  the workspace). Thirteen of the fourteen in `TroupeDirTest` failed on the chunk's tip,
  the trusted include only for want of the new option; the include inside the repository
  passed there too.
- **Not here.** `skills.add`'s answer does not say that a link it just wrote waits for
  trust; `commands.list` and `workflows.list` carry no `skipped`; neither client shows the
  new entries (D99's client items are another slot's).
