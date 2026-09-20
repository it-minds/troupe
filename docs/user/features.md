> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> ## Deprecated — kept as an artifact
>
> This page documents the `troupe` terminal client. That client left this repository on
> 2026-09-14: `apps/troupe_tui` and `apps/troupe_ctl` were deleted, the packaged binary
> and its installers with them, and nothing here builds an executable any more. The
> source citations under each section point at files that now exist only in git history
> (`git show 20fe871 -- apps/troupe_ctl` and the tree at that commit).
>
> What this repository is, is the remote: the plane, the operator, the worker pods and
> the admin console, deployed to Kubernetes by `charts/troupe` and reached over
> [PROTOCOL.md](../../PROTOCOL.md). A terminal or graphical client is a separate release
> from a separate repository, and its own documentation goes with it.
>
> Nothing in this directory is maintained against the code. It is here because the prose
> is worth keeping until the client repository can take it, and for no other reason.

# Features

Every user-facing feature, with what it does, how to reach it (command-line flag,
terminal key, slash command, or protocol method for script writers), and its limits
and defaults. Protocol method names are given where a script would need them; the
full wire format is in [PROTOCOL.md](../../PROTOCOL.md). Where the README or PROTOCOL
disagree with the code, a `Discrepancy:` line says so and the code wins.

