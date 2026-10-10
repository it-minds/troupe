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
- Under full load, core `SleepTest` ("sleeps on a spent budget's question") and two of the
  gateway's `PrivateTest` tests ("a seal with nobody linked", "carrying on another
  person's link") failed now and then, the latter beside `session_ids_test` and
  `daemon_test`; all pass alone. Core `Session.ShellTest` "a restart puts back a note ...
  gives it once" is the other way round: it fails alone and passes in the full run.
- CI's umbrella dev-check job can wait on "Waiting for lock on the build directory" until
  its 20-minute timeout, the lock held by an orphan `beam.smp` the runner kills at the
  job's end (PR #495's run 37842248603); a re-run passes.
- With mise's shims on `PATH` in WSL, the core suite's `FileToolsTest`, `ReadOutputTest`,
  `ReadRootsTest` and `BenchTest` fail as `BenchCLITest` does: the `rg` shim answers "No
  version is set" outside a mise directory.
- Under full load, core `Troupe.Agent.CompactionTest` "a result the model has not answered
  yet is sent whole" failed once (a 54-byte result where it waits for one over the inline
  limit); it passes alone.

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23), in chunks 3 to 7, and by
the chunk 24 and 26 fixers (2026-10-08/09).

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
  detail says "running in this VM".
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
  the person's.

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

- `Troupe.Session.MCP`, reloading after a server left `mcp.json`, stops the server but
  leaves its HTTP sessions in the local session's table and open at the server until the
  local session stops (`Sessions.retain/2` would end them, as `put_servers` now does on a
  pod).

