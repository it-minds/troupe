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

### D9 - On Windows the desktop app installs into the daemon's state directory (low)

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

### D10 - An `{env:VAR}` key in opencode's config is sent as it is written (unconfirmed, medium)

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

## Taken

| Defect | Taken by |
| --- | --- |
| On Windows, dormant sessions vanish after a daemon restart (`Path.wildcard` on backslashes) | #87, PR #89 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
