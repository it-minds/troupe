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

### D1 - A session id is used as a glob pattern (unconfirmed, possibly high)

`Troupe.Session.Log.locate/2` (`apps/troupe_core/lib/troupe/session/log.ex`) and
`Troupe.Sessions.Index` `from_disk/2` build `<state>/sessions/*/<session_id>/events.jsonl` and
pass it to `Path.wildcard/1`. Nothing validates the id first: no protocol handler checks
its shape. An id of `*` matches the first session's log on disk. The `troupe.ex` read
paths (`Log.read_session/2`, which serves history and subscribe) take the id as the
client sent it.

- The `read_branch` tool is **not** affected. It reads only ids that are an exact match
  in the session's own family.
- The daemon is single-user, so there the exposure is to yourself.
- To confirm: check whether any path lets a client reach `Log.locate`/`Index.get` with an
  id the plane has not authorised. That means a worker pod whose state directory holds
  more than one user's sessions, or a worker WebSocket that trusts the id in the request.
- Fix: validate session ids at the protocol edge, since they are generated, so a strict
  pattern works. Or escape the id and join it by string concatenation: `Path.join` on
  Windows strips a leading `\` from each right-hand part.
- Found by the #87 fixer (PR #89), 2026-09-22.

### D2 - The same glob-on-a-runtime-path bug, outside the harness core (medium)

PR #89 fixed the core's globs. Two more build a pattern from a runtime path without
`Troupe.Paths.glob_escape/1`. On Windows (backslashes), or with `[`/`{` in a directory
name, they find nothing:

- the TUI's file completion, in `clients/tui/lib/troupe/ui/tui/server.ex` `complete_file`
- `read_skill`/`list_skills` in `apps/troupe_protocol/lib/troupe/protocol/bundle.ex`

Found by the #87 fixer (PR #89), 2026-09-22.

### D3 - The TUI sends parameter names the daemon does not accept (unconfirmed, medium)

In `clients/tui`, the worker sends:

- `profile.switch` with `name:`, where Dispatch requires `profile`
- `todo.edit` with `change:`, where Dispatch wants `action`/`content`/`id`
- `fs.upload` with `content_base64`, where Dispatch wants `content`

Against the daemon these would fail with `invalid_params`. Read, not reproduced. To
confirm, do each of the three in the TUI against an installed daemon. Found by the #59
fixer (PR #86), 2026-09-22.

### D4 - The Authentik runbook makes a public client confidential (unconfirmed, medium)

`docs/admin/authentik.md` step 1b creates a **Confidential** provider. The GUI (PKCE, no
secret) and the TUI refresh without a client secret. If Authentik demands the secret on
the code and refresh grants for a confidential client, those fail with
`invalid_client`, and the clients need a **Public** provider. To confirm, sign in to
`/app` against the live Authentik and reload: PR #84 logs the provider's reason. Found
by the #53 fixer (PR #84), 2026-09-22.

### D5 - A long refresh token may not fit the Windows keychain (unconfirmed, medium)

The Tauri build keeps the refresh token in Windows Credential Manager, which caps a secret
at 2560 bytes (about 1280 UTF-16 characters). A long Entra refresh token could exceed
that, and then nothing is stored. To confirm, sign in with Entra in the desktop app and
restart it. Found by the #53 fixer (PR #84), 2026-09-22.

### D6 - Plane mode opens a just-created local session as a team session (low)

In plane mode, a local session opened before the fleet list has caught up defaults its
kind to `team`, and the GUI briefly tries the plane's `session.open`. PR #88 fixed the
default for local mode only (`clients/gui/apps/desktop/src/views/Session.tsx`). Found by
the #85 fixer (PR #88), 2026-09-22.

### D7 - A team's budget period offers "daily" and refuses it (medium)

The `default_budget_period` setting offers `daily`, but a team accepts only `monthly` or
`never`. Choosing the offered value fails. Found by the #54 fixer (PR #90), 2026-09-22.

### D8 - Test hygiene (low)

- The `tmp_dir` tests in `apps/troupe_core` leave an untracked `apps/troupe_core/tmp/`,
  and `.gitignore` does not cover it.
- `apps/troupe_core/test/troupe/tools/publish_test.exs:15` has an unused
  `alias Troupe.Protocol.Event`, and it warns on every test run.
- The root `.formatter.exs` has no `subdirectories`, so `mix format --check-formatted`
  never checks `apps/`. Running `mix format` on an app file reflows unrelated lines.

Found by the #59 and #87 fixers, 2026-09-22.

## Taken

| Defect | Taken by |
| --- | --- |
| On Windows, dormant sessions vanish after a daemon restart (`Path.wildcard` on backslashes) | #87, PR #89 |