Found by the chunk 14 fixers of slots A14 and B14 (PRs #364, #363), 2026-10-03.

### D61 - Private sessions after #365: what is left (medium)

- A private session sealed before PR #373 lacks its first events (`session_created`): the
  sealer subscribed after the session started.

Found by the chunk 15 fixer of slot D15 (PR #373), 2026-10-04.

### D62 - Start at login: small leftovers (low)

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

- Unchecked: whether a gateway speaking Anthropic's API passes `cache_control` on.
- Subagent spend is added to the parent's turn live only. A cancel or a parent restart in
  the middle of the turn loses what the subagents reported; the delegation's own
  `tool_call_completed` could carry it.
- `Troupe.Bench.Model.measure/2` counts `request.system` only, so the offline bench's
  `system_bytes` leaves out the task list the log counts; `Request.system_text/1` has both.

Found by the chunk 17 fixers, 2026-10-04.

### D66 - Compaction and cut tool output: small leftovers (medium)

- The `explore`, `answer`, `ask` and `librarian` profiles don't offer `read_output`, but
  `grep`, `git_read` and `web_fetch` cut long output with a marker naming a `read_output`
  call: those agents are told to make a call they can't. #389's stubs are skipped for such
  profiles (Decision 771); the markers are not. Cuts come sooner since the default limit
  became 32 KiB (Decision 781).
- `Troupe.SessionCase` could turn the stand-in provider's strict tool-call pairing on by
  default, and its refusal of tool blocks in a request without tools too: the whole core
  suite passes with both (Decisions 774 and 779).

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

### D69 - Anthropic thinking: what #396 left (low)

- Unchecked: reasoning blocks go to the compaction summariser unchanged, so when the small
  model is a different Anthropic model it receives another model's signed thinking blocks.
- Opus 4 and 4.1 cap output at 32K tokens, but `xhigh` (and now `max`) asks for
  `max_tokens` 36,864 (`put_thinking`), which they refuse.
- The catalog records each model's thinking form, not which effort levels it takes: a
  model that lacks one would refuse it (Decision 780's refusal words name the setting).
- Unchecked: whether a gateway speaking Anthropic's API passes `output_config` on.

Found by the chunk 18 fixers, 2026-10-05.

### D70 - The live bench and the model list: small leftovers (low)

- A live run that fails before its first model call reports `FAILED, 0 model calls` with
  `error` and `stop_reason` both null: nothing says why. A model nothing lists or prices
  (here `--model openai/qwen3-235b`) still ran all 30 runs; it could be refused before the
  first, as `troupe doctor` does since #412.
- With `provider: openai` and no named providers, `troupe bench --live --model
  openai/qwen3-235b` runs against `openai/openai/qwen3-235b`; `--model qwen3-235b` works.
  `docs/user/bench.md` shows `--model gateway/model-b` for a named provider only.
- `troupe-daemon models` has no `--json`, so an install without the TUI has no JSON form.
- The summariser's `prompt_bytes.tool_results` now reads 0: its results are text inside
  `conversation` (Decision 779).
- `Troupe.Agent.Headroom.tokens/1` formats with floats and prints `1.0e3k` for 999,950 to
  999,999 tokens and `1.0e3M` at a billion (the TUI's own figures were fixed in #418).
- The fake worker behind `pnpm fake` and the desktop tests
  (`clients/gui/packages/client/test/support/worker.ts`) ends a turn without `turn`, so the
  fake deployment never shows the turn line.
- `cut_output`'s budget (36,000 bytes) is a tenth over the measured cut, so the limit
  could creep to about 35 kB unnoticed; the old budget had about 2% headroom.

Found by the chunk 18 fixers and the coordinator, 2026-10-05.

### D71 - Private sessions after 0.8.4: what is left (medium)

- The TUI has no way to unlink a daemon, so a second person on the same OS account can't
  take it over from the terminal.
- A person moved to another subject claim (Decision 755) has the sessions made under their
  old subject left alone at their next link (Decision 784); no client hands a daemon a
  token under another subject today.
- A claim on a copy that diverged from the plane's is refused (`diverged`), with no way to
  restore the plane's copy over the local one first.
- The desktop app's session view header says where a session runs, not how its sealing
  stands; only the list says it.

Found by the chunk 19 fixers, 2026-10-05.

### D72 - Model calls, naming Troupe, and what a stopped call leaves: small leftovers (low)

- A pod can't turn `identify` off: no `WorkerProfile` field and no environment variable
  carries it.
- The model listing and the catalog's refresh (`/v1/models`, LiteLLM's `/model_group/info`)
  and `troupe doctor`'s key check still send Req's own User-Agent.
- `troupe bench --live` sessions name their client `other` (the bench starts sessions in
  the VM, with no connection); `bench` would say what they are.
- #419's documented set of `x-troupe-*` headers for LiteLLM's `extra_spend_tag_headers` is
  not there.
- A summary that fails (refused, timed out or crashed) is never written to the log, so a
  stopped summariser's usage is counted live only (Decision 788).
- `Session.Summary.fold` counts tokens and cost from `llm_response` only, leaving out the
  summariser's call on `compacted` and a stopped call's `stopped`, so a session summary's
  totals disagree with the listing.
- Unchecked: `cancel_everything` doesn't reset `compact_reason`, `compact_prompt` or
  `compact_resume`, so a threshold compaction after a cancel while compacting could log a
  stale reason.
- `Provider.start_stream/4` monitors the stream task and drops the reference, and the agent
  monitors it again: every call leaves a `DOWN` that `common/4` drops.
- A stopped call's ledger row gets a made-up request id, since only `finish/1` reads the
  gateway's headers, so it can't be joined to the gateway's record of the request.

Found by the chunk 19 fixers, 2026-10-05.

### D73 - Test hygiene from the 0.8.4 work (low)

- A gateway loopback test logs a `FunctionClauseError` from `Troupe.LLM.Fake.render(%{text:
  "done"}, ...)`; it fails nothing.
- The TUI tests' `FakeRemote` HTTP `/rpc` can only answer errors without `data`.
- `Private.resume/1` now always asks `Plane.subject`, so a link's resume task that outlives
  a daemon test's teardown logs a task exit.

Found by the chunk 19 fixers, 2026-10-05.

### D74 - Model calls: what the 0.8.5 work left (low)

- `qwen3-235b` never puts two tool calls in one response (179 of 179 in the live bench), so
  `build.md`'s "one `delegate` call per item, all in the same turn, so they run
  concurrently" can't happen on it. The OpenAI-compatible adapter sets no
  `parallel_tool_calls`.

Found by the chunk 20 fixers, 2026-10-06.

### D75 - Decision files: small leftovers (low)

- `symbols:` in a decision's front matter is type-checked but not checked against the code,
  as #437 had it optionally.
- Gists were drafted from titles: a long title gives a gist cut off with "…", which reads
  badly in `mix troupe.decisions --for`.
- Several migrated bodies run a `- ` list straight on from a paragraph with no blank line
  (683 and 789 among them): GitHub renders it, the docs site's Markdown probably doesn't.
- Twelve root decisions govern a component directory rather than files (92, 112, 253, 256,
  257, 289, 461, 497, 498, 675, 708, 730), and the 51 TUI decisions no citation pointed
  at govern `clients/tui` as a whole.

Found by the #437 fixer, 2026-10-06.

### D78 - Instruction files and the brief: what #123's slice left (low)

- A nested instruction file reaches the turn after its directory is first opened, not the
  same turn; attaching it to the tool result that opened the directory would, as some
  tools do.
- `context.get` for a sleeping session lacks the conversation's focus (asking the agent
  would wake it), so it lists fewer nested files than the prompt had.
- `context.get` reads `Path.expand(session.workspace)` where the prompt uses the
  workspace's real root, so on a workspace reached through a link (macOS `/tmp`) the two
  name different paths.
- A brief left out as outside the repository reads as absent in `memory.get`, so a client
  with `memory_auto_refresh` may start a librarian whose writes are then refused; the run
  counts as a try and holds the next off for `memory_max_age_days`.

Found by the #123 fixer, 2026-10-06.

### D79 - `troupe-daemon open` and the loopback: what #449 left (medium)

- The GUI reads `#daemon=` only when the page loads; a fragment set in an open tab is not
  taken (`open` always opens a new one).
- The loopback admits an upgrade that carries no `Origin` header (the token is still
  required).

Found by the #449 fixer, 2026-10-06.

### D80 - Small leftovers from the 0.8.6 work (low)

- A write signed just before another device claims a private session and sent after it
  still lands: a presigned URL can't be withdrawn (Decision 800). The window is one object.
- Nothing tests that `Private.take_over/2` stopping a sealer still running at the old
  epoch has that sealer's last seal refused.
- The TUI's model menu (`Troupe.Settings.choices/3`) still shows the default window for a
  model nobody serves; it doesn't read the catalog's record of what each provider serves.
- The VS Code Settings view, opened on a configuration that doesn't load, doesn't ask again
  when the file is saved; only Refresh does.

Found by the chunk 21 fixers, 2026-10-06.

### D81 - CI after the move to Ubuntu 26 (low)

- `windows-latest` and `macos-latest` are still unpinned in the VS Code matrix and the
  desktop Windows build.
- The desktop Linux build stays on `ubuntu-22.04` as the glibc floor; it needs a new answer
  when GitHub retires that image.
- The cluster suite stays on `ubuntu-24.04`, untried on 26 (`gh workflow run nightly.yml
  --ref <branch>` after changing its label tries it).
- A Windows daemon build once spent 29 minutes in `mlugg/setup-zig` and passed; the new
  15-minute timeout would fail such a run.

Found by the chunk 21 fixers, 2026-10-06.

### D82 - Thinking on Anthropic's newest models: what #427 left (low)

- With no `reasoning_effort`, `max_tokens` (8,192 by default) isn't raised for a model that
  thinks unasked, and its thinking counts against it, so a long reply can be cut short.
- With no effort, those models' thinking reaches no client: `display` defaults to omitted.
  Sending `display: "summarized"` would show it, at the same cost, but adds a field nobody
  asked for (Decision 805).
- A gateway's own name for one of these models isn't known to think unasked (the model
  listing has no field for it), so its thinking blocks are still dropped unless an effort
  is set.
- Unchecked: whether Troupe ever sends a forced `tool_choice` (`any` or a named tool),
  which Opus 5.5, Sonnet 5.5 and Fable 5.1 refuse.
- The conversation-prefix binding of thinking blocks is #465.

Found by the #427 fixer, 2026-10-06.

### D83 - The plane host's policy: what #460 left (low)

- The app's `connect-src` allows any `https:` and `wss:` address, because sign-in reaches
  the identity provider and remote sessions reach each worker's host, both known only at
  run time. A chart option naming the deployment's provider and workers domain could narrow
  it (Decision 803).
- Plane pages keep `style-src 'unsafe-inline'` and Google's font hosts: the front page's
  `<style>`, the sign-in pages' style attributes and LiveView's patched styles need it.
  Moving the page CSS to a file, attributes to classes, and the fonts onto the plane would
  drop both.
- Phoenix's own error page, for a request refused before the endpoint's plugs run (a body
  the parser rejects), goes out without the header; it carries no script.
- The GUI image's nginx configuration is only exercised when the image is built on `main`;
  a `RUN nginx -t` in the Dockerfile's runtime stage would catch a broken one at build.

Found by the #460 fixer, 2026-10-06.

### D84 - Erasures and the daemon's start: small leftovers of 0.8.7 (low)

- A team session whose key is gone but whose pod couldn't delete every object, or that had
  no healthy pod, has its objects tried again only when a pod of its profile next enrols;
  erasing it again returns the existing tombstone (its key is retried every five minutes
  since Decision 811).
- Two acknowledgements of the same private session at once run two background deletions of
  its prefix (harmless: the second finds what is left).
- On Windows, a program the VM starts through `System.shell` inherits the VM's handles: a
  client other than `troupe-daemon open` that starts a daemon could hand it a caller's
  output pipe (Decision 802 fixed it for `open`).
- `troupe-daemon open` waits 15 s for the daemon it started, too short on a loaded Windows
  machine (one came up after 41 s).
- `open` opens `<plane>/app/` when the plane says it has no app (`plane.app: null`), a 404;
  it could say so instead.
- `ReaderLogTest`'s "a read whose reader meets an activation as it writes" still awaits 5 s
  behind the same lock and backoff Decision 801 measured; `Restore.with_log/2`
  (`:global.trans`) can leave a waiting reader asleep up to 8 s after the lock frees.
- `/context` prints on the TUI's single status line, clipped at the terminal's width; a
  repository with several files left out won't fit (TUI Decision 148).

Found by the chunk 22 fixers, 2026-10-06.

### D85 - Instruction files and Cursor rules: what the 0.9.0 slices of #123 left (low)

- `.cursor/rules` is read as far as Decision 809 goes: not `.mdc` files in subdirectories of
  `.cursor/rules`, not `.md` rules, not a rule's `@` file references, and a glob's `[...]`
  character class is taken literally. Whether Cursor takes a nested rule's globs from its
  own directory (809's choice) or from the root is unchecked.
- `troupe instructions check` takes every file under the workspace as its focus; how that
  attaches glob-scoped Cursor rules, and how a root rule compares with the root's
  `AGENTS.md`, is untried now that the loader reads them (Decision 810 predates 809).
- Left out of the check by its rule of preferring a missed finding to a false one: an
  `install` subject, whether a command's subcommand exists (#123's item 14), and files so
  long the budget will cut them (the loader already marks them `trimmed` or `dropped`).
  `troupe-daemon` has no `instructions check` of its own.
- On this repository the check flags `clients/tui/CLAUDE.md`'s lines 39 and 83 (example
  paths it reads as real ones) and, on Windows, line 20 (`mise` lives in WSL here);
  rewording the two examples would let it run quiet in this repository's CI.

Found by the chunk 23 fixers, 2026-10-07.

### D86 - The TUI's themes and mark: small leftovers (low)

- Limelight's `border.focus` token is its reserved lime, so the desktop app's focus ring in
  Limelight uses the colour that should mean only "a person is needed" (the TUI falls back
  to `text.link`, Decision 807). The themes' `$meta` is stale: Footlight's description says
  it is the default, and Signal still has `default: true`.
- The status line says "idle" while a window's mark turns, because `attention_summary`
  counts only needs-you, done and failed.
- Needs-you has two glyphs: the window title's blinking "▶ needs input" and the observer
  page's "▶ you", against the corner's ◑.
- A session on a plane has no settings door (`Client.settings/1` returns an error), so it
  always draws in Afterglow; it could read the local daemon's `config.get`.
- The fake provider's JSON scripts can't express `delay` or `endless` steps, so a packaged
  smoke test can hold a window "working" only with a slow shell tool.

Found by the #228 fixer, 2026-10-07.

### D87 - The VS Code extension after #378's commands (low)

- The extension passes `--workspace` as `folder.uri.fsPath`, with a lowercase drive letter
  on Windows (`c:\`), where a hand-typed terminal gives `C:\`; if a session's workspace is
  matched case-sensitively, Resume Last Session Here misses a session started by hand.
  Untested.
- "Ask Troupe About This File" with Troupe already running in the folder's terminal only
  reveals it and says what to type; putting the path into a running TUI would need a way in
  through the daemon.
- With a shell the extension can't quote for (nushell, or WSL's launcher as the Windows
  default), Doctor's and Open Settings' output closes with their terminal; a `.cmd` troupe
  under PowerShell 7 gets the batch file's quoting.
- `scripts/licences.exs --check` crashes with a `File.Error` unless `clients/gui`'s
  `node_modules` are installed, even for a change that doesn't touch the GUI, and it needs
  `clients/tui`'s deps fetched too.
- After VS Code is closed and opened again, it brings each Troupe terminal back as an idle
  shell tab with the old output replayed: a leftover tab, not a second Troupe.
- When the TUI fails to start from the "Troupe" terminal profile, its own error is lost:
  no shell runs under it, and VS Code reports only the exit code.
- In a window of several folders, "Create New Terminal (With Profile)" asks for a folder
  but does not pass it to an extension's profile, so with no editor open the person is
  asked twice.
- `restore` waits up to 5 s for the terminals' process ids before the startup decision,
  however many terminals there are.

Found by the #378 fixers, 2026-10-07 and 2026-10-08.

### D88 - Erasure after #470: small leftovers (low)

- `session.redeem` records the redemption in the audit log and marks the share redeemed
  before it refuses an erased session, so a refused redemption still leaves both.
- A tombstone whose session row was deleted outright is skipped by the erasure pass, which
  joins on sessions.
- The plane names a team session's key by the team's current name; if a team could be
  renamed, the session's manifest would be the safer source. Unchecked whether renames
  exist.
- Tests of the key manager other than the erasure tests still run under OpenBao's root
  token, which hides every policy refusal; Decision 811's tests use the credentials
  `Troupe.KMS.Policy` writes for each component.
- `InstructionsPromptTest`'s `await_event` waits 5 s and times out under load (2 runs in 6),
  and `LocalPricingTest` failed once in a full core run; both pass alone.

Found by the chunk 23 fixers, 2026-10-07.

### D89 - Shell mode and tool output after #486 and #493 (low)

- The desktop app doesn't call `shell.run` and doesn't know `user_shell`, so it probably
  draws the `user_input` from `shell` as a line the person typed (unconfirmed). The A2A
  facade folds that note into a task's history as a user message, as it does harness
  notes.
- `!` typed in a window's input box still goes to that window's agent (TUI Decision 152:
  an answer may start with `!`). Neither the palette nor the status line mentions `!`;
  only the CLI reference does.
- An interactive program (`vim`, `ssh`, `less`) is not detected: it waits on the empty
  stdin until the timeout or Esc, and the block's title says "no stdin". Untried: whether
  `!ssh`, or the agent's `shell`, in a TUI serving its own embedded harness on Windows
  reaches the TUI's console.
- The TUI has no up-arrow history, so shell lines can't be kept apart from prompts there.
- `fs_changed` and watch events carry file paths, which on Linux need not be UTF-8; #493
  replaced invalid bytes in tool results only. The shell tool under PowerShell (no bash on
  a Windows host) was not tried with invalid bytes.

Found by the #486 and #493 fixers, 2026-10-08.

### D90 - Sessions after `/new` and `troupe resume` (#484) (low)

- The daemon refuses to fork a private session (`invalid_params`, `private`).
- The desktop app greys `/new` and `/back` as "not in the desktop app yet"; they could map
  to its New-session flow and session list.
- While a plane's session is on screen, the TUI's `workspace` is the label `plane/<sid>`.
  `/sessions` and `/new` use the window's own directory; other features keyed on the
  workspace may still use the label.
- The client journal gains a root "spawned /build" line every time a session is opened.
  Headless resume no longer prints them, but they accumulate.
- The TUI's `FakeRemote` answers `commands.list` without aliases, so `/resume` on a
  stand-in remote session is dispatched to the plane as a profile name; a real pod's table
  has them.
- `scripts/verify-local.ps1`'s `Stop-OurDaemon` stops every process running from the
  install directory, which includes a person's own installed daemon if one is running.

Found by the #484 fixer, 2026-10-08.

### D91 - Repository commands after #371 (low)

- The TUI reads the command table only when a session opens (Decision 763), so after a
  command file is edited its palette shows the old prompt until the session is reopened.
  The daemon sends the new prompt, and asks again.
- A harness question with no tool call behind it (the command question, and #60's MCP
  trust question) is closed in both clients by a `cancelled` on root, but the daemon's
  asking task keeps waiting: the session row counts a pending question nobody can answer,
  and if the session sleeps with it open, a later answer is recorded and nothing is sent.
- The desktop app's approval panel puts `.approval .evidence` in the same scrolling flex
  column that squeezed a question's preview to one line, so a long approval's evidence
  probably shrinks the same way in a short window (unconfirmed; only the question's was
  fixed).
- `pnpm fake`'s fake worker lists command bodies but doesn't ask the command question;
  only the fake daemon does.

Found by the #371 fixer, 2026-10-08.

### D92 - Thinking blocks and the prompt prefix, what #465's measurement found (medium)

- Today's resend (Decision 805) and the `drop_block` beta both leave the stale thinking
  blocks in Troupe's history, so on an enforced account every later call of the session
  meets the mismatch again until a compaction: two requests a call today, or every block
  dropped on every call with `drop_block`. Once a call is refused or reports drops,
  sending the leading run of pre-change blocks no more would end it (Anthropic accepts a
  leading run removed oldest first).
- Decision 793 offers the todo tools once a list exists or after 10 calls, which changes
  `tools` mid-turn: that invalidates every kept block on the newest models and the cache.
  `llm_request.tools_changed` counts it.
- Unchecked: whether `split_for_compaction` strips thinking from the tail compaction
  keeps; Anthropic's documentation says a kept tail breaks the binding unless it does.
- With `system_prompt: stable`, the turn contexts live in the agent's state, not the log,
  so an agent restarted mid-session edits its history once.
- Unchecked: whether LiteLLM carries `anthropic-beta` into Amazon Bedrock's
  `anthropic_beta` body field.

Found by the #465 fixer and the coordinator's live run, 2026-10-08.

### D93 - Tab completes a command name without its slash (low)

`complete_command/2` in `clients/tui/lib/troupe/ui/tui/server.ex` (TUI Decision 38)
completes a command name on a line with no slash: "mer" and Tab give "merge ", "hel" and
Tab give "help ", and "merge 2" and Tab give "merge code-1". Since #496 a line without a
slash goes to the agent, so Enter then sends those words to the agent instead of running
the command. The palette's way ("/", "mer", Tab) still gives "/merge " and runs it.
Putting the slash in when Tab completes a command name, or offering no command names on
a line without one, would end it.

Found by the #496 fixer, 2026-10-09.

### D94 - The installers after the start-at-login step (#504) (low)

- `install.ps1` has no `[CmdletBinding()]`, so an unknown or misspelt switch is taken into
  `$args` and ignored without a word; `install.sh` refuses unknown arguments. An installer
  from before #504 given `-StartAtLogin` ignores it the same way.
- `scripts/check-installers` and `scripts/check-installers.ps1` run by hand only; CI
  doesn't run them.
- `docs/quick-start.md` and the release notes templates in `release.yml` and
  `prerelease.yml` don't name `--start-at-login` (`-StartAtLogin`).

Found by the #76 installer fixer, 2026-10-09.

### D95 - Setup after `troupe setup` (#513) (low)

- `troupe config`'s line-by-line question about starting at login (`ConfigSetup.at_login/2`)
  asks without checking whether an entry exists; the installers and the setup screen
  don't ask then.
- The desktop app's Daemon step offers "Only when an app needs it" when a login entry
  exists, and choosing it removes the entry, where the installers and the TUI keep it.
- The gateway's `setup.answer` for `finish` builds the first session's command id from
  `params["command_id"]` (`first_session/3` in `dispatch.ex`), so a client that omits it
  makes the handler raise. Every client sends one today.
- The setup screen's summary shows the project path as the TUI expands it on Windows
  (`c:/Users/...`, forward slashes).
- The daemon holds one setup flow for every client, so opening the TUI's screen resets a
  flow the desktop app left half-way.

Found by the #76 setup fixer, 2026-10-09.

### D96 - `troupe doctor --bench` and the offline bench (#505) (low)

- None of the offline scenarios calls the `shell` tool and doctor has no shell line, so the
  most fragile Windows tool path (Git for Windows' bash, Decision 776) is checked by
  neither `troupe doctor --bench` nor CI's bench.
- The bench's scripted model has no price, so every `troupe bench` and `troupe doctor
  --bench` writes five "fake-model has no price" warnings into the person's own
  `<state>/troupe.log`.
- `doctor --bench` has no overall deadline: a hung harness waits up to 60 s per wait in
  each scenario.
- It runs in `troupe`'s own VM, so it doesn't exercise a running daemon (the desktop
  app's, which TUI sessions use when it answers), and `troupe-daemon doctor` has no
  `--bench`.

Found by the #390 fixer, 2026-10-09.

### D97 - MCP servers after `headers` (#507) (low)

- The MCP trust fingerprint in `<state>/mcp-trust.json` hashes the resolved `env` values
  and now the header values: a truncated sha256 of secrets in the state directory, and a
  rotated token asks about a workspace's server again.
- OAuth discovery's unauthenticated probe (`probe/1` in `Troupe.MCP.OAuth`) sends none of
  the entry's headers, so a server behind a gateway that wants a static key as well as
  OAuth fails discovery.
- Importing from opencode skips a server whose values use `{file:path}`.
- The TUI's `/mcp` page and the desktop app's panel show neither header nor `env` names,
  though `mcp.list` now carries both.

Found by the #60 fixer, 2026-10-09.

### D98 - Onboarding after #516's first slices (low)

- Onboarding proposes only a repository's files: the person's own `~/.claude/agents`,
  `~/.claude/commands` and opencode's global agents (`target: :user`) are not proposed,
  nor opencode's `command` block, its legacy `.opencode/mode(s)/` files, or files in
  subdirectories (listed as skipped).
- A rule that denies a tool for some uses only (Claude Code's `Read(./.env)`) becomes
  `ask` for the whole tool, since Troupe allows a tool whole or not at all: that `.env` is
  then asked about rather than refused.
- An opencode `provider/model` whose provider isn't in `config.yaml` is sent whole to the
  session's provider.
- A command's positional arguments aren't filled: Troupe fills only `$ARGUMENTS`
  (Decision 763), while Claude Code counts `$0`/`$ARGUMENTS[0]` from zero and opencode
  `$1` from one; the importer notes them. #516's table says they already match.
- The librarian's prompt still says `CLAUDE.md`, `GEMINI.md` and Copilot's file are in
  every prompt, and doesn't mention `onboard_write` (#516's slice 2).
- `troupe onboard` calls a source's `proposals/2` and then `skipped/2`, so the agents and
  commands source surveys the files twice a run.

Found by the #516 fixers, 2026-10-09.

### D99 - `.agents/` and skills after #518 (low)

- The TUI's `/mcp` page shows the new skill layers (`agents`, `user_agents`) as `[session]`,
  from the fallback of `layer/1` in `clients/tui/lib/troupe/client/daemon.ex`.
- The desktop app's "Servers and skills" panel takes every skill not in the workspace layer
  for the person's own when removing it, so removing an `.agents` skill fails with "no
  skill named".
- Neither client shows `skills.list`'s `skipped`.
- An unreadable `.agents/skills/*/SKILL.md` is dropped with no entry; it doesn't show in
  `skills.list`.

Found by the #516 fixers, 2026-10-09.

### D100 - MCP import after #520 (low)

- Linking (`include`) an `opencode.json` yields no servers: `Troupe.MCP.Local.servers_of/2`
  reads `mcpServers`, `servers` and `mcp_servers`, not opencode's `mcp`. A copy works.
- `agents.list` lists primary agents only, so the note on a `.troupe/agents` subagent whose
  `auto` waits for trust reaches no client.
- The desktop app's import hint and the `/mcp import` row of the CLI reference don't
  mention Codex's `config.toml`.
- A linked file's import warnings (Codex's `enabled_tools is not carried`) repeat on every
  `mcp.list`.
- Codex's top-level `scopes`/`auth` aren't folded into Troupe's `oauth`.
- An imported `${HOME}` becomes `{env:HOME}`, which refuses the server on a machine where
  `HOME` isn't set (Windows).

Found by the #516 fixers, 2026-10-09.

### D101 - Pods and worktrees after #523 (low)

- The TUI shows the `files_skipped` event as a bare line (`files_skipped files=[1]`).
- A worktree reads its main checkout's committed agents and skills, but not its commands,
  workflows or `mcp.json`.
- `TroupePolicy` can't forbid a profile's `repositoryOverridesBundle`.

Found by the #516 fixers, 2026-10-09.

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
| D65's first item - cache writes over an OpenAI-compatible gateway were priced as fresh input | #396, PR #420 |
| D65's fifth item - neither the desktop app nor a headless run showed what a turn cost | PR #418 |
| D59's first item - an erasure left the object versions past the first 1,000 | PR #429 |
| D59's second item and D61's first two - the clients showed a private session as a local one, and none could claim one | PR #431 |
| D69's first item - a model call past its timeout was never stopped, and its usage not counted | PR #435 |
| D69's second item - Anthropic's newest models think unasked, and that thinking is dropped on replay | #427 |
| D70's third item - the task list takes model calls of its own on `qwen3-235b` | #428, PR #445 |
| D65's first item - a rewritten task list made the next call write the conversation to the cache again | #389, PR #447 |
| D70's fourth item and D76 - the model list gave a window for a model nobody serves, and the editor hid a configuration's errors | PR #455 |
| D77 - CI on GitHub's hosted runners (the native builds had timeouts already; every build job has one now, and the runners are Ubuntu 26) | PR #456 |
| D66's first item - a summariser call that never answered kept the agent compacting | #404, PR #421 |
| D71's first two items - an erasure counted a refused delete as done, and a large one timed out the daemon's call | PR #467 |
| D74's first two items - a 5xx past its retries said only its status, and an Anthropic stream error showed unmasked | #427, PR #464 |
| D78's first and fifth items - the Copilot file counted in every directory, and `/context` gave no reason for a file left out | PR #471 |
| D79's first two items and its fifth - a Windows daemon died with its terminal, `open` guessed the app's address, and the plane host had no policy | PR #468; #460, PR #466 |
| D81's last item, D73's first and D8's second - `RestartTest` and `AutospawnTest` started slowly enough to fail | PR #469 |
| D84's first item, the key half - a pod could never destroy a team session's key, and the plane marked the erasure done (what is left of it stays in D84) | #470, PR #480 |
| D43's `troupe resume` item - with no id it opened the newest row, which could be a branch or an empty scratch session | #484, PR #495 |
| D62's first item - uninstalling didn't run `troupe-daemon login off`, leaving the login entry pointing at nothing | #76, PR #504 |
| D49's import item - importing MCP servers from other tools dropped their `headers` | #60, PR #507 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
