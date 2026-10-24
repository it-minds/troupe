# Closed defects

Defects that left [the known defects](../developer/defects.md): taken by an issue or a
pull request, judged not worth fixing, or checked and found not to be one. A record kept
as it was written, so a `D` number cited elsewhere still says where it went; nothing
here is open.

## Taken

| Defect | Taken by |
| --- | --- |
| On Windows, dormant sessions vanish after a daemon restart (`Path.wildcard` on backslashes) | #87, PR #89 |
| D1 - A session id is used as a glob pattern | #97, PR #105 |
| D2 - Glob on a runtime path in TUI completion and bundle skills | #98, PR #104 |
| D3 - The TUI sends parameter names the daemon does not accept | #99, PR #102 |
| D7 - A team's budget period offers "daily" and refuses it | #100, PR #103 |
| A team's `monthly` budget never resets (found by the #100 fixer) | #106, PR #129 |
| D13 - A cancelled turn may leave a tool call awaiting approval | #137, PR #138 |
| A person's cap is described as monthly but never resets (found by the #106 fixer) | #132 |
| The plane has no `session.archive`; A2A `tasks/cancel` fails (found by the #111 fixer) | #135 |
| A cancelled approval stays waiting in three more readers (found by the D13 and #142 fixers) | #142, PR #143; #145, PR #150 |
| A failed subagent never reports; delegation reuses a child path after restart (found by the #127 and D13 fixers) | #149, PR #151 |
| D11 - `/todo cancel <id>` needs an id the TUI never shows | PR #163 |
| D12 - The TUI reads four protocol error codes wrongly | PR #163 |
| D16 - An `{env:VAR}` key in opencode's config is sent as it is written | #161, PR #169 |
| D17 - A question that times out or is cancelled stays open in the GUI | #162, PR #168 |
| D20 - Small leftovers of the first-run and headless work (what remains is in D23) | PR #175 |
| A pod's slot isn't given back when the pod reports a session asleep (found by the #135 fixer) | #173, PR #174 |
| A session waiting on a question never reaches the desktop inbox (found by the D17 fixer) | #172, PR #176 |
| A finished subagent stays in memory until its session stops (found by the #134 fixer) | #171, PR #198 |
| D10 - The protocol's documents and the gateway disagree | PR #196 |
| D14 - Small leftovers of the budget and loop work | PR #197 |
| D15 - On Windows the desktop app installs into the daemon's state directory | #185, PR #193 |
| D18 - A session restored while a subagent waits on an approval may keep it open | #171, PR #198 |
| D19 - Restart leftovers in delegation | #171, PR #198 |
| D21 - A remote session that moves to another pod isn't followed | #184, PR #199 |
| D22 - Revoking access or erasing a running session may keep its budget reservation | #190, PR #192 |
| The TUI shows every typed line twice | #181, PR #194 |
| A brief with only notes stays stale, so every session starts the librarian (found by the D8 fixer) | PR #201 |
| `install-local.ps1` fails while a TUI is running, and `verify-local.ps1` accepts any daemon (found in chunk 5) | PR #200 |
| A session's own token is refused `commands.list` on a worker (found by the #123 fixer) | PR #217 |
| Two gateway tests left a session running, so later tests saw it (found by the #119 fixer and the coordinator) | PR #220, PR #218 |
| D24 - The librarian can run in every session of a repository | PR #237 |
| D25 - An ACP agent whose subprocess exits may run its task again (confirmed) | PR #237 |
| D27 - The TUI never draws `read_file`'s numbered body | PR #234 |
| D28 - Writing a setting drops the config file's comments | #223, PR #235 |
| D29 - A pod's command palette lists the built-in agents, not the bundle's | PR #237 |
| D31 - The dev stack doesn't come back after a WSL restart | #225, PR #233 |
| D33 - A renamed desktop build shares the real app's stored sign-in | #224, PR #232 |
| Headless runs waited forever on a spent budget: the printer answered its question as an approval (found by the D32 fixer) | PR #234 |
| The TUI's needs-input, done and failed window states were dead since the daemon move (found by the #228 fixer) | PR #241 |
| `troupe` on Windows died at boot in a large directory and broke the console (every session start walked the workspace for `.gitignore`) | #231, PR #240 |
| D34 - On a pod, a deleted file is never reported to clients | #252, PR #254 |
| D38 - `UpgradePending` says every pod is current while one runs the old image (confirmed) | #251, PR #253 |
| D35 - Clicking a desktop notification on Windows doesn't open its session | PR #263 |
| D6 - Plane mode opens a just-created local session as a team session (confirmed) | PR #265 |
| D9 - The admin docs describe a `subject_claim` setting the plane does not have (confirmed: no code in this repository has it; the plane keys on `sub`) | PR #265 |
| Without Cilium, the worker's policy admitted an external object store or OpenBao only on 443 or 80 at a public address (found by the #251 fixer) | #257, PR #260 |
| A failed activation left the restored event log on the pod; a fork and `session.read` answered `internal_error` when storage was unreachable (found by the #252 fixer) | #259, PR #261 |
| A roll never finished by itself: pods on an old revision waited to be deleted by hand (found by the #251 fixer) | #258, PR #264 |
| `session.read` left the log it restored on the pod; a fork read a failed listing as "no archives" (found by the #259 fixer) | #269, PR #271 |
| `Troupe.Reaper.open/3` raised when the helper couldn't start, which crashed the agent on every model call (found by the chunk 9 fixer of slot D) | #270, PR #272 |
| The plane's scale-down removed pods without draining them (found by the #258 fixer) | #273, PR #274 |
| With Entra and SCIM, the plane keys a person on `sub` only (found by the chunk 9 fixer of slot F) | #267, PR #339; #340, PR #345; #341, PR #343 |
| Without Cilium, a profile's own endpoints on other ports or at private addresses are unreachable (found by the #257 fixer) | #268 |
| The plane's `gitops` mode worked only in tests: no `git` in its image, no repository setting, no push credential (found while planning #186) | #186, PR #285 |
| A trigger's timezone typed in the console was ignored; the MCP schema of `admin.trigger.put` didn't match its handler; a profile's bundle channel never reached its row; an ssh profile got a StatefulSet (found by the #186 fixers) | #290, PR #291 |
| Team and host admin methods accepted fields they don't document; the profile editor couldn't save a storage class; the console's budget bars drew no fill and showed the wrong currency (found by the #290 and #188 fixers) | PR #292 |
| D42 - The clients drop what a stopped turn says | #301, PR #306; #305, PR #309 |
| D39 - A `session.read` and an activation of the same session on one pod | #302, PR #307 |
| D44 - Uninstalling the chart deletes its namespace; the scaler forgot a failed write (D40's first item) | #303, PR #304 |
| A person's own remote MCP server that needs their OAuth sign-in (found by the deployment's first profile); then the `initialize`/session handshake and the desktop app's half of the pod path (the TUI's half has landed since; client registration is #585) | #300, PR #310; #319, PR #323; #308, PR #322 |
| D47 - On a plane, a turn the harness stopped reads as a finished one | #320, PR #325 |
| D52 - A worker logs in to OpenBao as one shared role and for every request; a person-mode server's mode before the first bundle | #336, PR #337 |
| D56's SCIM items - a create answered `200`, a delete of an unknown id `204`, and a `PUT` with `active: false` left sponsored principals running | #356, PR #362 |
| D54's first item - with Cilium, a profile could name a loopback or link-local endpoint | #355, PR #360 |
| D51 - an MCP session a renewed token or a dropped server left open (the person-mode case stays in D51) | #358, PR #363 |
| D53's first item - the desktop app showed a team turn that failed on the plane as finished | #354, PR #359 |
| D60 - A checkout that built the previous version kept reporting it | #380, PR #382 |
| D61's first item - `troupe logout` left the daemon holding the plane token | #381, PR #385 |
| D65's first item - cache writes over an OpenAI-compatible gateway were priced as fresh input | #396, PR #420 |
| D65's fifth item - neither the desktop app nor a headless run showed what a turn cost | PR #418 |
| D59's first item - an erasure left the object versions past the first 1,000 | PR #429 |
| D59's second item and D61's first two - the clients showed a private session as a local one, and none could claim one | PR #431 |
| D69's first item - a model call past its timeout was never stopped, and its usage not counted | PR #435 |
| D69's second item - Anthropic's newest models think unasked, and that thinking is dropped on replay | #427 |
| D70's third item - the task list takes model calls of its own on `qwen3-235b` | #428, PR #445 |
| D65's first item - a rewritten task list made the next call write the conversation to the cache again | #389, PR #447 |
| D70's fourth item and D76 - the model list gave a window for a model nobody serves, and the editor hid a configuration's errors | PR #455 |
| D77 - CI on GitHub's hosted runners (the native builds had timeouts already; every build job has one now, and the runners are Ubuntu 26) | PR #456 |
| D66's first item - a summariser call that never answered kept the agent compacting | #404, PR #421 |
| D71's first two items - an erasure counted a refused delete as done, and a large one timed out the daemon's call | PR #467 |
| D74's first two items - a 5xx past its retries said only its status, and an Anthropic stream error showed unmasked | #427, PR #464 |
| D78's first and fifth items - the Copilot file counted in every directory, and `/context` gave no reason for a file left out | PR #471 |
| D79's first two items and its fifth - a Windows daemon died with its terminal, `open` guessed the app's address, and the plane host had no policy | PR #468; #460, PR #466 |
| D81's last item, D73's first and D8's second - `RestartTest` and `AutospawnTest` started slowly enough to fail | PR #469 |
| D84's first item, the key half - a pod could never destroy a team session's key, and the plane marked the erasure done (what is left of it stays in D84) | #470, PR #480 |
| D43's `troupe resume` item - with no id it opened the newest row, which could be a branch or an empty scratch session | #484, PR #495 |
| D62's first item - uninstalling didn't run `troupe-daemon login off`, leaving the login entry pointing at nothing | #76, PR #504 |
| D49's import item - importing MCP servers from other tools dropped their `headers` | #60, PR #507 |
| D99 - `.agents/` and skills: the TUI's layer labels, the desktop app's remove, the clients' skipped lists, unreadable `SKILL.md` and `.agents/AGENTS.md`, and the check's paths in `.agents/AGENTS.md` | PRs #530, #532, #533 |
| D101's first item - `files_skipped` shown as a bare line | PR #530 |
| D100's first item - a linked `opencode.json` gave no servers | #522, PR #531 |
| D98's librarian item - its prompt said other tools' files are in every prompt | #516, PR #534 |
| D84's last item - an instruction file that couldn't be read only logged a warning | #516, PR #533 |
| D93 - Tab completed a command name without its slash | #502, PR #547 |
| D105's first items - `/cancel` kept the window, `/worktree <existing>` and `<name>:` weren't read, a dismissed branch wasn't in `/sessions`, a refused merge said "conflicts", `read_branch` listed its parent, `/dismiss` on a pod, `worktree.remove` inside the tree | #502, PR #556 |
| D106 - a watch trigger ran on the session's own agent with its permissions, unseen, with no state on the protocol | #502, PR #558 |
| D107's first and palette items - a slash command typed in a window went to the agent, the palette dropped the window, Tab matched summaries, an argument hint ran empty, `/agents` listed `worktree` | #502 and #503, PRs #560 and #563 |
| D108 - an upload over 16 MB, or a connection closed mid-call, took the connection or the screen down | #502, PR #552 |
| D109 - `/copy` and Ctrl-Y on Windows | #502, PR #552 |
| D115's first five items - `troupe daemon open` from the TUI lost its daemon on Windows, an MCP stdio server that exited early crashed its start, `clip` got UTF-8, `/upload` read an oversized file first, a dropped protocol client's pending calls exited | PR #566 |
| D117 - the sessions index blocked on a slow stop, the shared cause of most load flakes | PR #568 |
| D113's first six items and D105's last two - an approval asked before a worker restart went to the parent, `/new --branch` forked the empty log, a conflicted merge said to resolve, `worktree.remove` answered an inspected string, `worktree.list` ran four git calls a tree, rows had no model, a dismissed one was titled by its path, the focus named a closed window, `/ask` never said none had finished | #502, PR #570 |
| D107's subagents item, D112's conflict and unparseable-file items, D114's desktop watch box and headless line | #565, PR #571 |
| D102's, D110's and D111's items, and D68's empty `TROUPE_DAEMON_SOCKET` - untracked anchors hashed on read, the old `remember` form, `scope`, anchor case on Windows, `memory.get`'s scope and model, onboarding outside a repository, onboarded files said not read, nested files, second runs, opencode globs and keys | #248, #516, PR #574 |
| Sessions found by the chunk 27 fixer of slot B - erasure ignoring a configured `state_dir`, dormant sessions there unlisted, a slow stop blocking every start, a command reaching a stopping session, the sweep dropping a running session, listings reading every log | PR #576 |
| D26's headless item - `troupe run --headless` exited at the first rest, so a reply to a line queued mid-turn was never printed | PR #262 |
| D26's A2A item - a task stayed `working` after the failure guard stopped its turn | PR #266 |
| D36's dead code - the printer's and the model's dead clauses, the view's recount, the picker's empty branches column, `Troupe.Codec`'s `to`/`reason` (the dead `truncated` and `compaction` clauses were left for #301) | PR #262 |
| D43's subagent-name half - a subagent's window had no name in the TUI | PR #570 |
| D52 - nothing writes a profile's OpenBao role and policy | #627 |
| D55's first item - every worker pod logs in as the one role `troupe-worker` | #627 |
| D64's build.md item - section 3 had no row for `mix troupe.config.schema` | #422 |
| D69's summariser item - the compaction summariser got another model's signed thinking | #590, PR #604 |
| D73's `FakeRemote` item - its `/rpc` could answer errors only without `data` | PR #605 |
| D75's `symbols:` item - a decision's `symbols:` is not checked against the code | #422 |
| D82's last item - the prefix binding of thinking blocks | #465, PR #601 |
| D90's `FakeRemote` item - `commands.list` answered without aliases | PR #547 |
| D100's subagents item - a `.troupe/agents` subagent's trust note reached no client (the desktop app's half is in D103) | PRs #563, #571 |
| D112's choosers item - the TUI's two agent choosers, Ctrl-N and Tab | #594 |
| D115's `open` item - the daemon CLI ran `open` and `xdg-open` by a bare name | PR #562 |
| D118's closed-call item - the desktop app showed a stopped child's closed call as failed without the reason | PR #647 |
| D122's two plane-check items - a connected client isn't judged again when the policy changes, and the plane doesn't record client versions | #657 |
| D123's guardrail item - an organisation's enforced set is a guardrail, not a lock | #657 |
| D124's three frames items - reasoning on replay, Afterglow dark's `--bg-sunken`, no desktop control for `transcript.detail` | #659 |
| D46 - the TUI and headless runs didn't follow a restarted daemon; D55 - a worker's OpenBao mount and an empty static token; D66 - `read_output` named to agents without it, the lax stand-in provider; D40's activation on a draining pod and its test comment; D50's first three items; D65's bench item; D79's open-tab fragment; D131's per-call timeout, TUI first run, viewers' config and the two test-order items | chunk 39's criticals sweep (Decision 923) |

## Won't fix

- **A private session sealed before PR #373 lacks its first events.** This was D61: the
  sealer subscribed after the session started, so `session_created` and what came before
  it were never sealed. The fix holds for every session since; the events of the older
  ones were never written to the sealed log, and nothing can restore them. Judged in
  chunk 39's criticals sweep, 2026-10-18.

## Checked and not a defect

- **The daemon's loopback admits a WebSocket upgrade with no `Origin`.** This was D79.
  A browser always names the page in `Origin` on an upgrade, and `origin_allowed?` in
  `apps/troupe_gateway/lib/troupe/gateway/web.ex` refuses a page whose origin is not
  listed; an upgrade without one comes from a program (the TUI, the VS Code extension, a
  script), which still needs the daemon's token. Checked in chunk 39, 2026-10-18.

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
- **`done ●` and "1 done" after every reply from the command line.** This was in D36: the
  TUI marks the session's own window done until it is opened (PR #241). A question for the
  design, not a defect.
- **A forced `tool_choice`, which the newest Anthropic models refuse.** This was in D82.
  Checked on 2026-10-12: nothing in `apps/` or `clients/` sends a `tool_choice` at all.
- **A team renamed under its sessions' keys.** This was in D88. Checked on 2026-10-12: no
  path renames a team (`team_update` changes its settings only), so a team session's key
  named by the team's name stays the right one.
- **A raw `Port.open` of a console program without `:hide` on Windows.** This was in D115.
  It does nothing on OTP 28, but every raw spawn in the code passes `:hide` (checked on
  2026-10-12); it is a trap for new code, not a defect.
- **A daemon older than 0.8.0 writing `provider: anthropic`.** This was in D63: such a daemon
  reads a `config.set` without `provider` as a model-panel save. The clients of this
  release never send one, and a daemon that old is past support ([SECURITY.md](../../SECURITY.md)).
