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

### D5 - A long refresh token may not fit the Windows keychain (unconfirmed, medium)

The Tauri build keeps the refresh token in Windows Credential Manager, which caps a secret
at 2560 bytes (about 1280 UTF-16 characters). A long Entra refresh token could exceed
that, and then nothing is stored. Authentik's tokens are 128 characters, so this only
matters for Entra. To confirm, sign in with Entra in the desktop app and
restart it. Found by the #53 fixer (PR #84), 2026-09-22.

### D6 - Plane mode opens a just-created local session as a team session (low)

In plane mode, a local session opened before the fleet list has caught up defaults its
kind to `team`, and the GUI briefly tries the plane's `session.open`. PR #88 fixed the
default for local mode only (`clients/gui/apps/desktop/src/views/Session.tsx`). Found by
the #85 fixer (PR #88), 2026-09-22.

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
- The gateway suite prints `erl_child_setup: failed with error 32 on line 284` a few
  times, with or without failures (probably a port child writing to a closed pipe).
- `apps/troupe_gateway/test/troupe/gateway/restart_test.exs` `create/2` never stops the
  sessions it creates. They live in a second daemon OS process, so they probably don't
  leak into the test VM the way the two fixed in chunk 6 did (unconfirmed).
- Gateway `PrivateTest` (`@moduletag :object_store`) has no reachability check: without
  MinIO it fails with `econnrefused` rather than a SKIPPED block naming `scripts/dev-up`.
- The desktop app's tests time out now and then when the machine is busy (goal-loop,
  local-mode, onboarding, command-palette); local-mode sends before its session is
  attached ("not attached").

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23) and in chunks 3 to 7.

### D9 - The admin docs describe a `subject_claim` setting the plane does not have (unconfirmed, medium)

`docs/admin/integrations.md`, `authentik.md` and `roles-and-permissions.md` say
`subject_claim` names the claim that is the person (`oid` for Entra with SCIM, whose `sub`
is pairwise). No code in this repository's history has it; `Troupe.Plane.OIDC` goes
through `Login.from_claims/1`. If a plane needs it, Entra with SCIM would match a sign-in to
the wrong person, or to none. To confirm: find whether the setting lives in the archived
`troupe-remote` or the live plane's image; otherwise the docs are wrong. Found by the #54
fixer (PR #101), 2026-09-23.

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
- An A2A task stays `working` after the failure guard stops its turn (`turn_ended`
  reason `tool_failures`).
- `troupe run --headless` exits at the first rest, so the reply to a line another client
  queued mid-turn is never printed.

Found by the chunk 5 fixers, 2026-09-26.

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

### D35 - Clicking a desktop notification on Windows doesn't open its session (medium)

`tauri-plugin-notification` can't report a click on desktop (its `show()` drops the
handle; `onAction` is fed only by the phone plugins). Since PR #238 the app opens the
session when its window comes to the front within 15 s of a notification, which a click
usually causes. A real click handler needs the shell to show its own toast through
`tauri-winrt-notification`'s `on_activated` (already in `Cargo.lock`), and single-instance
handling beside it, because a click may start a second copy from the Start-menu shortcut
(unconfirmed). Found by the fixer of PR #238, 2026-09-27.

### D36 - TUI leftovers after the attention fix (low)

- `clients/tui/lib/troupe/ui/headless/printer.ex` still reads the dead
  `:branch_state`/`:branch_failed`.
- `view.ex`'s `waits_on_you?/1` and its status-line recount (from PR #239) are redundant
  since PR #241 derives the window state in the model; so is its comment that no daemon
  sends `branch_state`.
- `model.ex`'s `:finished`, `:delegation_started` and `:delegation_completed` clauses are
  dead (`Translate` never emits them), so a finished subagent's `ended_at` is never set,
  and after a cancel a killed subagent's last activity stays on its window.
- The session picker's `branch_states` column reads `Client.summary` branches, and
  `Troupe.Client.Daemon` always returns `branches: []`, so it is always empty.
- An idle screen stops ticking, so the sessions page's and HQ's ages are only as fresh
  as the last tick.
- A question for the design rather than a defect: chatting from the command line, the
  session's own window shows `done ●`, dimmed, and "1 done" after every reply until you
  open it (PR #241).
- `Troupe.Codec.decode_event` restores only its `@enum_keys` as atoms, so on a rebuild
  from the journal `agent_state` comes back with `to: "idle"` (a string) but
  `reason: :cancelled` (an atom); readers comparing `to` with atoms break on a reopened
  screen.
- `model.ex` highlights code with syntect's dark-only `base16_ocean_dark`, so code keeps
  dark-theme colours on a light terminal.

Found by the fixers of PRs #234, #239 and #241, 2026-09-27.

### D37 - Small leftovers from the 0.6.1 work (low)

- `Troupe.Tools.Output.cap/2` computes "N more bytes" before cutting back to the last
  newline, so it under-reports what was dropped.
- The settings help's "Where things live" says `~/.config/troupe/config.yaml`; on
  Windows the file is under `%APPDATA%\troupe`.
- An agent that crashes in `init` restarts in a tight loop with no backoff (dozens of
  `agent_restarted` a second when the reaper can't spawn).
- `troupe --watch` still walks the whole workspace for `.gitignore` rules at start (PR
  #240 moved that walk out of every other session start).
- The desktop client: after the daemon socket drops, `DaemonClient.connection()` rebinds
  open views but never resubscribes them, so a session screen open across a daemon
  restart may stop receiving events (unconfirmed); `DaemonClient.open` leaves a view
  registered when `subscribe` fails, and later opens reuse it.
- The desktop first run's Where step pre-fills the plane address from the daemon's link
  only, not from the app's own `planeUrl` preference.
- `clients/gui/dev/plane-stack.yml` has its own in-memory OpenBao and one-shot setup, so
  a restart there loses the key as D31 did.
- Dependabot puts Tauri's crates (cargo `tauri` group) and its npm packages (npm
  `tooling` group) in different groups, so one pull request can move one half alone and
  fail Tauri's version check, as #120 did. `@types/node` is 26 while the runtime is 24.
- The comment above `handle("memory.get")` in `dispatch.ex` belongs to `agents.list`.

Found by the chunk 7 fixers, 2026-09-27.

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

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
