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

Found by the #59, #87, #97, #98 and #99 fixers, 2026-09-22 and 2026-09-23.

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

2026-09-23.

### D11 - `/todo cancel <id>` needs an id the TUI never shows (medium)

The TUI lists task text only, so a person cannot see what to type. Found by the #99
fixer (PR #102), 2026-09-23.

### D12 - The TUI reads four protocol error codes wrongly (medium)

`reason/1` in `clients/tui/lib/troupe/remote/rpc.ex` maps -32004 to `not_found` (PROTOCOL.md
section 10: `forbidden`), -32009 to `conflict` (`resync_required`), -32010 to `no_capacity`
(`unavailable`) and -32012 to `session_moved` (`payload_too_large`). A real `conflict`
(-32006) reaches the TUI as the bare word, with no reason. Found by the #59 fixer
(PR #108), 2026-09-23.

### D13 - A cancelled turn may leave a tool call awaiting approval (unconfirmed, medium)

`cancel_everything` writes no `tool_call_completed` for the calls it kills. A turn cancelled
while waiting on an approval would leave that call incomplete and awaiting approval in the
log, and a later cold restart would ask for it again. To confirm: cancel a turn during an
approval, restart the daemon, and resume. Found by the #59 fixer (PR #108), 2026-09-23.

### D14 - Small leftovers of the budget and loop work (low)

- A plane that stored `default_budget_period = daily` now runs on `monthly`, but the
  Settings page marks the row "stored" until someone resets it (PR #103).
- After a daemon crash mid-loop, the TUI status line shows `loop n/N` until the session
  is activated and `loop_stopped interrupted` arrives (PR #108).

## Taken

| Defect | Taken by |
| --- | --- |
| On Windows, dormant sessions vanish after a daemon restart (`Path.wildcard` on backslashes) | #87, PR #89 |
| D1 - A session id is used as a glob pattern | #97, PR #105 |
| D2 - Glob on a runtime path in TUI completion and bundle skills | #98, PR #104 |
| D3 - The TUI sends parameter names the daemon does not accept | #99, PR #102 |
| D7 - A team's budget period offers "daily" and refuses it | #100, PR #103 |
| A team's `monthly` budget never resets (found by the #100 fixer) | #106 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
