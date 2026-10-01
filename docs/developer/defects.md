# Known defects

Defects found in passing, while working on something else, and not fixed yet. Each has a
place in the code, what goes wrong and who saw it. An entry leaves this page when an issue
or a pull request takes it; the line that remains says which one.

Fixers following [fixing-issues.md](fixing-issues.md) add their `noticed` defects here.
Stale docs and style nits are not defects and do not belong here.

| Severity | Meaning |
| --- | --- |
| **high** | data exposure, data loss, or a user-facing failure with no workaround |
| **medium** | wrong behaviour with a workaround, or a failure only some setups hit |
| **low** | noise, hygiene, or a trap for the next developer |
| **unconfirmed** | read in the code, not reproduced; the entry says what would confirm it |

## Open

### D5 - On Windows a refresh token over 1280 characters can't be stored, and the desktop sign-in fails (medium)

`secret_set` (`clients/gui/apps/desktop/src-tauri/src/secrets.rs`) stores the refresh
token with keyring 3.6.3's `Entry::set_password`, which writes it to Windows Credential
Manager as UTF-16 and refuses more than 1280 UTF-16 units (the 2560-byte
`CRED_MAX_CREDENTIAL_BLOB_SIZE`) before writing anything: "Attribute 'password encoded
as UTF-16' is longer than platform limit of 2560 chars" (`validate_attributes` in the
crate's `windows.rs`). It is worse than a token left unsaved: `AuthSession.adopt`
(`clients/gui/packages/client/src/auth.ts`) writes the token before the exchange and
does not catch, so that sign-in fails, and so does a refresh that rotates to such a
token. Authentik's are 128 characters. Entra's are opaque and vary; other projects
report them over 1280 in tenants with many claims, which is still unmeasured here (no
Entra tenant). `set_secret` with UTF-8 would hold 2560 and needs a read path for entries
written as UTF-16; splitting the token across entries has no limit. Either wants a
renamed desktop build to test. Found by the #53 fixer (PR #84), 2026-09-22; the limit
and the failure read in the code by the chunk 9 fixer of slot F, 2026-09-29.

### D8 - Test hygiene (low)

- The root `.formatter.exs` has no `subdirectories`, so `mix format --check-formatted`
  never checks `apps/`. Running `mix format` on an app file reflows unrelated lines.
- `Troupe.Gateway.RestartTest` sometimes fails under load ("the daemon never came up",
  a second VM with a 30 s limit).
- Load-dependent: core `Troupe.Watch.WatcherTest` "poll backend five writes inside the
  debounce window produce one trigger", and the plane's `UsageTest` `enrolled/1`
  (`{:error, :closed}`, probably a shared-database deadlock inside the control connection).
- `clients/tui/test/troupe/worker_commands_test.exs` prints `spawn: Could not cd to
  /tmp/troupe-ws-N` after the todo.edit test: something starts a process in the
  session's workspace after the test deleted it.
- `apps/troupe_protocol` can't run its suite from its own directory: `policy_test.exs`
  needs `Troupe.Operator.Fixtures`, and `VersionTest` needs `troupe_core`. Run it from the
  root (`mix test apps/troupe_protocol/test`).
- The TUI's `FakeRemote` answers `input.send` with the dotted `input.queued` and
  `input.accepted` and never a `user_input`, so the remote session tests don't exercise
  the real sequence.
- Under full load, core `WatcherTest` "poll backend a gitignored file's marker is ignored"
  and `ReadBranchTest` (an `Index` call timeout) fail now and then; both pass alone.
- On the 0.6.3 tip under full load, core `BlobsTest` and `CutShortTest` (an `Index` call
  timeout), the worker's `ReaderLogTest` "a log an activation has taken over" and the
  gateway's `RestartTest` (once with a `FunctionClauseError` in `Troupe.LLM.Fake.render/2`)
  each failed once; all pass alone.
- Under full load, the TUI's `ClipboardTest` and `TUISelectionTest` (Ctrl-Y copy) fail
  now and then; both pass alone.
- The gateway suite prints `erl_child_setup: failed with error 32 on line 284` a few
  times, with or without failures (probably a port child writing to a closed pipe).
