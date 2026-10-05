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
- The worker suite's plane-backed tests share `troupe_plane_test` with the plane suite, so
  running both at once can deadlock in Postgres (`40P01` in `plane_link_test.exs`).
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
- Dead since the daemon move: a window's `summary` and `diff_stat` fields, which nothing
  feeds.

The rest of this entry (the printer's and the model's dead clauses, the view's recount,
the picker's empty branches column, `Troupe.Codec`'s `to`/`reason`) was fixed in PR #262,
and the dead `truncated`, `compaction` and other clauses left in both for issue #301.
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

### D41 - A click in Windows' notification centre (unconfirmed)

- Unconfirmed: whether Windows raises `Activated` in the running app for a click in the
  notification centre or starts a second copy. `tauri-winrt-notification` 0.8 can't set a
  toast's `launch` argument, so a copy Windows starts can't tell which session was
  clicked; it brings the window forward.

Found by the chunk 9 fixer of slot G (PR #263), 2026-09-29. The redial to the port and
token a restarted daemon publishes, and the status after a redial that works, were fixed
for issue #305.

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

### D46 - The TUI and headless runs don't follow a restarted daemon (medium)

For a daemon session, `Troupe.Remote.Worker` keeps the endpoint and token it was given at
attach (`clients/tui/lib/troupe/client/daemon.ex`), while the daemon's loopback picks a new
port and a random token on every start (`apps/troupe_gateway/lib/troupe/gateway/loopback.ex`,
`bind/1`, `token/0`). A TUI window or a headless run therefore never reconnects after the
daemon restarts, and a headless run ends 1 after 60 s, though the printer says a daemon
that comes back within a minute costs a script nothing. Read in the code; the desktop app's
half was fixed for #305. Found by the chunk 11 fixer of slot C1 (PR #306), 2026-10-01.

### D48 - A dormant session whose log its root can't replay can never be woken (medium)

When the root's first start fails inside the session's own start (a log the replay can't
fold), `input.send` answers `unavailable` with the raw term
(`{:shutdown, {:failed_to_start_child, {Troupe.Agent.Node, ["root"]}, ...}}`) and no
`turn_ended` `agent_failed` is written: Decision 727 covers a root that crashes after the
session is up, not one that never starts. Found by the chunk 11 fixer of slot C2
(PR #309), 2026-10-01.
On a pod, since PR #325, a root that crashes right after activation puts its session to
sleep at once; that path is not this defect's, which is the daemon's.

### D49 - Small leftovers from the 0.7.1 work (low)

- A fresh install that follows `docs/admin/installing.md` §1 creates its Secrets in the
  release's namespace first, so Helm then refuses to install the chart's own Namespace
  ("exists and cannot be imported"); `createNamespace: false` is the documented answer, but
  `values.small.yaml` and `values.example.yaml` still default it to `true`.
- The scaler doesn't recreate a profile's resource that is missing in `direct` mode, resyncs
  only `replicas`, warns every 15 s while a resend keeps being refused, and reads the
  resource twice a tick (`Upgrade.step` too); `Harness.warm_up` has the same row-first
  order, healed by the read-back but untested.
- The chart is linted and rendered only on pull requests into `main`; `dev-check` doesn't.
- `troupe run <agent>` with an agent that doesn't exist starts the tree anyway and shows
  the raw term as the error.
- `Troupe.Remote.Translate` crashes on a `goal_set` whose `text` isn't a string (only a
  malformed log has one), and the headless printer can print a client-made
  `branch_spawned` twice (it has no `seq`).
- The desktop transcript says a local session was "activated on a pod" (`transcript.ts`
  falls back to "a pod" when `session_activated` has no `pod`), and shows a `tool_failures`
  stop only as the guard's question answered `stop`.
- `Troupe.Tools.identity_of` finds only a pod's configured servers, so a call to a person's
  own MCP server is recorded with the subject `profile`, though since PR #310 the token is
  the person's; `Troupe.MCP.Import` drops `headers`, so a local server that needs a static
  key can't be imported.

Found by the chunk 11 fixers, 2026-10-01.

### D50 - A person's servers offered to a pod session: the rough edges (medium)

- `Troupe.Gateway.ClientTool.run/4` reads only an error answer's `message`, so a client's
  failure reaches the pod's model as "failed on the client: internal_error" and the
  answer's `data.detail` or `reason` is lost (the daemon being unreachable, for one).
- `DaemonClient.registerTools` in `@troupe/client` sends `consent` as a string where the
  server expects `{challenge, confirmed_by}`, and `unregisterTools` sends `names` where the
  server reads `tools`. Neither is used yet; both are wrong.
- PROTOCOL.md section 8's `tool.invoke` example names the tool `notes.search`; the gateway
  sends `client.notes.search`.
- The desktop app offers a person's servers once per attachment: a server signed in to
  while attached is not offered until the next one, and there is no per-server choice.
- The daemon's `mcp.tools` and `mcp.call` hold no MCP session, so each call against a
  stateful server is its own session: `initialize`, the request and a `DELETE`.

Found by the chunk 12 fixers of slots C and A (PRs #322, #323), 2026-10-01.

### D51 - MCP sessions a caller leaves open (low)

A person's MCP session on a pod is not ended when a refreshed token of theirs opens
another: nothing in the client tells one person's renewed token from another person's,
and the pod does not hold the credential to end it with (Decisions 746, 757), so it stays
in the pod's `Troupe.MCP.Sessions` until the pod stops or a bundle drops the server, and
at the server until the server expires it. Found by the chunk 12 fixer of slot A (PR
#323), 2026-10-01; the rest is #358.

### D52 - A worker's own OpenBao identity (medium)

- Nothing writes a profile's OpenBao role and policy: an installation that turns on
  `bao.workerRolePerProfile` (Decision 753) makes `troupe-worker-<profile>` by hand, and
  writes the profile's policy again whenever its granted teams change.

Found by the chunk 12 fixer of slot B (PR #324), 2026-10-01; the rest is #336.

### D53 - Small leftovers from the 0.7.2 work (low)

- A2A's `state_of_row` could read the plane row's `failed_reason` (Decision 750) instead
  of the log, and `Web.Live.Status.from_session/1` is used by no page. (The desktop app
  reads it since #354.)
- A plane row's `cost_micros` lags: a pod reports status on lifecycle changes only, and
  the summary folds the cost later, so a report just after a turn says 0.
- `EndpointUnreachable` (Decision 749): in `gitops` mode an ssh profile's resource gets the
  condition too, since the operator reads no provisioner annotation (738);
  `admin.bundle.validate` and `admin.bundle.preview` have no channel and don't check;
  the console's server check and preview don't show it; `gitHosts` aren't checked.
- `TROUPE_STATE_HOME` doesn't move `daemon.json`, which is always under
  `%LOCALAPPDATA%\troupe`, so a daemon run with scratch homes still takes the machine's one
  discovery slot, and a forced stop leaves a stale file (`verify-local.ps1` too).
- The daemon's clocks are set in whole minutes, so a waiting session's clock can't be
  under a minute.
- Core `SleepTest` failed once under the full core suite's load and passed alone.

Found by the chunk 12 fixers, 2026-10-01.

### D54 - What a worker may reach: the edges left after #268 (medium)

- An `egress.fqdns` entry written `host:port` is compared to `allowedEgress` as the whole
  string (`Troupe.Policy.matches?/2`), and with Cilium it becomes a `toFQDNs` `matchName`
  that carries the port and admits nothing: ports in entries work without Cilium only.
- Without Cilium, an MCP identity's `tokenUrl` (Decision 747) on a port other than 443 or
  80 is neither admitted nor judged.
- An IP-literal endpoint inside the cluster (a pod's address) gets an `ipBlock`, and what
  that admits depends on the CNI; the docs say to name the Service.
- `:inet.ntoa` prints an IPv6 address in `::/96` as `::0.0.0.2`, in `Reach`'s blocks and the
  Cilium path's `address_block` alike (a deprecated range; cosmetic).

Found by the chunk 13 fixer of slot B13 (PR #338), 2026-10-02.

### D55 - A worker's OpenBao login: what #336 left (medium)

- By default every worker pod logs in as the one role `troupe-worker`, and the dev
  manifests give that role a policy over every team's keys. Keeping profiles apart takes
  per-profile roles and `bao.workerRolePerProfile` (Decision 753), and then narrowing or
  removing the shared role, since a pod chooses the role it asks for.
- The worker doesn't read `TROUPE_BAO_AUTH_PATH`: its auth mount is always `kubernetes`,
  where the plane's follows `bao.authPath`.
- `Troupe.KMS.OpenBao.static_token/1` takes `TROUPE_BAO_TOKEN` unfiltered, so an empty
  value counts as a static token and no login is made (the operator never sets it on a
  pod).

Found by the chunk 13 fixer of slot C13 (PR #337), 2026-10-02.

### D56 - SCIM and the subject claim: small leftovers (low)

- After a re-key (Decision 751) a plane token minted before the move is refused as an
  unknown user; how the desktop app and the TUI take that one refusal is untested, and so
  is the budget ceiling carried over when an old row is folded into SCIM's.
- The gateway suite's `FakePlane` doesn't answer `session.assertion`, so the daemon's
  `exchange/2` for a private session is covered only by an installed-build check.
- `SubjectClaimTest` ("switching on an installation that already has people...") failed
  once under the full plane suite's load and passed alone.

Found by the chunk 13 fixers of slots A13, D13 and E13 (PRs #339, #345, #343), 2026-10-02.

### D57 - SCIM: what is left after #356 (low)

- `PUT /scim/v2/Users/:id` and `/Groups/:id` ignore the id in the path and upsert on the
  body's subject: a `PUT` to an id the plane doesn't have creates a resource (RFC 7644
  section 3.5.1 says a `PUT` must not), and one whose body names another `externalId` (or
  `userName`) changes or creates that person instead of being refused as `mutability`, the
  way a `PATCH` is (Decision 754). Addressing `PUT` by id through the `PATCH` path would
  close both.
- A refused `POST` or `PUT` answers `400` as `{"status", "detail"}` without SCIM's error
  schema, and a user body with neither `externalId` nor `userName` (or a group body with
  neither `externalId` nor `id`) raises and answers `500`.
- A deleted user stays visible to `GET` by id and to filters (the plane deactivates rather
  than deletes, for the audit trail and a later reactivation); RFC 7644 section 3.6 has a
  `404` and leaves it out. That is deliberate but no decision says so.
- Responses carry `application/json`, not `application/scim+json`.
- Unconfirmed: a `POST` or `PUT` passes `active` to the changeset unread, so a string
  `"False"` is probably refused where a `PATCH` reads it as false.

Found by the chunk 14 fixer of slot D14 (PR #362), 2026-10-03.

### D58 - The desktop app and a failed turn: what #354 left (low)

- The review queue shows a failed run's Failed pill but says "Ended: Idle", and
  `wentWrong` ignores `row.failed`, so the run's group isn't sorted first or marked as
  something that did not finish (`views/Review.tsx`; about two lines).
- A session whose turn stopped on `tool_failures` still reads Idle in the session view's
  header while the list says Failed; changing it reopens Decision 745's choice for the
  transcript.
- A local session can't carry `tool_failures`: the daemon's `session.list` `failed` is
  `agent_failed` only (Decision 745).

Found by the chunk 14 fixer of slot E14 (PR #359), 2026-10-03.

### D59 - Private sessions and MCP sessions: small leftovers of 0.7.4 (low)

- `ObjectStore.list_versions/2` reads one page, so an erasure (a pod's, and since PR #364
  a private session's) of a session with more than 1000 object versions leaves the rest.
- How the desktop app and the TUI show a session in the new `erasure_pending` state is
  untested: the client library types a state as an open string, and the TUI's remote
  worker reads a state it doesn't know as none.
- `Troupe.Session.MCP`, reloading after a server left `mcp.json`, stops the server but
  leaves its HTTP sessions in the local session's table and open at the server until the
  local session stops (`Sessions.retain/2` would end them, as `put_servers` now does on a
  pod).

Found by the chunk 14 fixers of slots A14 and B14 (PRs #364, #363), 2026-10-03.

### D61 - Private sessions after #365: what is left (medium)

- The daemon's `session.list` rows carry no `kind` or `sync`, so the desktop app lists a
  private session as a local one ("Here only").
- A private session whose plane row names another device is left alone on resume
  (Decision 764), but no client offers `claim`, which a renamed machine needs too.
- A private session sealed before PR #373 lacks its first events (`session_created`): the
  sealer subscribed after the session started.

Found by the chunk 15 fixer of slot D15 (PR #373), 2026-10-04.

### D62 - Start at login: small leftovers (low)

- Uninstalling (`install.sh` / `install.ps1 --uninstall`) doesn't run
  `troupe-daemon login off` first, so the login entry is left pointing at nothing.
- On macOS and Linux a daemon started at login (and one a Finder-launched desktop app
  starts) gets the session manager's minimal `PATH`, so tools an agent's shell expects
  (Homebrew, `~/.local`) may be missing.
- Unchecked: the desktop shell's `spawn_any` (`src-tauri/src/daemon.rs`) starts
  `troupe-daemon.cmd run` without `CREATE_NO_WINDOW`, so a daemon the desktop app starts
  on Windows may get a console window of its own.
- A Startup item disabled in Task Manager still reads as on in `troupe daemon login
  status`, and the Windows entry spells the drive in lower case.
- A test suite that reaches the setup flow's `daemon` step must point
  `:troupe_core, :start_at_login` at a scratch home (core's and the gateway's do), or it
  writes the developer's real login entry.

Found by the chunk 15 fixer of slot B15 (PR #372), 2026-10-04.

### D63 - Shared settings and user commands: small leftovers (low)

- `troupe config --explain --json` likely fails when a list holds an unset `{env:VAR}` (an
  MCP server's `args`): `Explain.json_value` keeps the `{:unset_env, ...}` tuple, which
  JSON can't encode. `config.get` has the fix (PR #374); `Explain` doesn't.
- A daemon older than 0.8.0 treats a `config.set` without `provider` as a model-panel save
  and writes `provider: anthropic` when the file has none. This release's clients refuse to
  set a single key unless `config.get` lists `keys`; another client could still do it.
- The TUI's settings help says a `next_run` setting applies "the next time the TUI
  starts"; most apply to the next session.
- Two clients saving one file at the same moment: the last write wins (Decision 761).
- A command file that shadows a built-in is skipped with a warning logged on every
  `commands.list`, so each time a palette opens; and the TUI reads the command table only
  when a session opens (the desktop app reads it each time its palette opens).
- The TUI suite prints "spawn: Could not cd to /tmp/troupe-ws-NNN" in several tests, and
  `InterruptTest` ("a console that cannot be read ends the watch") failed once under the
  full gate's load and passed alone.

Found by the chunk 15 fixers of slots A15, B15 and C15 (PRs #374, #372, #370), 2026-10-04.

### D64 - Small leftovers from the 0.8.1 work (low)

- Nothing checks that a new `mix.exs` that reads `VERSION` also lists the `:troupe_version`
  compiler (Decision 768); `build.md` says it should. An assertion in `Troupe.VersionTest`
  would hold it.
- `/todo complete|cancel|add`, typed in a branch window, is a slash command missing from
  `Troupe.Commands`, so it is in neither `commands.list`, the palettes, `troupe --help` nor
  the command reference.
- `docs/developer/build.md` section 3 has no row for `mix troupe.config.schema` (the
  config schema and the configuration reference it writes).
- `troupe --workspace DIR` with a directory that doesn't exist is unchecked; the VS Code
  extension always passes a real folder.
- The TUI suite shares one embedded daemon, which answers a replayed `command_id` with the
  first answer: two tests using the same literal id make the second a silent no-op. Tests
  should take ids from `RPC.command_id()`.

Found by the chunk 16 fixers, 2026-10-04.

### D65 - What a turn costs: what #389 left (medium)

- The task list goes after the system prompt's cache mark, before the messages
  (`Request.system_tail`, Decision 770). Each `todo_write` changes it, and the provider
  writes the conversation's cache again: in a 30-call turn with about ten list updates the
  saving is about 2x where it could be about 8x. Keeping the list as it was for the whole
  turn (refreshed on new input or after a compaction), or sending it as a message, would
  keep the cache.
- Unchecked: whether a gateway speaking Anthropic's API passes `cache_control` on.
- Subagent spend is added to the parent's turn live only. A cancel or a parent restart in
  the middle of the turn loses what the subagents reported; the delegation's own
  `tool_call_completed` could carry it.
- The headless printer doesn't print the per-turn line, and the desktop app shows no turn
  cost: `@troupe/client`'s fold reads neither `turn` (on `turn_ended`, `cancelled`,
  `agent_done`) nor `compacted.usage`.
- `Troupe.Bench.Model.measure/2` counts `request.system` only, so the offline bench's
  `system_bytes` leaves out the task list the log counts; `Request.system_text/1` has both.

Found by the chunk 17 fixers, 2026-10-04.

### D66 - Compaction and cut tool output: small leftovers (medium)

- `:compacting` has no clause for `{:llm_timeout, ref}` (`agent/server.ex`), so `common/4`
  drops it: a summariser call that hangs keeps the agent in `:compacting` past
  `llm_timeout_ms`, where `:thinking` turns the same message into an `llm_error`.
- The `explore`, `answer`, `ask` and `librarian` profiles don't offer `read_output`, but
  `grep`, `git_read` and `web_fetch` cut long output with a marker naming a `read_output`
  call: those agents are told to make a call they can't. #389's stubs are skipped for such
  profiles (Decision 771); the markers are not.
- `Troupe.SessionCase` could turn the stand-in provider's strict tool-call pairing on by
  default: the whole core suite passes with it (Decision 774).

Found by the chunk 17 fixers, 2026-10-04.

### D67 - Model discovery: what #410 left (low)

- Discovery asks no provider when the key comes from `ANTHROPIC_API_KEY` or
  `OPENAI_API_KEY` only: `Store.targets` (`llm/catalog/store.ex`) checks the config's
  `api_key`, so `troupe models` says "catalog: no provider to ask".
- A named provider without `models:` entries shows a `name/` row reading "no price".
- A changed key alone doesn't trigger a refresh (Decision 778's triggers are the provider,
  the base URL, the age, a failed provider and a missing configured model).
- A model lookup that misses during a session waits for the next session's start to
  refresh.

Found by the #410 fixer, 2026-10-04.

### D68 - Small leftovers from the 0.8.2 work (low)

- `troupe run ... --watch`, and `watch: true` in the config, show "watch: off" in the
  TUI's status line: either watch mode isn't on for run sessions or it isn't reported.
- The TUI's "session created as build" note is drawn after the first turn's lines.
- On Windows, killing `troupe.exe` (the Burrito launcher) leaves its VM (`erl.exe`)
  running and holding the pipe.
- `troupe bench --live` prints the history path with mixed separators on Windows;
  `Troupe.Paths.display/1` would print it the platform's way.
- The embedded daemon on Windows with `TROUPE_DAEMON_SOCKET` set but empty fails with
  `{:listen_failed, "unix:", :eafnosupport}`; an empty value should count as unset.
- A daemon started with only the `TROUPE_*_HOME` variables pointing at scratch still
  writes `%LOCALAPPDATA%\troupe\daemon.json`, which then names a daemon that is gone.
- `scripts/dev-check` doesn't run `mix troupe.bench` (about 10 s), so a change past a
  budget shows only on the chunk's pull request into `main`.
- Two `scripts/ci` runs from different worktrees share the toolbox's Docker volumes and
  can break each other.

Found by the chunk 17 fixers and the coordinator, 2026-10-04.

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
| A person's own remote MCP server that needs their OAuth sign-in (found by the deployment's first profile); then the `initialize`/session handshake and the desktop app's half of the pod path; client registration and the TUI's half are next | #300, PR #310; #319, PR #323; #308, PR #322 |
| D47 - On a plane, a turn the harness stopped reads as a finished one | #320, PR #325 |
| D52 - A worker logs in to OpenBao as one shared role and for every request; a person-mode server's mode before the first bundle | #336, PR #337 |
| D56's SCIM items - a create answered `200`, a delete of an unknown id `204`, and a `PUT` with `active: false` left sponsored principals running | #356, PR #362 |
| D54's first item - with Cilium, a profile could name a loopback or link-local endpoint | #355, PR #360 |
| D51 - an MCP session a renewed token or a dropped server left open (the person-mode case stays in D51) | #358, PR #363 |
| D53's first item - the desktop app showed a team turn that failed on the plane as finished | #354, PR #359 |
| D60 - A checkout that built the previous version kept reporting it | #380, PR #382 |
| D61's first item - `troupe logout` left the daemon holding the plane token | #381, PR #385 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
