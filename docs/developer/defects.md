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

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23) and in chunk 3 (2026-09-25).

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

### D11 - `/todo cancel <id>` needs an id the TUI never shows (medium)

The TUI lists task text only, so a person cannot see what to type. Found by the #99
fixer (PR #102), 2026-09-23.

### D12 - The TUI reads four protocol error codes wrongly (medium)

`reason/1` in `clients/tui/lib/troupe/remote/rpc.ex` maps -32004 to `not_found` (PROTOCOL.md
section 10: `forbidden`), -32009 to `conflict` (`resync_required`), -32010 to `no_capacity`
(`unavailable`) and -32012 to `session_moved` (`payload_too_large`). A real `conflict`
(-32006) reaches the TUI as the bare word, with no reason. Found by the #59 fixer
(PR #108), 2026-09-23.

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

### D16 - An `{env:VAR}` key in opencode's config is sent as it is written (unconfirmed, medium)

`Troupe.Config.OpenCode.provider/3` (`apps/troupe_core/lib/troupe/config/open_code.ex`)
takes `options.apiKey` and `options.authToken` as written. The fallback merges them into
the session's providers, and `Troupe.Config.target/2` sends the key unchanged. Only
`config.yaml` goes through `Troupe.Config.interpolate/1`. opencode itself expands
`{env:VAR}` (and `{file:path}`), so a key written that way in `opencode.jsonc` reaches
the provider as the literal text `{env:VAR}`, and the provider refuses it.

- Workaround: a key in opencode's `auth.json`, or the copy `troupe config` offers,
  since `config.yaml` is interpolated when it is read.
- To confirm: `apiKey: "{env:SOME_KEY}"` in `opencode.jsonc` with no `config.yaml`,
  then a session; the provider answers 401.
- Fix: interpolate in `OpenCode.provider/3`, as `Config.read_yaml/1` does.
- Found while adding the opencode copy (PR #121), 2026-09-24.

### D17 - A question that times out or is cancelled stays open in the GUI (medium)

The GUI transcript's `openQuestions` (`clients/gui/packages/client/src/transcript.ts`)
never closes a question on its call's `tool_call_completed` (an `ask_user` that timed out),
on a `cancelled`, or on `tool_failures_ask_answered` (the failure guard's question when
nobody is there to answer). The TUI has the first gap for questions too. #143 and #150
fixed the same gaps for approvals. Found by the #145 fixer (PR #150), 2026-09-25.

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

### D20 - Small leftovers of the first-run and headless work (low)

- A headless run still waits for ever if the daemon connection dies for good; killing
  `troupe.exe` on Windows can leave Burrito's `erl.exe` running.
- Plain `troupe` with a redirected, non-terminal stdout renders into it and never exits.
- The headless root window is named `/root`, not the profile.
- Printed paths still mix separators on Windows in config errors and warnings,
  `config --explain` and the daemon's status line (`Endpoint.discovery_path/0`).
- `Troupe.Protocol.Daemon.detach/1` starts the daemon with `cmd.exe /c start /b`; a quoted
  path with a space becomes `start`'s window title. The TUI never reaches it.
- The TUI help (`clients/tui/lib/troupe/settings.ex` ~458) says `troupe daemon status`
  prints the state directory; it doesn't.
- The worker's `activation_error/1` shows a `Troupe.Config.Error` as an inspected struct.
- The config schema's `$id` (`https://troupe.dev/schema/config/v1.json`) isn't served, so
  an editor can't fetch it.
- `Ledger.breakdown/3` puts its default `to: DateTime.utc_now()` into the cache key, so a
  call without `:to` never hits the cache and adds an ETS entry until the sweep.
- Config loader warnings (`apps/troupe_core/lib/troupe/config/layers.ex`) and
  `config validate/migrate/--explain` output (`config/explain.ex`) say `troupe config ...`
  even when `troupe-daemon` prints them.
- The TUI tells a plane (remote) session's no-key model error to run `troupe config`
  (`remote/translate.ex` -> `ui/model_error.ex`), which can't fix a plane worker's key.

Found by the fixers of #76 (PRs #146, #153), #106, #122, #127 and #128, 2026-09-25.

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

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