- `apps/troupe_gateway/test/troupe/gateway/restart_test.exs` `create/2` never stops the
  sessions it creates. They live in a second daemon OS process, so they probably don't
  leak into the test VM the way the two fixed in chunk 6 did (unconfirmed).
- The desktop app's tests time out now and then when the machine is busy (goal-loop,
  local-mode, onboarding, command-palette); local-mode sends before its session is
  attached ("not attached").

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23) and in chunks 3 to 7.

### D23 - Small leftovers (low)

- The config schema's `$id` (`https://troupe.dev/schema/config/v1.json`) isn't served, so
  an editor can't fetch it.
- Killing `troupe.exe` on Windows can leave Burrito's `erl.exe` running.
- `queue_input` logs a task edit's `input_queued` text as `inspect(%Todo.Edit{})`.
- A worker command that is `waiting` can still be sent after its caller got
  `{:error, :timeout}` at 35 s.
- Under Windows PowerShell 5.1, `scripts/verify-local.ps1`'s `$ErrorActionPreference =
  "Stop"` turns a native command's stderr (with `2>&1`) into a terminating
  `NativeCommandError`, so on a broken install it stops before its summary.
- `verify-local.ps1` stopping the installed daemon leaves a stale
  `%LOCALAPPDATA%\troupe\daemon.json` whose port no longer listens.
- The GUI's `BlobResponse` doc comment (`clients/gui/packages/client/src/types.ts`,
  `session.ts`) still says a server may answer a shorter `range`.

Found by the chunk 4, 5 and 7 fixers, 2026-09-26/27.

### D26 - Small state leftovers in the GUI, A2A and headless runs (low)

- The desktop app starts the daemon with the app's install directory as its working
  directory (`spawn_any` in `src-tauri/src/daemon.rs`), so the uninstaller probably can't
  remove that directory while the daemon runs (unconfirmed).
- Fixed in PR #262: `troupe run --headless` exited at the first rest, so the reply to a
  line another client queued mid-turn was never printed.

The A2A task that stayed `working` after the failure guard stopped its turn was fixed in
PR #266. Found by the chunk 5 fixers, 2026-09-26.

### D30 - Two sources for the brand's assets (low)

- `scripts/brand-icons.py` (Pillow) draws the plane's `favicon.ico` and
  `apple-touch-icon.png` with a second rasteriser; `pnpm icons` (PR #210) could draw them
  from the same mask so the plane and the desktop app match.
- `clients/gui/docs/design/*.dc.html` reference `./support.js`, which is not in that
  directory.

The two copies of the design tokens are one since PR #239. Found by the #159 and #52
fixers (PRs #210, #211), 2026-09-26.

### D32 - Small leftovers from the 0.6.0 work (low)

- On a pod the plane always sends terms, so `contract/1` sets `budget_asks: false` for
  every placed session and the budget question never fires there. If pods should ask,
  the terms need their own switch.

The rest of this entry was fixed in PRs #234 and #237. Found by the chunk 6 fixers,
2026-09-26/27.

### D36 - TUI leftovers after the attention fix (low)

- An idle screen stops ticking, so the sessions page's and HQ's ages are only as fresh
  as the last tick.
- A question for the design rather than a defect: chatting from the command line, the
  session's own window shows `done ●`, dimmed, and "1 done" after every reply until you
  open it (PR #241).
- `model.ex` highlights code with syntect's dark-only `base16_ocean_dark`, so code keeps
  dark-theme colours on a light terminal.
- Dead since the daemon move: `model.ex`'s `:truncated`, `:compaction`,
  `:compaction_started`, `:profile_switched` and `:watch_trigger` clauses, the printer's
  `:truncated` and `:compaction_started` clauses, and a window's `summary` and
  `diff_stat` fields, which nothing feeds.

The rest of this entry (the printer's and the model's dead clauses, the view's recount,
the picker's empty branches column, `Troupe.Codec`'s `to`/`reason`) was fixed in PR #262.
Found by the fixers of PRs #234, #239 and #241, 2026-09-27.

### D37 - Small leftovers from the 0.6.1 work (low)

- The settings help's "Where things live" says `~/.config/troupe/config.yaml`; on
  Windows the file is under `%APPDATA%\troupe`.
- `troupe --watch` still walks the whole workspace for `.gitignore` rules at start (PR
  #240 moved that walk out of every other session start).

Found by the chunk 7 fixers, 2026-09-27. The restart loop of an agent that crashes as it
starts, `Output.cap/2`'s count and the stray comment in `dispatch.ex` were fixed in PR
#266. The desktop client's three items (a view not resubscribed after a dropped daemon
socket, a failed `open` leaving its view behind, and the Where step ignoring the app's
`planeUrl`) were fixed in PR #263; `plane-stack.yml`'s OpenBao and the split Dependabot
groups in PR #265.

### D39 - A `session.read` and an activation of the same session on one pod (medium, unconfirmed)

- `Reader.open` (`apps/troupe_worker/lib/troupe/worker/session/reader.ex`) checks
  `Sessions.whereis` before it starts, but the Link runs pushed commands concurrently, so
  a `session.read` racing a `session.activate` can have the reader's `Restore.events`
  write storage's copy of the log over the live session's, and the events not sealed yet
  are lost. The reader's write should check for a registered manager inside
  `Restore.with_log/2`.
- `Manager.put_back/3`'s `forget` removes the log directory without `with_log` or a check
  for a reader.
- A reader still alive when a manager's dormancy erases the log answers a later
  `Reader.open` from what it had, until its next idle tick (up to 30 s), and then
  `not_found`.

Found by the #269 fixer (PR #271), 2026-09-29.

### D40 - The plane's drains (medium)

- A worker's `session.activate` doesn't refuse on a pod that is draining, so a session
  placed in the few seconds after SIGTERM isn't in the shutdown drain's list.
- `Drain.pod` waits for its push for the drain's timeout plus 30 s, while the pod makes
  sessions dormant one after another (up to 120 s each): several busy sessions can outlast
  it, and the plane gives up on them while the pod is still archiving (unconfirmed).
- Bonny's `SkipObservedGenerations` skips metadata-only modify events, so the operator
  acts on the plane's `troupe.dev/drained` annotation at the next resync (about 30 s);
  the `touched/1` comment in `admin_cluster_test.exs` says sooner.

Found by the #258 and #273 fixers (PRs #264, #274), 2026-09-29.

### D41 - The desktop app after the daemon restarts (medium)

- Unconfirmed: whether Windows raises `Activated` in the running app for a click in the
  notification centre or starts a second copy. `tauri-winrt-notification` 0.8 can't set a
  toast's `launch` argument, so a copy Windows starts can't tell which session was
  clicked; it brings the window forward.

Found by the chunk 9 fixer of slot G (PR #263), 2026-09-29.

### D42 - The clients drop what a stopped turn says (medium)

- The headless printer never prints `:remote_note`, so since the daemon move a headless
  run shows no `done: <summary>`, "context compacted", "budget exhausted", cut-short or
  empty replies, or the harness's notes.
- The TUI and headless runs treat a `turn_ended` with reason
  `agent_failed` (PR #266) as an ordinary rest; a headless run exits 0 on it
  (`printer.ex` `outcome/2`, `model.ex` `failure/3`).
- A2A's `state_of_row/1` maps an idle plane row whose turn the harness stopped to
  `completed` (the row carries no reason).

Found by the chunk 9 fixers of slots D and E (PRs #262, #266), 2026-09-29.

### D43 - Small leftovers from the 0.6.3 work (low)

- `clients/tui/lib/troupe/os/process.ex` still opens the reaper with `Port.open` directly
  and raises when it is missing or won't start; `acp_agent.ex` `open_port/2` does the same
  for a bundle command that exists but won't start (the agent is `:temporary`, so it
  doesn't loop).
- The TUI's `troupe doctor` under a scratch `APPDATA` fails in the Burrito launcher with
  "error: FileNotFound" (with the real `APPDATA` it works).
- Subagents get no `started_at` or name in the TUI (`delegation_started` isn't read), so
  the observer measures their time from the window's start.
- `budget_ask_answered` and `tool_failures_ask_answered` carry `decision` as a string
  live and an atom when `Troupe.Codec` reads them back (nothing reads it yet).
- The TUI picker: every local row's title is the workspace path (the daemon's
  `session.list` has no title; Decision 65 promised the first prompt); a daemon session's
  detail says "running in this VM"; `troupe resume` with no id opens the newest row, which
  may be a branch or an empty scratch session.
- `troupe.log` never rotates (`daemon.log` rotates at 5 MB, three files), and the TUI
  release ignores `TROUPE_LOG_LEVEL` (fixed at warning).
- `Session.Summary.fold/2` crashes on a `todo_updated` whose items aren't a list (only a
  malformed log has one; unconfirmed).
- `scripts/install-local` demands 7-Zip before any TUI build, though only the Windows ERTS
  needs it; `scripts/toolbox` builds `troupe-toolbox` only when it is missing, so an image
  older than PR #208 keeps forwarding the old dev ports until it is rebuilt.
- Without Cilium, the `NoCilium` message on `EgressByHostname` doesn't mention the extra
  port a platform endpoint on a port other than 443 opens (the docs do).

Found by the chunk 9 fixers, 2026-09-29.

### D45 - Small leftovers from the 0.7.0 work (low)

- `admin.team.grant` never writes `Grant.granted_by`, so grants carry no attribution;
  `admin.team.enable` doesn't run the ladder check `admin.team.update` does on the
  settings it is given (platform administrators only).
- Changing a profile's storage class or size class after its pods exist is refused by
  the API server (a volume claim template can't change); the plane has no guard beyond
  the editor's hint.
- The profile editor has no provisioner field, though `single-machine.md` step 1 says to
  set it under Profiles; only the API and MCP can.
- In `gitops` mode an ssh profile's resource keeps the CRD's default of one replica until
  the plane's first pass sets 0, so the operator may run one pod briefly (Decision 738).
- The Workers page links a gitops resource the plane refused (no row) to the editor,
  which then answers `not_found`.
- Only `amount/1` shows the currency; the budget bars' figures, the Overview's "Spent" and
  the Teams cap note show bare numbers, and the admin API calls `budget_micros`
  "millionths of a currency unit" where the rest of the product says dollars.
- The GUI client's `Trigger` type has drifted from `trigger_json` (`review` is a string,
  `notify` a list of strings; `notify_url`, `has_key` and `revision` are missing), and the
  admin MCP projection doesn't emit `required` for nested object properties.
- `POST /trigger/<id>` means to refuse a body that isn't an object, but `Plug.Parsers`
  wraps a JSON array as `{"_json": [...]}` (unconfirmed).
- The plane's object store Secret is marked optional in the chart, so a missing Secret
  doesn't stop the plane from starting.
- Pre-release images and charts pile up on ghcr.io: the pre-release cleanup deletes
  releases and tags, not package versions.
- `scripts/check-neutral.exs` runs only on pull requests into `main` (`ci.yml`), so a
  name slips into a chunk and is caught only at the chunk's pull request.
- Unit-test fixtures and the desktop app's identifier still use an old personal namespace
  (`ghcr.io/objective-mj/...`, `com.objective-mj.troupe`).
- `Session.Log`'s moduledoc cites `troupe ctl verify`, which no client has; the TUI's
  tile headline reads `needs_input ▶ needs input`.
- `docs/mask.png` (2 MB, the source of the brand mask) is referenced by nothing and is
  published with the site; MkDocs is held at 1.x because Material warns that 2.0 breaks
  its plugins (the generator's future belongs to #189).

Found by the chunk 10 fixers, 2026-09-30.

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
| With Entra and SCIM, the plane keys a person on `sub` only (found by the chunk 9 fixer of slot F) | #267 |
| Without Cilium, a profile's own endpoints on other ports or at private addresses are unreachable (found by the #257 fixer) | #268 |
| The plane's `gitops` mode worked only in tests: no `git` in its image, no repository setting, no push credential (found while planning #186) | #186, PR #285 |
| A trigger's timezone typed in the console was ignored; the MCP schema of `admin.trigger.put` didn't match its handler; a profile's bundle channel never reached its row; an ssh profile got a StatefulSet (found by the #186 fixers) | #290, PR #291 |
| Team and host admin methods accepted fields they don't document; the profile editor couldn't save a storage class; the console's budget bars drew no fill and showed the wrong currency (found by the #290 and #188 fixers) | PR #292 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
