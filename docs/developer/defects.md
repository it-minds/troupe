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
- Under WSL, 2 tests in `apps/troupe_gateway/test/troupe/gateway/files_test.exs` fail
  (`fs_changed` timing, no `inotifywait`), and `Troupe.Gateway.RestartTest` sometimes
  fails under load ("the daemon never came up", a second VM with a 30 s limit).
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

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23) and in chunks 3 to 5.

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
- `scripts/verify-local.ps1` prints "To go back: install-local.ps1 -Rollback" even when
  its only failure is another daemon answering, which could lead to rolling back a good
  install.
- The GUI's `BlobResponse` doc comment (`clients/gui/packages/client/src/types.ts`,
  `session.ts`) still says a server may answer a shorter `range`.

Found by the chunk 4 and 5 fixers, 2026-09-26.

### D24 - The librarian can run in every session of a repository (medium)

Since #201 a librarian run that ends normally stamps the brief. A run that fails (model
error, budget, cancel) stamps nothing, so with `memory_auto_refresh` it runs again in every
new session, and a repository with no brief whose librarian writes nothing gets one in
every session too. Each spends tokens. A fix: record an attempt time and cap automatic
refreshes (for example once per `memory_max_age_days`). Found by the fixer of PR #201,
2026-09-26.

### D25 - An ACP agent whose subprocess exits may run its task again (unconfirmed, medium)

`Troupe.Agent.ACPAgent` starts under its parent's DynamicSupervisor with the default
`use GenServer` child spec (`restart: :permanent`), so one whose subprocess exits stops
`:normal` and is restarted, re-running its task. #198 (stopping a subagent once it has
reported) narrows this but doesn't remove it. It should be `:temporary`. To confirm: an ACP
agent whose subprocess exits once; count its task starts. Found by the fixer of PR #198,
2026-09-26.

### D26 - Small state leftovers in the GUI, A2A and headless runs (low)

- The GUI transcript (`clients/gui/packages/client/src/transcript.ts`, `agent_done`) sets
  the session's `doneReason` on any agent's `agent_done`, so a subagent finishing (or one
  ended `interrupted` by a restore) makes the session view say "Finished".
- The desktop app reconnects with `session.open` in activate mode, so any dropped socket
  wakes a session that had gone to sleep on its own.
- The desktop app starts the daemon with the app's install directory as its working
  directory (`spawn_any` in `src-tauri/src/daemon.rs`), so the uninstaller probably can't
  remove that directory while the daemon runs (unconfirmed).
- An A2A task stays `working` after the failure guard stops its turn (`turn_ended`
  reason `tool_failures`).
- `troupe run --headless` exits at the first rest, so the reply to a line another client
  queued mid-turn is never printed.

Found by the chunk 5 fixers, 2026-09-26.

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

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
