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

- The `tmp_dir` tests in `apps/troupe_core` leave an untracked `apps/troupe_core/tmp/`,
  and `.gitignore` does not cover it.
- `apps/troupe_core/test/troupe/tools/publish_test.exs:15` has an unused
  `alias Troupe.Protocol.Event`, and it warns on every test run.
- The root `.formatter.exs` has no `subdirectories`, so `mix format --check-formatted`
  never checks `apps/`. Running `mix format` on an app file reflows unrelated lines.
- Under WSL, 2 tests in `apps/troupe_gateway/test/troupe/gateway/files_test.exs` fail
  (`fs_changed` timing, no `inotifywait`), and `Troupe.Gateway.RestartTest` sometimes
  fails under load ("the daemon never came up", a second VM with a 30 s limit).
- `clients/tui/test/troupe/worker_commands_test.exs` prints `spawn: Could not cd to
  /tmp/troupe-ws-N` after the todo.edit test: something starts a process in the
  session's workspace after the test deleted it.

- Seed- or load-dependent: the TUI's `RemoteSessionTest` 10k-delta flood (4.8 MB against a
  4 MB bound on seeds 936525 and 877736), and core `Session.LoopTest` "with
  resume_on_restart the loop carries on" (the two outcomes in the other order).
- `apps/troupe_protocol` can't run its suite from its own directory: `policy_test.exs`
  needs `Troupe.Operator.Fixtures`, and `VersionTest` needs `troupe_core`.
- The memory test "a second session finds a brief and starts nothing" refutes an event
  that could only arrive before its subscription, so it can pass vacuously.

- Order- or load-dependent: core `CutShortTest` (`cut_short_test.exs:106`) once saw
  `budget_ask_answered` after `budget_exhausted` in a full run, and the plane's
  `UsageTest` `enrolled/1` sometimes gets `{:error, :closed}` from the control listener.
- Unused aliases warn in `harness_test.exs` (`Principals`) and `triggers_test.exs` in the
  plane.
- Parallel plane suites on the shared `troupe_plane_test` database deadlock (Postgrex
  `40P01`); run one at a time. A branch that adds a migration leaves the shared database
  unmigrated for everyone else until someone runs `MIX_ENV=test mix ecto.migrate`.

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23) and in chunks 3 and 4 (2026-09-25/26).

### D9 - The admin docs describe a `subject_claim` setting the plane does not have (unconfirmed, medium)