Contents: [Sessions](#sessions) · [Remote sessions and profiles](#remote-sessions-and-profiles) ·
[Agents](#agents) · [Plan and build](#plan-and-build) · [Approvals](#approvals) ·
[Task lists](#task-lists) · [Tools](#tools-available-to-the-agent) · [Watch mode](#watch-mode) ·
[Worktrees](#worktrees) · [Budgets and limits](#budgets-and-limits) · [Compaction](#compaction) ·
[Files](#files) · [Large outputs](#large-outputs) · [Presence and several people](#presence-and-several-people-on-one-session) ·
[Skills](#skills-from-a-profile-bundle) · [MCP servers from a profile](#mcp-servers-from-a-profile) ·
[Personal MCP connectors](#personal-mcp-connectors) · [Triggers, A2A and the review flag](#sessions-started-by-triggers-or-by-other-agents) ·
[Cost](#cost-per-session) · [Dormancy](#dormancy-and-what-wakes-a-session) · [Interrupted sessions](#interrupted-sessions-after-a-restart) ·
[Verify](#verify) · [HQ](#hq) · [Headless and run](#headless-and-run-mode) · [MCP admin bridge](#the-mcp-admin-bridge) ·
[troupe admin](#troupe-admin-for-team-admins) · [Scripts](#scripts-and-other-clients)

---

## Sessions

A session is one agent tree in one directory with a durable, hash-chained log. It
exists in the daemon (local) or on a pod (remote), not in the window you watch it
from.

| Action | Local | Remote | Protocol |
|---|---|---|---|
| Create | `troupe` (UI) or `troupe run "TASK"` | `troupe --remote` / `troupe --remote run "TASK"` | daemon: `session.create`; plane: `session.create` |
| List | `troupe sessions` (this workspace) | `troupe --remote sessions` (everything you may see on the plane) | `session.list`; plane: `sessions.list` |
| Resume | `troupe resume [ID]` (newest in this workspace when unnamed) | `troupe --remote resume ID` | daemon: `session.get` + `subscribe`; plane: `session.open` |
| Archive | happens after `troupe run` finishes; `/quit` does **not** archive | — (a pod session goes dormant on its own) | `session.archive` |
| Pin / unpin | no command | no command; GUI has no screen either | `session.pin`, `session.unpin` (daemon and plane) |
| Erase | no command | `troupe admin session erase ID` (team admin) | `session.erase` (daemon and plane) |

Session ids look like `20260913T101502-Ab3dEf`.

**Archive** stops the actor tree and leaves the log; the session is then `dormant`
and any steering command brings it back. `troupe run` archives its session when the
task ends so a scripted run leaves nothing running. Quitting the UI leaves the session
running until the idle timeout (30 minutes locally, about 10 minutes on a pod).

**Pin** marks a session exempt from retention. On the plane the pin is a column on the
session's row and survives restarts; erase and pin there require the session's owner.
Locally the pin is held in the daemon's memory only and is lost when the daemon
restarts, and no local retention code reads it, so today it has no effect on the local
daemon.

**Erase** is irreversible. Locally it stops the session and deletes its log directory.
On the plane it writes a tombstone, makes the session read-only, and tells the pod to
destroy the session's key and delete its objects; the head hash of the log is kept in
the tombstone. A team admin may erase any session in their team; the owner may erase
their own.

Listing shows metadata only: id, state, status, profile, title or last activity,
tokens and cost. On the plane each row also carries `your_role` (`owner`,
`collaborator`, `viewer`), `pending_approvals`, `origin`, `reviewed_by` and
`pinned`.

Discrepancy: PROTOCOL says pins are "exempt from retention"; the local daemon persists
neither the pin nor any retention policy. The plane persists the pin.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:188-242, 249-264, 383-401, 423-439
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:135-145, 396-435
- apps/troupe_core/lib/troupe.ex:173-186, 308-331
- apps/troupe_core/lib/troupe/sessions/index.ex:27-33, 91-92, 325
- apps/troupe_plane/lib/troupe/plane/harness.ex:124-143, 247-272, 957-984
- apps/troupe_plane/lib/troupe/plane/admin.ex:366-378
- apps/troupe_worker/lib/troupe/worker/session/manager.ex:51
- PROTOCOL.md:369-373, 468-486
- docs/AUDIT.md §3 finding 5

## Remote sessions and profiles

A remote session is created through the plane and lives on a worker pod of one
profile. Your terminal (or the GUI) connects to the pod directly over a WebSocket;
the plane is not in the path of a keystroke.

**How the CLI gets there.** `troupe --remote` uses the refresh token `troupe login`
stored to get a plane token, asks the plane to create or open a session, receives the
pod's address and a token minted for that pod, and dials it. `--plane URL` picks a
plane when you are logged in to several.

**Profiles.** `me` (what `troupe login` prints) lists your teams and the profiles
granted to them. `profiles.list` on the plane also says, per profile, how many pods are
healthy, how much capacity is free, which primary agents the current bundle offers,
and which skills and MCP servers a session there will have. The GUI's start dialog
shows this; the CLI does not.

**Choosing.** With one profile nothing needs naming. With several, `--agent NAME`
names the profile for `troupe --remote` (note the flag reuse). With several teams that
may all use the same profile, the plane answers `choose a team` and lists them; the
CLI has no `--team` flag, so use the GUI or pass `team` in a script's
`session.create`.

**What `session.create` accepts on the plane** (script writers): `profile`
(required), `team`, `agent` (a primary agent name the profile's bundle offers, or a
built-in), `prompt` (the first input, at most 64 KiB, never stored by the plane),
`title`, `visibility` (`private` by default, or `team`), `terms` (`budget_micros`,
`max_turns` 1–500, `wall_clock_seconds` 60–86400, `approvals` `wait` or `deny`),
`origin` (at most 4 KiB), `session_id`, `source`. The answer is `{session_id, epoch,
mode, endpoint, worker_id, pod, role, token, expires_at}`; connect to `endpoint` with
`token` in `initialize`.

**Your role on a session** decides what you may do on the pod. Owner: everything.
Collaborator: steer (send input, cancel, switch agent, answer approvals, edit tasks,
upload files, offer connectors) but not pin, erase or archive. Viewer: read only. You
are owner of sessions you created; a collaborator or viewer when somebody granted you
(`session.grant`); and, for a session with `team` visibility, a collaborator or viewer
according to the team's `members_may_control` setting.

**Tokens expire.** A pod token lasts at most 15 minutes. Two minutes before it
expires the pod sends `auth.expiring`; a client asks the plane for a new one
(`token.mint`) and presents it on the same connection (`auth.refresh`). The CLI and
GUI do this for you. A token for one pod is refused by every other pod
(`wrong_audience`). Access is re-checked on every command against the access list the
plane pushed, so a revoked collaborator is refused on their next command with `access
revoked` even while their token still verifies.

**Capabilities a pod reports** at `initialize`: `{"worktrees": false, "watch": true,
"remote": true}`.

Discrepancy: a pod reports `worktrees: false` but still serves `worktree.list` and
`worktree.remove`; they act on the pod's own filesystem and are not useful there.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:1-19, 38-51, 74-86, 96-137, 149-192, 216-225
- apps/troupe_ctl/lib/troupe/cli.ex:183-186, 266-331, 585
- apps/troupe_plane/lib/troupe/plane/harness.ex:49-64, 81-120, 147-166, 177-196, 225-243, 278-368, 413-415, 432-456, 712-741, 823-830, 957-989
- apps/troupe_plane/lib/troupe/plane/sessions.ex:537-556
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:160-168, 411-415, 475-478
- apps/troupe_protocol/lib/troupe/protocol/token.ex:98, 124-135
- apps/troupe_worker/lib/troupe/worker/auth.ex:206-219
- PROTOCOL.md:522-582

## Agents

A session runs a tree of agents. The root is a **primary** agent; it may delegate to
**subagents**, which report back with a summary and end.

Built-in agents:

| Name | Mode | Tools | Budget share | What it is for |
|---|---|---|---|---|
| `build` | primary | all | 1.0 | Full coding agent: reads, edits, runs commands, delegates, keeps a task list. The default. |
| `plan` | primary | `read_file`, `list_files`, `grep`, `todo_read`, `todo_write`, `delegate`, `finish`; `write_file`, `edit_file`, `shell` denied | 1.0 | Investigates and writes the plan into the task list; changes nothing. |
| `general` | subagent | all | 0.5 | One self-contained piece of delegated work that may edit. |
| `explore` | subagent | `read_file`, `list_files`, `grep`, `finish`; writes and shell denied | 0.4 | Read-only search; cheap; reports paths and line numbers. |

**Custom agents** are markdown files with YAML front matter: `name`, `description`,
`mode` (`primary` or `subagent`), `model`, `tools` (`all` or a list), `permissions`
(tool → `auto`, `ask` or `deny`), `max_turns`, `budget_share`, `skills`; the body is
the system prompt. Names match `^[a-z0-9][a-z0-9-]{0,63}$`. Where they live, lowest
precedence first: built-ins, the profile's bundle (`agents/` in the bundle), your
global config directory's `agents/`, the project's `.troupe/agents/`. On a pod only the
built-ins and the bundle apply. A subagent's `budget_share` is the fraction of the
parent's *remaining* budget it gets.

**Addressing a subagent from the terminal UI.** Type `@explore where is auth handled`
and press Enter. This sends the root agent an instruction to delegate that task in one
`delegate` call and report back; it is not a second way of spawning agents. The tree
panel on the right lists live agents; **Up/Down** moves the selection and the
transcript pane switches to the selected agent. `/agents` prints the live agent paths.

**Starting agent.** Locally `--agent NAME` (`-a`) picks the primary agent a session
starts with (default `build`, or `default_agent` in config). On the plane the
`agent` field of `session.create` does the same and is refused with the list of
offered names if the bundle does not define it. Delegation depth is capped by
`max_depth` (default 3).

Discrepancy: README says **Enter** on an agent row opens its transcript. There is no
such key handler; the transcript follows the selection made with Up/Down, and Enter
submits the input line (or allows a pending approval).

Sources:
- apps/troupe_core/priv/agents/build.md, plan.md, general.md, explore.md
- apps/troupe_core/lib/troupe/agent/definition.ex:11-12, 38, 79
- apps/troupe_core/lib/troupe/config.ex:31, 58
- apps/troupe_core/lib/troupe/budget.ex:72-89
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:106-108, 114-120, 279-291, 444-449, 467-480
- apps/troupe_plane/lib/troupe/plane/harness.ex:278-289
- README.md:97-98
- docs/AUDIT.md §1.7 (agent definition fields), §2 (Enter on agent row)

## Plan and build

`plan` and `build` are the two primary agents you switch between: plan reads and
writes the task list, build executes it. Switching changes which agent definition the
root uses from its next turn; the conversation and task list carry over.

| How | Where |
|---|---|
| **Tab** | terminal UI; toggles between `plan` and `build` |
| `/plan`, `/build` | terminal UI |
| Profile select in the session header | GUI |
| `profile.switch` `{session_id, profile}` | protocol (applied at the next turn boundary) |

A `profile_switched` event lands in the log and the UI shows `profile → build`. Any
primary agent name works, not only the two built-ins.

Sources:
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:91-95, 310-328
- apps/troupe_tui/lib/troupe/ui/tui/state.ex:216-218
- apps/troupe_core/lib/troupe.ex:111
- PROTOCOL.md:386-387
- ../../../troupe-gui/docs/AUDIT.md §1.2

## Approvals

Tools whose permission is `ask` stop and wait for a person before they run. By
default that is `write_file`, `edit_file`, `shell`, `publish`, `import`, every
personal-connector tool, and MCP tools unless the bundle marks a server `auto`.

**What you see.** The terminal UI shows a popup titled `approve shell?` (or the tool
name) with the agent path, the command for `shell`, and a diff for `write_file` and
`edit_file`. Headless mode prints `? approval needed for shell (call_3) — run with
--auto-approve in CI` and keeps waiting. The GUI shows a panel in the session and an
inbox across sessions. HQ lists approvals from every local session.

**Answers.**

| Decision | Terminal UI | HQ | GUI | Protocol `approval.respond` `decision` |
|---|---|---|---|---|
| allow this call | `y` or Enter | `y` or Enter | Allow / `A` | `allow` |
| allow this tool for the rest of the session | `a` | `a` | "Allow every … for this session" | `allow_session` |
| deny | `n` | `n` | Deny / `D` | `deny` |

A denial comes back to the model as a readable tool result, so it can try another
approach. `allow_session` is remembered per tool name for the session and survives
dormancy, because decisions are durable events.

**First answer wins.** Several people can watch one session. The first
`approval.respond` decides; anybody who answers afterwards gets an
`approval_resolved` event naming who got there first, and their answer has no effect.

**Unattended sessions.** `--auto-approve` does two things on a local session: the
session is created with `auto_approve` on, so the session itself answers allow, and
in headless mode the client also answers any request it sees, with the log naming
that client as the approver. With `--remote` only the client-side half exists and
only in headless mode: the plane's `terms` have no auto-approve key, and `troupe
--remote --auto-approve` with the terminal UI has no effect. In config, `approvals:
deny` makes the session itself answer no at once with the system as actor, which is
what a session with nobody attached should do; on the plane a trigger or script sets
the same through `terms: {approvals: "deny"}`. There is deliberately no `approvals:
auto`.

An approval left unanswered waits indefinitely (the tool's own timeout is the only
clock). A session waiting on one reports status `waiting`; on the plane that is
visible in the session list as `pending_approvals`.

Sources:
- apps/troupe_core/lib/troupe/session/approvals.ex:14-23, 53-68, 141-185, 199-245
- apps/troupe_core/lib/troupe/tools.ex:152-178
- apps/troupe_core/lib/troupe/config.ex:46-52
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:97-104, 482-492
- apps/troupe_tui/lib/troupe/ui/tui/view.ex:338-420
- apps/troupe_tui/lib/troupe/ui/hq/server.ex:116-119, 162-181
- apps/troupe_ctl/lib/troupe/ui/headless.ex:15-26, 137-154
- apps/troupe_ctl/lib/troupe/cli.ex:278-282, 299-308, 403-410, 460-467
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:158-170
- apps/troupe_tui/lib/troupe/ui/tui.ex:20-28
- apps/troupe_plane/lib/troupe/plane/harness.ex:308-327
- PROTOCOL.md:389-396

## Task lists

Each agent keeps a task list; the root agent's is the one you see. The `build` agent
is told to write the whole plan before a task of more than two steps, keep exactly one
item `in_progress`, and complete items as it goes; `plan` writes the list for `build`
to execute.

Statuses: `pending` `[ ]`, `in_progress` `[~]`, `completed` `[x]`, `cancelled` `[-]`.
At most one item may be `in_progress`; ids must be unique; an item without an id gets a
stable one derived from its text.

**You can edit the list.** The protocol command is `todo.edit` `{session_id, action,
id | content}` with `action` `add` (needs `content`), `cancel` or `complete`. The edit is
applied to the agent's list and a sentence such as "The user cancelled task t2." is
placed into the conversation so the model does not overwrite your change on its next
`todo_write`. The GUI's Tasks panel and scripts use it; the terminal UI shows the list
in its side panel but has no key for editing it. Every `todo_updated` event carries the
whole list, and headless mode prints it.

Sources:
- apps/troupe_core/lib/troupe/todo.ex:1-119, 121-171
- apps/troupe_core/lib/troupe/tools/todo.ex:15-18, 58, 76-88
- apps/troupe_core/priv/agents/build.md, plan.md
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:329-342, 598-613
- apps/troupe_tui/lib/troupe/ui/tui/view.ex:221-260
- apps/troupe_ctl/lib/troupe/ui/headless.ex:156-158, 208-215
- PROTOCOL.md:398-402

## Tools available to the agent

The harness enforces the tool allowlist and permissions, not the model: a call to a
tool the agent's definition does not allow never runs and comes back as an error
result.

| Tool | What it does | Default permission | Limits |
|---|---|---|---|
| `read_file` | Read a file, with `offset`/`limit` | auto | 2000 lines by default; output capped at `tool_output_limit` (60 000 bytes) |
| `write_file` | Write a whole file | ask | approval shows a diff against the existing file |
| `edit_file` | Replace one exact, unique string | ask | fails if the string is missing or ambiguous |
| `list_files` | Glob, honouring `.gitignore` | auto | 1000 entries |
| `grep` | Search (ripgrep when available, else built in) | auto | 200 matches, 60 s |
| `shell` | Run a command under the session's process reaper | ask | `timeout_ms` default `shell_timeout_ms` (120 s); output capped; the command and everything it started are killed at timeout |
| `publish` | Copy from the session workspace to a shared mount (team or org volume) | ask | needs a shared mount; a pod today has none (see below) |
| `import` | Copy from a shared mount into the session workspace | ask | same |
| `todo_write`, `todo_read` | The task list | auto | one `in_progress` item |
| `delegate` | Start a subagent with a slice of the budget | auto | depth capped by `max_depth` (3) |
| `finish` | A subagent's final summary to its parent | auto | — |
| `skill` | Read a skill from the profile's bundle | auto | only present when the bundle has skills the agent lists |
| `mcp.<server>.<tool>` | A tool on an MCP server the profile's bundle configures | ask, unless the bundle says `auto` for that server | server allowlist decided at discovery |
| `client.<server>.<tool>` | A tool on a personal MCP connector you offered | ask | only for the session it was offered to; gone when your client disconnects |

Paths are confined to the session's workspace (and mounts) by real-path checks;
climbing out is refused. On Linux, when a sandbox is available and the session has
mounts beyond its own workspace, `shell` runs in a restricted namespace.

Team and organisation volumes are mounted on pods but are not yet handed to sessions,
so on a pod `publish` and `import` have nowhere to go today. See
[AUDIT.md](../AUDIT.md) §3 finding 2.

Sources:
- apps/troupe_core/lib/troupe/tools.ex:16-32, 46-61, 72-78, 114-131, 152-169
- apps/troupe_core/lib/troupe/tools/read_file.ex:9, 12, 36, 80
- apps/troupe_core/lib/troupe/tools/write_file.ex:9, 33
- apps/troupe_core/lib/troupe/tools/edit_file.ex:16, 44
- apps/troupe_core/lib/troupe/tools/list_files.ex:8, 11, 35, 61-65
- apps/troupe_core/lib/troupe/tools/grep.ex:16, 19, 45, 80
- apps/troupe_core/lib/troupe/tools/shell.ex:23, 42, 64, 70, 134
- apps/troupe_core/lib/troupe/tools/publish.ex:22, 51
- apps/troupe_core/lib/troupe/tools/import.ex:17, 40
- apps/troupe_core/lib/troupe/tools/todo.ex:15, 58, 76, 88
- apps/troupe_core/lib/troupe/tools/delegate.ex:21, 24, 72, 117, 145
- apps/troupe_core/lib/troupe/skills.ex:120-140
- apps/troupe_core/lib/troupe/mcp.ex:60
- apps/troupe_protocol/lib/troupe/mcp/server.ex:25-28, 62-73
- apps/troupe_core/lib/troupe/session/client_tools.ex:36
- apps/troupe_core/lib/troupe/config.ex:32-33
- docs/AUDIT.md §1.7, §3 finding 2 (sandbox and mounts summarised from the core audit)

## Watch mode

With watch mode on, the session watches the workspace for comments addressed to the
agent and acts on them when you save.

| Comment | Meaning |
|---|---|
| `# make this return 42 AI!` | Do this now (a change). |
| `# why does this return nil AI?` | Answer this without editing anything; handled by the plan agent's rules. |
| `# the caller expects a list AI` | Context: collected and sent along with the next `AI!` or `AI?`. |

The word `AI` may begin or end the comment, in any case. Comment syntaxes recognised:
`<!--`, `/*`, `//`, `--`, `#`, `;`, `%`. A marker inside a string literal is ignored,
conservatively: an odd number of quotes before the comment opener disqualifies the
line. Six lines of context around the marker travel with it. The `build` agent removes
the comment as part of its edit so it does not fire twice.

**Turning it on.**

| How | Where |
|---|---|
| `troupe --watch` / `-w` | at start, local |
| `/watch` | terminal UI; toggles, and prints which backend is in use |
| `watch: true` | config file |
| `watch.set` `{workspace, enabled}` | protocol (admin scope) |

**Backends.** A native file-system watcher is used when one is available (inotify
tools on Linux, the macOS listener); otherwise a polling scan every second
(`watch_poll_interval_ms`). The UI tells you which: `watch: native` or `watch: poll`.
If the native backend dies, the session falls back to polling and says so. Bursts are
debounced (`watch_debounce_ms`, 300 ms).

**Exclusive per workspace.** Only one session may watch a given workspace; turning it
on where another session already watches returns `conflict` with `watch is exclusive
per workspace`. Watch mode works on a pod too (`watch: true` in capabilities); the
`watch.set` command there needs the pod-side workspace path, which the terminal UI
supplies from the session.

Sources:
- apps/troupe_core/lib/troupe/watch/marker.ex:1-17, 32-35, 123-148
- apps/troupe_core/lib/troupe/session/watcher.ex:49-66, 98-114, 146-150, 161-177
- apps/troupe_core/lib/troupe.ex:334-360
- apps/troupe_core/lib/troupe/config.ex:34-36
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:447-453
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:335-349
- apps/troupe_ctl/lib/troupe/cli.ex:585, 692
- apps/troupe_core/priv/agents/build.md
- PROTOCOL.md:464-466

## Worktrees

Two local sessions in one git repository would edit the same checkout. So a second
session in a workspace that already has a live one gets its own git worktree on a
fresh branch `troupe/<slug>` at `<workspace>-<slug>` next to the repository, and the
CLI says so before the UI opens:

```
working in a new worktree on troupe/k3m9x2ab: /home/me/project-k3m9x2ab
```

| `--worktree MODE` | Behaviour |
|---|---|
| `auto` (default) | branch only when the workspace already has an active session, and only if it is a git repository |
| `never` | always use the directory itself |
| `always` | always create a worktree |

Protocol: `session.create` takes `worktree`; `worktree.list` returns `{path, branch,
session_id, dirty}` for a workspace; `worktree.remove` `{path, force}` removes one and
**refuses a dirty tree** (uncommitted changes or untracked files) with `conflict`
unless `force` is true. `worktree.merge` `{workspace, path, message}` commits what the
agent left in the worktree, merges its branch into the checkout with a merge commit and
removes the worktree and branch — or answers `conflict` and leaves everything as it was
when git cannot merge it. `worktree.discard` `{workspace, path}` removes the worktree
and its branch, work and all. Both refuse while the session in the worktree is
mid-turn. There is no CLI command for any of this; a client (the TUI's `/merge` and
`/discard`) or a script speaks the protocol.

**Workflows.** `session.create` with `workflow: <name>` runs the prompt as a named,
multi-step workflow: the step list at `.troupe/workflows/<name>.json` (or the built-in
`default` pipeline: understand, plan, implement, test, document, verify) is rendered
around the prompt as the plan the `workflow` agent starts from. That agent is an
orchestrator — it cannot write, edit or run commands — and delegates each step to the
subagent that owns it: `explore` reads, `implementer` changes, `reviewer` verifies.
`workflows.list {workspace}` names the workflows a workspace has. Run one in a worktree
of its own (`worktree: "always"`), and merge or discard it afterwards.

**Project brief.** `.troupe/memory.md` in the repository's main checkout is what
earlier agents learned: `## Overview`, `## Layout`, `## Commands`, `## Conventions`, and
`## Notes` (dated one-liners). Every agent's system prompt opens with it, after the
profile's own words. Agents write it with the `remember` tool — `section: "note"`
appends a line, the other sections are rewritten whole — and the `librarian` agent
(primary, cheap model, read-only plus `remember`) surveys a repository once and writes
the four curated sections. `memory.get {workspace}` reports `status` (`absent`, `stale`,
`fresh`, `disabled`), the path, when it was built, its section titles and its text;
`memory.forget` deletes it. Config: `memory: false` turns it off, `memory_max_chars`
(6000) caps the prompt block, `memory_max_age_days` (7) is when it counts as stale,
`memory_auto_refresh` (true) asks a client to start the librarian on a missing or stale
brief. Hand edits survive: unknown headings and text before the first heading round-trip.

**Branches.** A client may create a session as a branch of another: `session.create`
with `parent` (the first session's id). The daemon records the link, lists it
(`session.list` with `filter.parent`), and gives the parent's agent a `read_branch`
tool that lists the branches and reads a finished one's prompt, summary and task list.
A branch is otherwise an ordinary session — in its own worktree when the workspace is
busy, which is what makes two agents on one repository safe.

Worktrees are a local-daemon feature; pods report `worktrees: false`.

Sources:
- apps/troupe_gateway/lib/troupe/gateway/worktrees.ex:1-12, 25-57, 80-108
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:239-243, 396-418, 437-445
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:411-415
- apps/troupe_ctl/lib/troupe/cli.ex:387-388, 417-419, 587, 609-630
- PROTOCOL.md:349-352, 454-459

## Budgets and limits

**Per agent.** Every agent has four limits, checked immediately before each model
request so an exhausted agent makes zero further calls:

| Limit | Default | Config key |
|---|---|---|
| Turns (model requests) | 40 | `max_turns` |
| Input tokens | 2 000 000 | `max_input_tokens` |
| Output tokens | 400 000 | `max_output_tokens` |
| Wall clock | 30 minutes | `wall_clock_ms` |

A subagent gets a slice of the parent's *remaining* budget, scaled by its
`budget_share`, with at least one turn and one second. When a limit is hit the agent
ends with `agent_done` reason `budget_exhausted` plus a `budget_exhausted {limit}`
event; the UI shows `budget exhausted (max_turns)`, headless mode exits 1, and a plane
run of a trigger is still counted `done` (a trigger with `max_turns: 3` is meant to end
that way). Sending another input starts a new turn only if the budget allows; the
counters are not reset by input.

**Per session on the plane** (`terms` in `session.create`): `max_turns` 1–500,
`wall_clock_seconds` 60–86400, `approvals`, `budget_micros`. These override the pod's
own configuration for that session and are fixed at creation.

**Team budget.** Each team has `budget_micros` (0 or unset means unlimited) and a
period. Creating or waking a remote session reserves a slice against it: the
session's `budget_micros` term, or 5 000 000 micros (five dollars at one micro per
millionth) by default, trimmed to what the team has left. Nothing left is
`budget_exhausted` at `session.create` or at wake-up, and the session stays dormant.
Spend is recorded from the model gateway's per-request cost and the reservation is
released at dormancy.

**Other limits you will meet.** The model request times out after 300 s; a tool call
after `shell_timeout_ms` + 60 s (at least 180 s); a prompt in `session.create` is at
most 64 KiB; a JSON-RPC message to a daemon at most 64 MiB; a WebSocket frame to a pod
at most 16 MiB.

Sources:
- apps/troupe_core/lib/troupe/budget.ex:11-18, 41-55, 72-89
- apps/troupe_core/lib/troupe/config.ex:27-30
- apps/troupe_core/lib/troupe/agent/server.ex:742, 921, 1103, 1470-1471
- apps/troupe_ctl/lib/troupe/ui/headless.ex:176-178, 244-263
- apps/troupe_plane/lib/troupe/plane/harness.ex:29-45, 315-346, 476-491, 624-638
- apps/troupe_plane/lib/troupe/plane/triggers.ex:396-425
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:33
- docs/AUDIT.md §1.7, §2 (budget period), core audit (request timeout 300 s, tool timeout, frame 16 MiB)

## Compaction

When the last request's input tokens reach `context_window × compact_at` (200 000 ×
0.75 by default) the agent summarises everything but the last six messages with the
`small_model` if one is set (else the main model), replaces the old messages with the
summary, and carries on. A `compacted` event is logged and the UI prints `compacted
earlier turns`. A failed compaction is logged as a warning and the turn continues
uncompacted. Nothing to do on your side; tune `context_window`, `compact_at` and
`small_model` in config if you need to.

Sources:
- apps/troupe_core/lib/troupe/config.ex:21, 25-26, 94-98
- apps/troupe_core/lib/troupe/agent/server.ex:910-911, 1106-1107, 1297-1400
- apps/troupe_tui/lib/troupe/ui/tui/state.ex:229-230
- apps/troupe_ctl/lib/troupe/ui/headless.ex:160-162

## Files

A client can browse and read the session's workspace through the same mount table
the agent's tools use, so you see exactly what the agent may see.

| Action | Protocol | GUI | CLI/TUI |
|---|---|---|---|
| List a directory | `fs.list` `{session_id, path}` → entries with `kind` `file`/`directory`/`other` and `size` | Files panel (tree) | — |
| Read a file | `fs.read` `{session_id, path}` → `{content, size, hash}`; refuses directories and files over the server's cap | Files panel (viewer) | — |
| Upload a file | `fs.upload` `{session_id, path, content}` (control scope); recorded as `fs_changed` with you as actor | not yet | — |

On a pod, every change in the workspace (by the agent, `shell`, or an upload) is a
durable `fs_changed` event carrying the file's hash, which is how the GUI knows to
refresh its tree. Locally that is off by default (`fs_events: false`) because you can
see your own files.

Sources:
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:157-210
- apps/troupe_core/lib/troupe/config.ex:37-41
- PROTOCOL.md:415-445
- ../../../troupe-gui/docs/AUDIT.md §1.2, §1.3

## Large outputs

A tool result larger than 16 KiB is not put in the event; the log carries `{"blob":
"sha256:…", "preview": …}` with the first 4 KiB as preview, and the bytes are stored
under the session, content-addressed. A client fetches them with `blob.get`
`{session_id, blob, range}`; `range` is an inclusive byte range and the server may
answer a shorter range than asked (the GUI reads in 256 KiB chunks). The terminal UI
shows the preview; the GUI shows "large result" and fetches on demand. Locally blobs
are erased when the session is erased. On a pod they live on the pod's disk for the
life of the activation and are not uploaded to object storage today, so a dormant
remote session's large outputs may be gone after it wakes elsewhere (see
[AUDIT.md](../AUDIT.md) §4 question 12).

Discrepancy: the blobs module says "any event field over 16 KiB"; only tool-result
content is spilled.

Sources:
- apps/troupe_core/lib/troupe/session/blobs.ex:5, 16-17, 71-75
- apps/troupe_core/lib/troupe/agent/server.ex:1124
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:212-227
- PROTOCOL.md:406-413
- docs/AUDIT.md §2 (blobs), §4 question 12

## Presence and several people on one session

Any number of clients may attach to one session; each sees the same events in the
same order.

**Queued input.** If somebody sends input while the agent is busy, the session logs
`input_queued` at once and `input_accepted` when the agent takes it; everybody sees
both, so two people cannot both believe their message went first. There is one order,
the session's.

**Approvals** are first-answer-wins (see [Approvals](#approvals)); the second person
sees `approval_resolved` naming the first.

**Presence** is ephemeral (never logged): the pod announces `joined` and `left` for
every connection, and a client may say what it is doing with `presence.set`
`{session_id, state, agent}` (for example `viewing`, `focused`, `typing`). The GUI shows
who is on the session in its Backstage panel and sets its own presence; the terminal
UI neither sets nor shows presence.

**Rights** come from your role (owner, collaborator, viewer); see
[Remote sessions](#remote-sessions-and-profiles). Locally everyone on the socket is
the same user with every scope.

Sources:
- apps/troupe_core/lib/troupe/agent/server.ex:74, 661
- apps/troupe_gateway/lib/troupe/gateway/presence.ex:1-27
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:217, 616-622
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:59-61, 344-347
- apps/troupe_core/lib/troupe/session/approvals.ex:14-16, 232-245
- PROTOCOL.md:377-382, 644-654
- ../../../troupe-gui/docs/AUDIT.md §1.2

## Skills from a profile bundle

An administrator may publish skills in the profile's bundle: directories in the Agent
Skills convention with a `SKILL.md` and supporting files. In a session on that
profile, an agent whose definition lists the skills (or `skills: all`) sees a "Skills
available" section in its prompt and a `skill` tool that reads one by name; the
skill's other files are readable under the read-only `skills:/<name>/` mount with the
ordinary file tools. `profiles.list` tells you which skills a profile currently
offers, and the GUI's start dialog shows them. There is nothing to configure on your
side; a session is pinned to the bundle version current when it was created, and an
upgrade at the next activation is recorded as a `config_upgraded` event so the model
is told.

Sources:
- apps/troupe_core/lib/troupe/skills.ex:5-11, 53-60, 112-140, 149, 178-179
- apps/troupe_core/lib/troupe/tools.ex:80-92
- apps/troupe_plane/lib/troupe/plane/harness.ex:98-120, 507-509, 861-914
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:172-197

## MCP servers from a profile

A profile's bundle may list MCP servers (with the secret referenced, not written). The
pod discovers each server's tools at start and offers them to agents as
`mcp.<server>.<tool>`, filtered by the allowlist the bundle gives, at the permission
the bundle sets (`ask` unless `auto`). The session's id travels to the server as
metadata for its logs, never as an authorisation. `profiles.list` names the servers a
profile offers; `troupe admin mcp check URL` tells an admin whether cluster policy lets
a pod reach one. Nothing to configure on your side.

Sources:
- apps/troupe_core/lib/troupe/mcp.ex:50-60
- apps/troupe_protocol/lib/troupe/mcp/server.ex:25-28, 62-73
- apps/troupe_plane/lib/troupe/plane/harness.ex:870-882
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:48
- docs/AUDIT.md §1.7 (MCP discovery, `_meta`)

## Personal MCP connectors

You can offer an MCP server that runs on *your* machine (your notes, your calendar,
something on localhost) to one session, for as long as your client is attached.

**Configure.** A JSON file at `$TROUPE_MCP_CONFIG`, else
`$XDG_CONFIG_HOME/troupe/mcp.json`, else `$HOME/.config/troupe/mcp.json`:

```json
{"servers": [{"name": "notes", "url": "http://127.0.0.1:7331/mcp", "credential_ref": "NOTES_TOKEN"}]}
```

`credential_ref` names an environment variable; the value stays in the shell that
started `troupe`. On Windows `HOME` is normally unset, so set `TROUPE_MCP_CONFIG`
explicitly.

**Offer, in the terminal UI.**

1. `/connect` lists your configured servers and whether each is offered.
2. `/connect notes` asks the server for its tools and registers them
   (`tools.register`). The session answers with a consent challenge and the UI prints
   the words: `Let this session run 2 tools on your machine: notes.search,
   notes.get?` followed by what will run on your machine with your credentials.
3. `/connect yes` sends the confirmation with the challenge; `/connect no` drops it. The
   challenge is bound to your connection, your subject and exactly those tools, and
   expires after five minutes.

**What everybody sees.** The session logs `tools_registered` and `session_tainted`
(`taint: personal_connector`); the taint shows in every participant's summary, because
a tool running on somebody's laptop is something the others should know about. The
tools appear to the agent as `client.notes.search` and are `ask` by default, so each
call is an approval prompt. Calls arrive at your client as `tool.invoke`, are served
against your server with your credential, and are answered on your connection only;
another client on the same session cannot invoke them. When your client disconnects
the tools are unregistered.

Protocol: `tools.register` `{tools: [{name, description, schema}], consent:
{challenge, confirmed_by}}` → `{registered, taint}`; without consent → error
`consent_required` (−32013) with `data.challenge`, `data.prompt`, `data.tools`.
`tools.unregister`. The GUI does not host tools today and answers `tool.invoke` with
`method_not_found`.

Sources:
- apps/troupe_tui/lib/troupe/ui/tui/connectors.ex:1-25, 32-74, 91-106, 116-157
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:359-442
- apps/troupe_core/lib/troupe/session/client_tools.ex:9-20, 36-40, 69-89, 132-147, 202-248
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:62-64, 357-394
- apps/troupe_protocol/lib/troupe/protocol/error.ex:33-34
- PROTOCOL.md:584-642
- ../../../troupe-gui/docs/AUDIT.md §1.3

## Sessions started by triggers or by other agents

Not every session is started by a person.

**Triggers.** A team admin defines a trigger: a cron schedule (UTC) or a webhook an
external executor terminates, a service principal to run as, a profile, a prompt
template, terms, `visibility` (default `team`), `review` (`required` by default, or
`none`), `notify` (subjects granted collaborator on each run), and `concurrency`
(1–100, default 1). Each firing makes one run and one session, created as the
principal; a firing over the concurrency cap records a `skipped` run and no session.
The session's `origin` is `{kind: "trigger", trigger, run}` and its log's first event
says so.

**A2A.** Another agent can send a task to `/a2a/<profile>` as a team's service
principal (or as a person with a provider token). The facade creates a session with
`origin: {kind: "a2a", caller, task}`; the A2A task id is the session id. Approvals
surface as `input-required` and are answered with a data part. Full mapping in
[a2a.md](../a2a.md).

**The review flag.** A session whose trigger says `review: required` carries
`needs_review` until somebody who can see it calls `session.review`
`{session_id}`; the plane records `reviewed_by` and `reviewed_at` on the session and
its run and audits it. `sessions.list` takes a `needs_review: true` filter and `origin`
and `trigger` filters so you can find them; the GUI has no review screen yet, and the
CLI has no command, so today reviewing is a protocol call. People named in `notify`
are collaborators on the run's session and can open it.

**Runs.** `troupe admin runs TEAM [TRIGGER]` lists runs newest first with a `state`
derived from the session: `created`, `running`, `waiting` (an approval is pending),
`done`, `failed`, `skipped`. `troupe admin trigger run TEAM NAME` fires one by hand;
`trigger.fire` `{trigger, idempotency_key, event}` on the plane's `/rpc` is what an
external executor or the principal calls.

Sources:
- apps/troupe_plane/lib/troupe/plane/triggers/trigger.ex:5-12, 24-41, 48-66, 72-79, 84-105
- apps/troupe_plane/lib/troupe/plane/triggers.ex:199-270, 277, 331, 339-341, 373, 396-425, 445-464, 501-507
- apps/troupe_plane/lib/troupe/plane/harness.ex:124-137, 198-223, 348-368, 810-815
- apps/troupe_plane/lib/troupe/plane/admin.ex:804-870
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:66-73, 369-372
- docs/a2a.md
- apps/troupe_a2a/lib/troupe/a2a/auth.ex:6-19

## Cost per session

Every model response carries the tokens used and, when the request went through a
gateway that reports it, the cost in micros (millionths of a currency unit). The
session folds these into a running total: the terminal UI's tree panel shows
`12/40 turns · 18342 tok` per agent, the GUI shows a cost figure per session and a
total across the list, and `session.list` (local) returns `tokens` and `cost` while
`sessions.list` (plane) returns `cost_micros`. On the plane the pod reports usage to
the ledger in batches, so a session that ran while the plane was unreachable is still
charged when it reconnects. The ledger is per team; `troupe admin overview` shows
spend per team to admins.

Sources:
- apps/troupe_core/lib/troupe/session/usage.ex:53, 78-100, 121-128
- apps/troupe_tui/lib/troupe/ui/tui/state.ex:303-310
- apps/troupe_plane/lib/troupe/plane/harness.ex:685-689, 977
- PROTOCOL.md:360-365
- ../../../troupe-gui/docs/AUDIT.md §1.2
- docs/AUDIT.md §1.7 (usage sink, ledger)

## Dormancy and what wakes a session

A session that has been idle goes **dormant**: its actor tree stops, its log stays.
Locally the daemon sweeps every 15 s and stops trees idle for 30 minutes. On a pod a
session goes dormant after about 10 minutes idle: its log is sealed and its workspace
archived and encrypted to object storage, the pod erases its local copy, and the plane
releases the pod slot and the budget reservation. `session.archive` locally, and
`troupe run` finishing, do the same on demand.

**Reading never wakes a session.** `session.list`, `session.get`, `subscribe`
(replaying the log), `blob.get`, `fs.list`, `fs.read` and the plane's `session.open`
with `mode: "read"` all work on a dormant session and start nothing. On a pod a read
opens a *reader* on any pod of the profile.

**Activating commands** bring the tree back before they take effect, and the log
records `session_activated`: `input.send`, `turn.cancel`, `profile.switch`,
`approval.respond`, `todo.edit`. On the plane, `session.open` with `mode: "activate"`
(what `troupe --remote resume` and the GUI's session view use) places the session on
a pod again, reserving capacity and budget; exactly one caller wins the activation and
the rest are handed the same pod.

A `read_only` session (its team's access to the profile was revoked, or it is being
erased) can be read but any activation is `forbidden` with `this session is
read-only`.

Note: the team setting `idle_timeout_seconds` is shown in `teams.list`, but the pod's
dormancy timer in this build is the fixed 10-minute default; no code path was found
that applies the team value to a pod.

Sources:
- apps/troupe_core/lib/troupe/sessions/index.ex:91-92, 159-199
- apps/troupe_core/lib/troupe.ex:205-240
- apps/troupe_worker/lib/troupe/worker/session/manager.ex:3-29, 51-57
- apps/troupe_plane/lib/troupe/plane/harness.ex:225-235, 561-666, 931-938
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:420-424
- PROTOCOL.md:468-486
- ../../../troupe-gui/docs/AUDIT.md §2 (GUI opens with `activate` from the list, `read` from the inbox)

## Interrupted sessions after a restart

If the daemon or the pod restarts while a session is mid-turn, the session comes back
**dormant** with status `interrupted`. That status is read from the log — a tool call
that started and never completed, or a model request never answered — so it is true
before anything has restarted. **No model call is made** and no shell command is
re-run until you send an activating command; a crash loop that resumed would spend
money and run commands nobody is watching. When you do resume, the unfinished tool
calls are closed off as errors reading `interrupted: the session stopped before this
finished`, so the model sees a result for every call it made, and an approval that was
waiting is asked again. Setting `resume_on_restart: true` in a local config file opts
back into automatic continuation (unfinished tool calls are re-run at least once and
the owed turn is taken). On the plane, a run whose session is `interrupted` is shown
as `failed`.

Sources:
- apps/troupe_core/lib/troupe/agent/server.ex:280-320, 365-370
- apps/troupe_core/lib/troupe/config.ex:53-57
- apps/troupe_core/lib/troupe/sessions/index.ex:333-340
- apps/troupe_plane/lib/troupe/plane/triggers.ex:410-412
- PROTOCOL.md:487-504

## Verify

Every durable event carries the hash of the event before it, so a log can be checked
by whoever holds it without trusting whoever handed it over.

```bash
troupe verify 20260913T101502-Ab3dEf
```

replays the session from the local daemon over the protocol and walks the chain.

```bash
troupe verify --log path/to/events.jsonl
```

checks a log file, or a decrypted segment, offline with no daemon and no plane.

Output and exit codes:

| Result | Message | Exit |
|---|---|---|
| chain intact | `N events verify; the head is sha256:…` | 0 |
| empty log | `the log is empty` | 0 |
| break | `the chain breaks at seq N: its prev_hash does not match the event before it` or `…: the sequence skips` | 1 |
| file unreadable | `<path> could not be read: …` | 2 |
| daemon refused | `the daemon refused: …` | 1 |

`troupe verify ID` is local only; it is not one of the commands `--remote` applies to.
For a remote session, obtain the events with a script (`subscribe` from `seq` 0 as a
reader) and check them the same way, or ask an admin for the decrypted segment. The
`head_hash` on the plane's session row and in an erase tombstone is what to compare
against.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/verify.ex:1-15, 24-41, 54-75
- apps/troupe_ctl/lib/troupe/cli.ex:119-132, 183-186, 469-473, 675-676
- apps/troupe_plane/lib/troupe/plane/harness.ex:255-256, 968

## HQ

```bash
troupe hq
```

One screen for every session in the local daemon and one inbox of every approval
waiting in any of them, including sessions nobody has open in a terminal. It is built
from `session.list`, a `fleet` subscription and a replay of each session's history, so
an approval raised before HQ opened is still listed.

| Key | Action |
|---|---|
| Up / Down | select an approval |
| `y` or Enter | allow |
| `a` | allow that tool for the session |
| `n` | deny |
| `q` or Ctrl-C | quit |

Answering is the ordinary `approval.respond`; if somebody else answered first the row
disappears with the `approval_resolved` event.

HQ connects to the **local daemon only**. `--remote` does not apply to it.

Discrepancy: README says `troupe hq` shows remote sessions beside local ones. The
command has no remote path; use the GUI's "Waiting for you" inbox for remote
approvals.

Sources:
- apps/troupe_tui/lib/troupe/ui/hq/server.ex:1-14, 28-94, 102-119, 162-181
- apps/troupe_tui/lib/troupe/ui/hq/view.ex:66
- apps/troupe_ctl/lib/troupe/cli.ex:170-186
- README.md:303-305
- docs/AUDIT.md §2

## Headless and run mode

```bash
troupe run "make the tests pass"
```

creates a session, sends the task, follows it until the root agent finishes, archives
the session, and exits. Without `--headless` it opens the terminal UI when one is
available; with `--headless` it prints the event stream as plain lines, which is what
CI and scripts want. `--headless` also works with `troupe`, `troupe resume` and
`troupe --remote ...`; on a remote session the task is sent as the session's first
prompt.

| Flag | Effect |
|---|---|
| `--headless` | plain lines instead of a UI |
| `--quiet` | do not stream the model's text; print only structure (tool calls, approvals, task list) |
| `--auto-approve` | this client answers every approval with `allow` |
| `--timeout SECONDS` | give up after this long (default 1800) |

What it prints: `> task` for inputs, `→ tool args` when a tool starts, `✓ tool` or
`✗ tool: reason` when it ends, `⇢ delegate to explore: …`, `? approval needed for
shell (call_3) — run with --auto-approve in CI`, `☰ task list:` with the items, `…
compacted earlier turns`, `! model request failed: …`, `! budget exhausted (limit)`.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | the root agent finished normally |
| 1 | it ended with an error, the budget ran out, or the daemon went away |
| 124 | the timeout passed (the same code `timeout(1)` uses) |
| 2 | bad command line |

The run is complete when the root agent reports `done`, or goes idle again after
having been busy; the durable `agent_done` event is the fallback for a client that
fell behind. An approval nobody answers keeps the run waiting until the timeout.

Sources:
- apps/troupe_ctl/lib/troupe/ui/headless.ex:1-11, 28-55, 57-69, 71-99, 108-180, 244-265
- apps/troupe_ctl/lib/troupe/cli.ex:74-79, 208-220, 284-297, 441-467, 623, 696-699
- apps/troupe_tui/lib/troupe/ui/tui.ex:55-64

## The MCP admin bridge

For team and platform admins who want to drive administration from a model. The plane
serves its admin methods as MCP tools at `/mcp`; `troupe mcp` bridges that endpoint
over stdio, minting and renewing the plane token from the credentials `troupe login`
stored (renewed every ten minutes), so no credential is pasted into a configuration
file.

```bash
claude mcp add troupe -- troupe mcp
```

Add `--plane URL` after `mcp` when logged in to several planes. Tool names are the
method names with dots replaced by underscores (`admin_trigger_put`). Destructive tools
take a `confirm` argument that must repeat the identifier (`admin_session_erase` wants
`session_id` and `confirm` equal). The tool list is not filtered by role; a team admin
sees every tool and is refused, with the required role named, when calling one they
may not. Everything the bridge says to a person goes to stderr; stdout carries only
protocol.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/mcp.ex:1-45, 54-65, 102-126, 148-169
- apps/troupe_ctl/lib/troupe/cli.ex:91-95, 654, 682
- PROTOCOL.md:707-755

## `troupe admin` for team admins

Every `troupe admin` command is one call to the plane's public `/rpc` with your login;
a person with `curl` and a token can do the same. `troupe admin` with no arguments
prints the list. Output is the JSON result, pretty-printed. `--plane URL` (before or
after `admin`) selects a plane.

Two roles exist. **Platform admin** comes from an identity-provider group. **Team
admin** is assigned per team by a platform admin. A team admin may run the commands
below for their own team; naming another team answers `not_found` (a team you may not
see is a team you should not learn exists), and a platform-only method answers
`forbidden` with `required_role: platform_admin`.

Commands a team admin may run:

| Command | What it does |
|---|---|
| `troupe admin overview` | fleet health, active sessions, spend, scoped to your teams |
| `troupe admin profiles` | the profiles granted to your teams, with pods and load |
| `troupe admin teams` | your teams, with grants, budgets and retention |
| `troupe admin team update NAME FILE` | change budget, retention, `members_may_control`, `pins_allowed`, volume size or class; FILE is a JSON object of the fields to change |
| `troupe admin sessions` | session metadata for your teams, never content |
| `troupe admin session erase ID` | erase a session in your team, irreversibly |
| `troupe admin bundles CHANNEL`, `troupe admin bundle show CHANNEL VERSION` | read published bundles |
| `troupe admin mcp check URL` | whether cluster policy lets a pod reach an MCP host |
| `troupe admin audit` | who changed what, newest first (today this is not filtered to your team; see below) |
| `troupe admin provisioning` | whether the plane applies profiles directly or through GitOps |
| `troupe admin settings` | every platform setting and where its value came from |
| `troupe admin identity check [GROUP]` | test the identity configuration |
| `troupe admin principal list TEAM` | your team's service principals (never a secret) |
| `troupe admin principal create TEAM NAME PROFILES` | create one; PROFILES is comma-separated and must be within the team's grants; the secret is printed once |
| `troupe admin principal rotate SUBJECT` | new secret, printed once; the old one stops at once |
| `troupe admin principal disable SUBJECT` | disable; its sessions are kept |
| `troupe admin trigger list TEAM` | your team's triggers |
| `troupe admin trigger put FILE` | create or update from a JSON file: `team`, `name`, `principal` (subject), `profile`, `agent`, `source` (`{kind: "schedule", cron}` or `{kind: "webhook", …}`), `prompt_template`, `terms`, `visibility`, `review`, `notify`, `concurrency`, `enabled`; partial on update |
| `troupe admin trigger delete TEAM NAME` | remove; its runs go with it, the sessions they made do not |
| `troupe admin trigger run TEAM NAME` | fire it now |
| `troupe admin runs TEAM [TRIGGER]` | runs newest first with their state |

Platform-only: `profile show|put|check|delete`, `pod drain`, `team enable`, `team
grant|revoke`, `team admin add|remove`, `bundle validate|publish|retire`, `setting
set|reset`. They are documented in [../admin/README.md](../admin/README.md).

FILE arguments are paths to a JSON object. For `bundle publish` (platform) FILE may be
a directory laid out as `agents/*.md`, `skills/<name>/SKILL.md` and `mcp.yaml`.

Exit codes: 0 success, 1 the plane refused or could not be reached, 2 usage error or
unreadable file.

Note: `troupe admin audit` returns every team's changes to a team admin; the filter is
by actor, kind, subject and time, not by team (see [AUDIT.md](../AUDIT.md) §3 finding
6). `troupe admin sessions` is scoped to your teams.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:1-14, 19-74, 84-95, 110-170, 172-197, 284-294, 349-375, 391-397
- apps/troupe_plane/lib/troupe/plane/admin.ex:57-99, 308-321, 355-378, 741-800, 804-870, 893-897, 930-962, 1020-1035
- apps/troupe_plane/lib/troupe/plane/admin/api.ex:99-145, 307-321, 390-419, 581-707
- apps/troupe_plane/lib/troupe/plane/triggers.ex:501-507
- PROTOCOL.md:656-705, 772-777
- docs/AUDIT.md §3 findings 6 and 7

## Scripts and other clients

Everything above is reachable from a script, because the CLI, TUI, GUI and A2A facade
have no private path. Locally, connect to the daemon's Unix socket (or loopback TCP
with the token from `daemon.json`), send `initialize` with `protocol_version: "1"`,
then commands; newline-delimited JSON-RPC 2.0. Remotely, get an endpoint and token from
the plane's `/rpc` (`session.create` or `session.open`) and open the WebSocket. A
reference Python client for the local daemon is at `clients/python/troupe.py`
(`connect_unix`, `connect_tcp`, `call`, `subscribe`, `send_input`,
`respond_to_approval`, `events`). Every command carries a `command_id`; replaying one
is a no-op that returns the original acknowledgement, so retries after a disconnect
are safe. Scopes: `observe` (read, subscribe, presence), `control` (steer), `admin`
(create, archive, pin, erase, worktree removal, watch); a local socket has all three,
a pod token carries the ones your role grants.

Discrepancy: PROTOCOL mentions `troupe ctl token --scope observe` for minting a
read-only local token. No `ctl` or `token` command exists.

Sources:
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:41-74
- clients/python/troupe.py:44-226
- apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:112-130
- PROTOCOL.md:14-47, 329-339, 507-520, 864-875
- apps/troupe_ctl/lib/troupe/cli.ex:633-661
- docs/AUDIT.md §2
