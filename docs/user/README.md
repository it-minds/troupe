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

# Troupe for users

This track is for people who **use** Troupe: a developer who signs in to the team's
plane with `troupe login`, runs sessions on the team's worker pods with `troupe
--remote` or the GUI, or runs the local daemon and terminal UI on their own machine;
and a team admin who uses `troupe admin` for their team. It is not for the platform
operator (that is [../admin/README.md](../admin/README.md)) and it does not explain the
source (that is [../developer/README.md](../developer/README.md) and
[../whitepaper.md](../whitepaper.md)).

| File | Read it when |
|---|---|
| [overview.md](overview.md) | you want the ten words that matter (session, profile, approval, budget…) and what Troupe never does |
| [getting-started.md](getting-started.md) | installing, signing in, first remote session, first local session |
| [features.md](features.md) | you want everything you can do, with the flag, key, slash command or protocol method, and the limits |
| [workflows.md](workflows.md) | you want steps and expected output for a task |
| [cli-reference.md](cli-reference.md) | you want every command, flag, exit code, key and file path |
| [troubleshooting.md](troubleshooting.md) | something on the screen does not make sense |

The GUI lives in a separate repository; its user guide is
[../../../troupe-gui/docs/user/README.md](../../../troupe-gui/docs/user/README.md).
What it can do today is summarised in [features.md](features.md) where relevant.

Every claim in this track was checked against the code at the commit above. Where the
README or PROTOCOL disagree with the code, the documents say `Discrepancy:` and the
code wins. Citations (file:line) sit at the end of each section, never in the prose.

## Self-check

Every top-level feature and every user-reachable route, and where it is documented.
"GUI" rows summarise the separate repository's confirmed capabilities.

### Features

| Feature | Documented in |
|---|---|
| Sessions: create, list, resume, archive, pin/unpin, erase | features.md § Sessions; cli-reference.md |
| Remote sessions, profiles, roles, token renewal | features.md § Remote sessions and profiles; getting-started.md §3 |
| Agents: build, plan, general, explore; custom agent files; `@agent` | features.md § Agents |
| Plan/build switching | features.md § Plan and build; workflows.md 2 |
| Approvals: y/a/n, allow/deny/allow_session, first answer wins, `--auto-approve`, `approvals: deny` | features.md § Approvals; workflows.md 2, 3, 5 |
| Task lists and editing them | features.md § Task lists |
| Tools and default permissions (incl. `skill`, `mcp.*`, `client.*`) | features.md § Tools available to the agent |
| Watch mode (`AI!`, `AI?`, `AI`; exclusive; polling fallback) | features.md § Watch mode; workflows.md 4 |
| Worktrees (auto/never/always; dirty refusal) | features.md § Worktrees; troubleshooting.md |
| Budgets and limits (agent, session terms, team budget) | features.md § Budgets and limits |
| Compaction | features.md § Compaction |
| Files (list, read, upload) | features.md § Files |
| Large outputs / blobs | features.md § Large outputs |
| Presence and several people on one session | features.md § Presence…; workflows.md 3 |
| Skills from a bundle | features.md § Skills from a profile bundle |
| MCP servers from a profile | features.md § MCP servers from a profile |
| Personal MCP connectors (`/connect`, mcp.json, consent, taint) | features.md § Personal MCP connectors |
| Sessions from triggers and A2A; review flag | features.md § Sessions started by triggers…; workflows.md 6, 7 |
| Cost per session | features.md § Cost per session |
| Dormancy and activation | features.md § Dormancy… |
| Interrupted sessions, `resume_on_restart` | features.md § Interrupted sessions…; workflows.md 10 |
| Verify (hash chain) | features.md § Verify; workflows.md 9 |
| HQ | features.md § HQ |
| Headless / run mode, exit codes | features.md § Headless and run mode; workflows.md 5 |
| MCP admin bridge | features.md § The MCP admin bridge; workflows.md 8 |
| `troupe admin` for team admins | features.md § troupe admin for team admins; cli-reference.md |
| Install, unsigned binaries | getting-started.md §1; troubleshooting.md |
| Login / logout, credential storage | getting-started.md §2; cli-reference.md § Files and paths |
| Local configuration (`config.yaml`, `{env:VAR}`, fake provider) | getting-started.md §4 |

### CLI commands

| Command | Documented in |
|---|---|
| `troupe` | cli-reference.md § Commands: local |
| `troupe run` | cli-reference.md § Commands: local; features.md § Headless |
| `troupe resume` | cli-reference.md § Commands: local |
| `troupe sessions` | cli-reference.md § Commands: local |
| `troupe hq` | cli-reference.md; features.md § HQ |
| `troupe verify` | cli-reference.md; features.md § Verify |
| `troupe daemon` | cli-reference.md § Commands: local |
| `troupe --remote` (tui, run, resume, sessions) | cli-reference.md § Commands: remote |
| `troupe login`, `troupe logout` | cli-reference.md § Commands: identity; getting-started.md §2 |
| `troupe admin …` (all 37 subcommands) | cli-reference.md § Commands: admin |
| `troupe mcp` | cli-reference.md; features.md § The MCP admin bridge |
| `--version`, `--help` and every option | cli-reference.md § Options |

### Terminal UI keys and slash commands

| Route | Documented in |
|---|---|
| Enter, y/a/n, Tab, Esc, Up/Down, PageUp/PageDown, End, F5, Backspace, Ctrl-C twice, paste | cli-reference.md § Terminal UI keys |
| `/plan` `/build` `/cancel` `/watch` `/agents` `/sessions` `/connect [NAME\|yes\|no]` `/resume` `/help` `/quit`, `@agent` | cli-reference.md § Terminal UI slash commands |
| HQ: Up/Down, y/Enter, a, n, q/Ctrl-C | cli-reference.md § HQ keys |

### Protocol commands a user's client may issue (daemon or pod)

| Command | Scope | Documented in |
|---|---|---|
| `initialize`, `auth.refresh` | — | features.md § Remote sessions; § Scripts |
| `subscribe`, `unsubscribe` | observe | features.md § Scripts; § Verify |
| `session.list`, `session.get` | observe | features.md § Sessions |
| `fs.list`, `fs.read` | observe | features.md § Files |
| `blob.get` | observe | features.md § Large outputs |
| `fleet.get` | observe | features.md § HQ |
| `workspace.recent`, `workspace.search` | observe | **not covered** (used by no shipped client; see PROTOCOL.md §6) |
| `worktree.list` | observe | features.md § Worktrees |
| `workflows.list` | observe | features.md § Workflows |
| `memory.get` | observe | features.md § Project brief |
| `mcp.status` | observe | features.md § Local MCP servers |
| `memory.forget` | admin | features.md § Project brief |
| `presence.set` | observe | features.md § Presence |
| `input.send`, `turn.cancel`, `profile.switch` | control | features.md § Sessions, § Plan and build |
| `approval.respond` | control | features.md § Approvals |
| `question.answer` | control | features.md § Approvals |
| `todo.edit` | control | features.md § Task lists |
| `fs.upload` | control | features.md § Files |
| `tools.register`, `tools.unregister`; server request `tool.invoke` | control | features.md § Personal MCP connectors |
| `session.create`, `session.archive` | admin | features.md § Sessions, § Worktrees |
| `session.pin`, `session.unpin`, `session.erase` | admin | features.md § Sessions |
| `worktree.remove`, `worktree.merge`, `worktree.discard` | admin | features.md § Worktrees |
| `watch.set` | admin | features.md § Watch mode |
| Notifications `event`, `resync_required`, `auth.expiring`, `auth.expired` | — | features.md § Remote sessions; troubleshooting.md |

### Plane harness methods (`/rpc`)

| Method | Documented in |
|---|---|
| `me`, `teams.list`, `profiles.list` | features.md § Remote sessions and profiles |
| `sessions.list`, `session.get` | features.md § Sessions; § Sessions started by triggers (filters) |
| `session.create` | features.md § Remote sessions (accepted fields) |
| `session.open` (read / activate), `token.mint` | features.md § Dormancy; § Remote sessions |
| `session.pin`, `session.unpin`, `session.erase` | features.md § Sessions |
| `session.grant` | features.md § Remote sessions; workflows.md 3 |
| `session.review` | features.md § Sessions started by triggers |
| `trigger.fire` | features.md § Sessions started by triggers; workflows.md 6 |
| `admin.*` (team-admin subset) | features.md § troupe admin; cli-reference.md § Commands: admin |
| `admin.*` (platform-only) | ../admin/README.md (out of this track) |

### GUI (separate repository; confirmed list)

| Capability | Documented in |
|---|---|
| Sign in (PKCE redirect or device code), stay signed in, sign out | getting-started.md §2 (pointer); troubleshooting.md § The GUI |
| Session list with search, state and profile filters; start a session (profile, agent, title, prompt) | features.md § Remote sessions; § Sessions |
| Read transcript live; send prompts; stop a turn; switch profile | features.md § Sessions; § Plan and build |
| Answer approvals in-session and from an inbox | features.md § Approvals |
| Expand tool output; fetch large results | features.md § Large outputs |
| Browse and read files | features.md § Files |
| Tasks, sub-agent states, presence, cost, bundle version; theme | features.md § Task lists, § Presence, § Cost |
| Not in the GUI: local sessions, pin/grant/review/erase/todo edit, upload, admin screens | noted in the relevant features.md sections |

### A2A

| Route | Documented in |
|---|---|
| Agent card, `message/send`, `message/stream`, `tasks/get`, `tasks/cancel`, `tasks/resubscribe`, artifacts, auth | features.md § Sessions started by triggers…; workflows.md 7; full detail in ../a2a.md |

### Not covered in this track

* `workspace.recent` and `workspace.search` (protocol only; no shipped client uses them).
* Platform-only administration (profiles, pods, team enable/grant, bundles publish,
  settings): [../admin/README.md](../admin/README.md).
* The console at `/admin` (browser): [../admin/README.md](../admin/README.md).
* SCIM, break-glass, provisioning modes: [../admin/README.md](../admin/README.md).