`docs/admin/integrations.md`, `authentik.md` and `roles-and-permissions.md` say
`subject_claim` names the claim that is the person (`oid` for Entra with SCIM, whose `sub`
is pairwise). No code in this repository's history has it; `Troupe.Plane.OIDC` goes
through `Login.from_claims/1`. If a plane needs it, Entra with SCIM would match a sign-in to
the wrong person, or to none. To confirm: find whether the setting lives in the archived
`troupe-remote` or the live plane's image; otherwise the docs are wrong. Found by the #54
fixer (PR #101), 2026-09-23.

### D10 - The protocol's documents and the gateway disagree (low)

- PROTOCOL.md says `fs.upload` answers `{path, size, hash}`; `Troupe.Gateway.Dispatch`
  answers `{path, bytes}`. PROTOCOL.md's `blob.get` answer has a `range` that Dispatch
  never sends. Found by the #99 fixer (PR #102).
- Dispatch serves `agents.list`, `identity.get`, `identity.link` and `identity.unlink`, but
  `Troupe.Protocol.Schema.commands/0` has no entry for them, so `protocol/schema/v1/`
  has no JSON Schema for them. Found by the fixer of PR #110.
- PROTOCOL.md's list of activating commands leaves out `tools.register`. Found by the
  #119 fixer (PR #140), 2026-09-25.

2026-09-23 and 2026-09-25.

### D14 - Small leftovers of the budget and loop work (low)

- A plane that stored `default_budget_period = daily` now runs on `monthly`, but the
  Settings page marks the row "stored" until someone resets it (PR #103).
- After a daemon crash mid-loop, the TUI status line shows `loop n/N` until the session
  is activated and `loop_stopped interrupted` arrives (PR #108).

### D15 - On Windows the desktop app installs into the daemon's state directory (low)

The desktop app's NSIS setup (`installMode: currentUser` in
`clients/gui/apps/desktop/src-tauri/tauri.conf.json`) installs into
`%LOCALAPPDATA%\Troupe`. The daemon keeps its state in `%LOCALAPPDATA%\troupe`, and NTFS
is case-insensitive, so both are one directory: `troupe-desktop.exe` and `uninstall.exe`
sit beside `sessions\`, `identity.json` and `daemon.json`.

- Nothing loses data today. Tauri's uninstaller deletes its own files by name and removes
  the directory only when it is empty.
- Anything that treats the install directory as the app's own takes the sessions and the
  machine's identity with it: a bundler template that removes it recursively, a person
  deleting "the app's folder", a cleanup tool. `install.ps1 -Uninstall -Purge` has to run
  the app's uninstaller before it purges the state, and does.
- Fix: give one of them another directory. For example, an NSIS hook or template that
  installs under `%LOCALAPPDATA%\Programs\Troupe`, or a subdirectory for the daemon's
  Windows state.
- Found reviewing the installers (PR #121), 2026-09-24.

### D18 - A session restored while a subagent waits on an approval may keep it open (unconfirmed, medium)

On restore, the root's `delegate` call is closed as interrupted, but the child's own call
gets no `tool_call_completed` or `cancelled`, so `Summary`, the worker and the GUI
transcript would keep that approval open. The dormant listing counts only the root's
approvals. To confirm: a subagent waiting on an approval, a daemon restart, then the fleet
summary. Found by the #145 fixer (PR #150), 2026-09-25.

### D19 - Restart leftovers in delegation (low)

- When a restart re-runs a delegation, the old child's log has no `agent_done`, so a
  listing may show that child as never finished.
- A root's `llm_failed` note goes into the conversation but not the log, so after a
  restart the model no longer sees "The previous model request failed".
- `finish_summary` is not folded, so a `finish` whose batch had a sibling re-run after a
  warm restart loses its summary and takes another model turn.

Found by the #149 fixer (PR #151), 2026-09-25.

### D21 - A remote session that moves to another pod isn't followed (medium)

`Troupe.Remote.Worker.connect/1` reconnects to the endpoint it stored and never calls
`session.open` again, so an active remote session whose plane moved it to another pod is
not followed. The old -32012 "session moved" retry, removed in #163 because PROTOCOL.md
section 10 has no such code, never fired for a real move either. Found by the #158 fixer
(PR #163), 2026-09-26.

### D22 - Revoking access or erasing a running session may keep its budget reservation (unconfirmed, medium)

`Identity.revoke/2` calls `Sessions.read_only_for/2`, which takes active sessions off
their pods with no `Placement.release` or `Budget.release`. `Erasure.erase/2` of a running
session never releases the team/person budget slice: the worker's `session.erase` doesn't
report dormancy, and `TeamBudget.load` reloads open reservations from the ledger. Placement
recovers on its recount (#174); the budget slices would look held for good. To confirm:
revoke a person with a running session, or erase one, then read the team's reserved
amount. Found by the #173 fixer (PR #174), 2026-09-26.

### D23 - Small leftovers of chunk 4 (low)

- The config schema's `$id` (`https://troupe.dev/schema/config/v1.json`) isn't served, so
  an editor can't fetch it.
- Killing `troupe.exe` on Windows can leave Burrito's `erl.exe` running.
- `admin.profiles.list` (the Workers page, every second) reads each Kubernetes
  WorkerProfile twice.
- `Provision.conditions/1` handles only `{:error, _}`; an exit from the Kubernetes client
  would crash the calling LiveView.
- `PlatformBudget`'s moduledoc says the deployment cap comes from a Helm value; nothing
  outside tests sets `:deployment_budget_micros`.
- `Troupe.A2A.Plane.list_tasks/1` sends `sessions.list` a nested `filter` the plane
  ignores; nothing calls it.
- `RPC.scope_hint` still accepts the old `data.scope` spelling beside section 10's
  `required_scope`, and the TUI's `FakeRemote` attaches `data.params` to every error, which
  only the removed -32012 retry read.
- The worker reports a root in agent state `waiting` as `idle` for the moment before the
  question is logged.

Found by the chunk 4 fixers, 2026-09-26.

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
| A finished subagent stays in memory until its session stops (found by the #134 fixer) | #171 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
