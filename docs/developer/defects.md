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
- Under full load, core `WatcherTest` "poll backend a gitignored file's marker is ignored"
  and `ReadBranchTest` (an `Index` call timeout) fail now and then; both pass alone.
- The gateway suite prints `erl_child_setup: failed with error 32 on line 284` a few
  times, with or without failures (probably a port child writing to a closed pipe).
- `apps/troupe_gateway/test/troupe/gateway/restart_test.exs` `create/2` never stops the
  sessions it creates. They live in a second daemon OS process, so they probably don't
  leak into the test VM the way the two fixed in chunk 6 did (unconfirmed).

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23) and in chunks 3 to 6.

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

### D27 - The TUI never draws `read_file`'s numbered body (medium)

`apps/troupe_core/lib/troupe/tools/read_file.ex` writes each line as `N<tab>line`, while
`split_number/1` in `clients/tui/lib/troupe/ui/tui/model.ex` expects a number
right-aligned in five columns. The parse fails, so every file renders raw with its number
inline, and the numbered, highlighted body (Decision 52) never appears. A fix: split at
the tab stop the number's width implies. The comment on `@gutter_width` there also says
the tab expands to an 8-column stop; `@tab` is 4. Found by the #182 fixer (PR #209),
2026-09-26.

### D28 - Writing a setting drops the config file's comments (medium)

`Troupe.Config.Yaml` has no comment-preserving edit for a scalar (`edit_list/4` handles
lists only), so the TUI settings screen, `ModelSettings.write` and the budget question's
"this workspace" answer re-render the whole `config.yaml`. The file before the write is
kept as `config.yaml.previous`. A follow-up to #122's scope-aware writes. Found by the
#183 fixer (PR #213), 2026-09-26.

### D29 - A pod's command palette lists the built-in agents, not the bundle's (low)

On a worker, `commands.list` (`handle("commands.list")` in
`apps/troupe_gateway/lib/troupe/gateway/dispatch.ex`) loads agent definitions with
`Definitions.load(workspace)` alone, without the `bundle_dir`, `entitled` and
`acp_agents` options `Troupe.Session` passes. So a pod's palette shows `priv/agents`
and leaves out the bundle's agents, against Decision 698. Small in practice: agent rows
are `availability: local` and show greyed on a remote session. Found by the fixer of
PR #217, 2026-09-27.

### D30 - Two sources for the brand's assets (low)

- `docs/design/themes/` (read by `mix troupe.theme` for the plane's front page; default
  Footlight) and `clients/gui/docs/design/themes/` (read by `pnpm tokens`; default
  Afterglow since Decision 702) are near-copies that drift.
- `scripts/brand-icons.py` (Pillow) draws the plane's `favicon.ico` and
  `apple-touch-icon.png` with a second rasteriser; `pnpm icons` (PR #210) could draw them
  from the same mask so the plane and the desktop app match.
- `clients/gui/docs/design/*.dc.html` reference `./support.js`, which is only in
  `docs/design/themes/` and `docs/design/admin/`.

Found by the #159 and #52 fixers (PRs #210, #211), 2026-09-26.

### D31 - The dev stack doesn't come back after a WSL restart (low)

`dev/docker-compose.yml` sets no restart policy, so after the WSL VM restarts (an idle
shutdown, `wsl --shutdown`, a reboot) the three containers stay `Exited`. Suites then fail
in ways that look like a bug: gateway `PrivateTest` with `econnrefused`, plane and worker
tests unable to reach Postgres. OpenBao runs in memory, so its transit key and the bucket
are gone too. `scripts/dev-up` brings everything back and re-seeds; `restart:
unless-stopped` on the three services would save the step. Found by the coordinator,
2026-09-27.

### D32 - Small leftovers from the 0.6.0 work (low)

- `/compact` does nothing in the TUI: `Client.Daemon.compact/2` and
  `Client.Remote.compact/2` only return a sentence saying the other side compacts on its
  own. The command table describes it truthfully; it could go.
- `Settings.help_sections/0` (`clients/tui/lib/troupe/settings.ex`) is prose that points
  at `/help` and `/settings` and can drift from the command table.
- The TUI's `Model` folds `:mcp_status` events that nothing emits.
- On Windows, `config.get`'s `path`, `Troupe.Config.user_path/0` and
  `Troupe.MCP.Local.user_path/1` return mixed separators (`...\troupe/config.yaml`) when
  `TROUPE_CONFIG_HOME` has backslashes, and the GUI's Models panel prints it raw;
  `Troupe.Paths.display` exists for this.
- The headless printer answers the budget question with
  `Client.approve(sid, budget_id, :deny)`, an approval call on a question id.
- `Troupe.Instructions.brief/2` finds the repository root with git three times per model
  call.
- The librarian's prompt (`apps/troupe_core/priv/agents/librarian.md`, step 1) still
  copies `AGENTS.md`, `CLAUDE.md` and `copilot-instructions.md` into the brief, which now
  renders after those files themselves (#123, PR #216).
- On a pod the plane always sends terms, so `contract/1` sets `budget_asks: false` for
  every placed session and the budget question never fires there. If pods should ask,
  the terms need their own switch.

Found by the chunk 6 fixers, 2026-09-26/27.

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

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
