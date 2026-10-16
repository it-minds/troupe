# Known defects

Defects found in passing, while working on something else, and not fixed yet. Each has a
place in the code, what goes wrong and who saw it. An entry leaves this page when an issue
or a pull request takes it; the line that remains says which one. Every entry but D8 (the
flaky tests, which have their own pass) was checked against the code of 0.15.0 on
2026-10-12 (#422): what was fixed went to the table at the end, and what was said twice is
said once.

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
  fails now and then; it passes alone.
- On the 0.6.3 tip under full load, the worker's `ReaderLogTest` "a log an activation has
  taken over" and the gateway's `RestartTest` (once with a `FunctionClauseError` in
  `Troupe.LLM.Fake.render/2`) each failed once; both pass alone.
- The worker suite's plane-backed tests share `troupe_plane_test` with the plane suite, so
  running both at once can deadlock in Postgres (`40P01` in `plane_link_test.exs`).
- The gateway suite prints `erl_child_setup: failed with error 32 on line 284` a few
  times, with or without failures (probably a port child writing to a closed pipe).
- `apps/troupe_gateway/test/troupe/gateway/restart_test.exs` `create/2` never stops the
  sessions it creates. They live in a second daemon OS process, so they probably don't
  leak into the test VM the way the two fixed in chunk 6 did (unconfirmed).
- The desktop app's tests time out now and then when the machine is busy (goal-loop,
  local-mode, onboarding, command-palette); local-mode sends before its session is
  attached ("not attached").
- Under full load, two of the gateway's `PrivateTest` tests ("a seal with nobody linked",
  "carrying on another person's link") failed now and then, beside `session_ids_test` and
  `daemon_test`; both pass alone. Core `Session.ShellTest` "a restart puts back a note ...
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
- Under full load, core `DoctorTest`'s bench line fails now and then; it passes alone.
  `Session.ShellTest` "a command that ends mid-turn ..." once found its workspace gone
  ("spawn: Could not cd").
- `OnboardWriteTest` once answered another file's refusal ("`.claude/agents/reviewer.md` is
  not there") for `nowhere/AGENTS.md`: order or shared state, not load.
- Runs on one machine share WSL's `/tmp`: `DoctorCLITest`'s `bench_dirs() == []` fails
  while another run has a `/tmp/troupe-bench-*` directory.
- A pull request into a chunk branch builds the TUI but doesn't run its tests, so a TUI
  regression is first seen on the chunk's pull request into `main`.
- Seen failing now and then under full load after D117 (Decision 848), passing alone, and
  not seen in chunk 32's load runs: core `WatchSessionTest`, `RememberFactsTest`
  ("README.md is not there"), and the gateway's `LoopbackTest` "a refused upgrade is
  logged at warning level".
- The core and TUI suites load every module before the first test since chunk 32
  (`apps/troupe_core/test/support/preload.exs`), which took most load timeouts away. What
  is left:
  - with 64 cases on 16 CPUs that as many busy loops share, a core run still has about a
    dozen first turns past the default five seconds (`IdentifyTest`,
    `UnattendedApprovalsTest`, `UnseenTest`, `LocalPricingTest` and others), where it had
    54;
  - at the default 64 cases while another suite runs, now and then `CutShortTest`'s
    `wall_clock` case: the root's own four seconds run out under load, so it waits on a
    budget question nobody answers and is never idle;
  - and `CrashLoopTest`, whose session was not down within five seconds of the kill:
    probably three slow restarts no longer fit `Agent.Node`'s five-second window, so it
    goes on restarting (unconfirmed).
- `Troupe.BenchTest` measures the tool definitions of the test build, which registers four
  test-only tools (about 582 bytes), so the budget gates a list nobody ships and `mix
  troupe.bench` in dev reads that much lower.

Found by the #59, #87, #97, #98 and #99 fixers (2026-09-22/23), in chunks 3 to 7, and by
the chunk 24, 26 and 27 fixers (2026-10-08/11).

### D23 - Small leftovers (low)

- The config schema's `$id` (`https://troupe.dev/schema/config/v1.json`) isn't served, so
  an editor can't fetch it.
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

Found by the chunk 5 fixers, 2026-09-26.

### D30 - Two sources for the brand's assets (low)

- `scripts/brand-icons.py` (Pillow) draws the plane's `favicon.ico` and
  `apple-touch-icon.png` with a second rasteriser; `pnpm icons` (PR #210) could draw them
  from the same mask so the plane and the desktop app match.
- `clients/gui/docs/design/afterglow.dc.html` and `example.dc.html` reference
  `./support.js`, which is not in that directory (the themes' comps have theirs beside
  them).

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
- `model.ex` highlights code with syntect's dark-only `base16_ocean_dark`, so code keeps
  dark-theme colours on a light terminal.
- Dead since the daemon move: a window's `summary` and `diff_stat` fields, which nothing
  feeds (TUI Decisions 39 and 42's diff stat, D113).

Found by the fixers of PRs #234, #239 and #241, 2026-09-27.

### D37 - Small leftovers from the 0.6.1 work (low)

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
- Subagents get no `started_at` in the TUI (a subagent's window is made with none), so the
  observer measures their time from the window's start.
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
- `Session.Log`'s moduledoc cites `troupe ctl verify`, which no client has (#628 makes it);
  the TUI's tile headline reads `needs_input ▶ needs input`.
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
  discovery slot, and a forced stop leaves a stale file (D23 has `verify-local.ps1`'s).
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
- The TUI's settings help says a `next_run` setting applies "the next time the TUI
  starts"; most apply to the next session.
- Two clients saving one file at the same moment: the last write wins (Decision 761).
- A command file that shadows a built-in is skipped with a warning logged on every
  `commands.list`, so each time a palette opens.
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
- `troupe --workspace DIR` with a directory that doesn't exist is unchecked; the VS Code
  extension always passes a real folder.
- The TUI suite shares one embedded daemon, which answers a replayed `command_id` with the
  first answer: two tests using the same literal id make the second a silent no-op. Tests
  should take ids from `RPC.command_id()`.

Found by the chunk 16 fixers, 2026-10-04.

### D65 - What a turn costs: what #389 left (medium)

- Unchecked: whether a gateway speaking Anthropic's API passes `cache_control` on.
- A waited-for subagent's spend is added to the parent's turn live only. A cancel or a
  parent restart in the middle of the turn loses what it reported; the delegation's own
  `tool_call_completed` could carry it. A background child is charged when it is stopped
  or cancelled (Decision 853), though not across its parent's restart (D118).
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
- `dev-check.yml` doesn't run `mix troupe.bench` (about 10 s), so a change past a budget
  shows only on the chunk's pull request into `main`.
- Two `scripts/ci` runs from different worktrees share the toolbox's Docker volumes and
  can break each other.

Found by the chunk 17 fixers and the coordinator, 2026-10-04.

### D69 - Anthropic thinking: what #396 left (low)

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
- `Private.resume/1` now always asks `Plane.subject`, so a link's resume task that outlives
  a daemon test's teardown logs a task exit.

Found by the chunk 19 fixers, 2026-10-05.

### D74 - Model calls: what the 0.8.5 work left (low)

- `qwen3-235b` never puts two tool calls in one response (179 of 179 in the live bench), so
  the `build` agent's "Independent items go to subagents, all in one turn"
  (`priv/agents/build.md`) can't happen on it. The OpenAI-compatible adapter sets no
  `parallel_tool_calls`.

Found by the chunk 20 fixers, 2026-10-06.

### D75 - Decision files: small leftovers (low)

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

- `.troupe/rules` (where Decision 828 moved 809's reading) reads no rules in its
  subdirectories, no `@` file references, and takes a glob's `[...]` character class
  literally. Whether a nested rule's globs should come from its own directory (809's choice)
  or the root is unchecked against Cursor, whose rules onboarding brings in.
- `troupe instructions check` takes every file under the workspace as its focus; how that
  attaches glob-scoped rules, and how a root rule compares with the root's `AGENTS.md`, is
  untried.
- Left out of the check by its rule of preferring a missed finding to a false one: an
  `install` subject, whether a command's subcommand exists (#123's item 14), and files so
  long the budget will cut them (the loader already marks them `trimmed` or `dropped`).
  `troupe-daemon` has no `instructions check` of its own.
- This repository's `clients/tui/CLAUDE.md` is no longer read by Troupe sessions (Decision
  828): onboard it, or rename it `AGENTS.md`.

Found by the chunk 23 fixers, 2026-10-07; brought up to date by the chunk 26 fixers.

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
- Tests of the key manager other than the erasure tests still run under OpenBao's root
  token, which hides every policy refusal; Decision 811's tests use the credentials
  `Troupe.KMS.Policy` writes for each component.
- `InstructionsPromptTest`'s `await_event` waits 5 s and times out under load (2 runs in 6),
  and `LocalPricingTest` failed once in a full core run; both pass alone.

Found by the chunk 23 fixers, 2026-10-07.

### D89 - Shell mode and tool output after #486 and #493 (low)

- The desktop app has no shell mode: it doesn't call `shell.run` and doesn't know
  `user_shell`, and shows the `user_input` from `shell` as the person's entry, tagged "via
  shell". (The A2A facade folds that note into a task's history as a user message: D118's
  ACP and A2A item.)
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
  leading run removed oldest first). Since Decision 871 a tool that comes or goes changes
  the prefix only at a turn boundary, but each change there (D124's turn's tools) still
  costs every later call one refusal.
- On a model that does not bind its thinking, Decision 793 still offers the todo tools once
  a list exists or after 10 calls, which changes `tools` mid-turn and costs a cache write
  (`llm_request.tools_changed` counts it). A model that binds has them from the first call,
  and a compaction's kept tail goes without its thinking there (Decision 867).
- A log written before 0.13.0 has no `turn_context_block` to fold (Decision 863): a session
  that ran `system_prompt: stable` then sends its first call after a resume without the
  turn contexts it had put, and one that ran 0.12.0's `per_turn` default changes its system
  prompt at that call; once either way.
- Unchecked: whether LiteLLM carries `anthropic-beta` into Amazon Bedrock's
  `anthropic_beta` body field.

Found by the #465 fixer and the coordinator's live run, 2026-10-08.

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
- `troupe onboard` calls a source's `proposals/2` and then `skipped/2`, so the agents and
  commands source surveys the files twice a run.

Found by the #516 fixers, 2026-10-09.

### D100 - MCP import after #520 (low)

- The desktop app's import hint and the `/mcp import` row of the CLI reference don't
  mention Codex's `config.toml`.
- A linked file's import warnings (Codex's `enabled_tools is not carried`) repeat on every
  `mcp.list`.
- Codex's top-level `scopes`/`auth` aren't folded into Troupe's `oauth`.
- An imported `${HOME}` becomes `{env:HOME}`, which refuses the server on a machine where
  `HOME` isn't set (Windows).

Found by the #516 fixers, 2026-10-09.

### D101 - Pods and worktrees after #523 (low)

- A worktree reads its main checkout's committed agents and skills, but not its commands,
  workflows or `mcp.json`.
- `TroupePolicy` can't forbid a profile's `repositoryOverridesBundle`.

Found by the #516 fixers, 2026-10-09.

### D102 - Onboarding after #516's second half (low)

- An item `GEMINI.md` adds after `CLAUDE.md`'s list joins the proposed `AGENTS.md` as a
  separate block, a loose list.
- The person's global opencode `instructions` (`~/.config/opencode/opencode.json`) aren't
  onboarded, only the workspace's.
- On a machine a worker runs on (`TROUPE_WORKER_AUTOSTART=true`), `troupe bench` and `troupe
  doctor --bench` fail the four onboarding scenarios with the pod refusal.
- A first session start in a workspace with other tools' files walks the tree and surveys
  the sources synchronously, once per onboarding version: a one-off delay in a very large
  repository.

Found by the #516 fixers, 2026-10-10.

### D103 - Trust, confinement and MCP after #531 and #532 (low)

- A copy-import into the person's own layer keeps a source file's `permission: auto`
  without saying so.
- `mcp.list`'s `trust` says "trusted" both when the workspace is trusted and when only the
  start was allowed; since #522 those differ for `auto`. The `notes` carry the difference,
  and neither client shows `mcp.list`'s; the desktop app doesn't show `agents.list`'s
  either (the TUI's agents manager does, since #563).
- Trust is read when a session starts, so after `troupe config trust` a running session
  keeps asking until a new one starts.
- `Troupe.Protocol.Bundle.list_skills_in/1` and `Skills.Local.skills_at` (`skills.add`,
  `skills.remove`) still raise on an unreadable `SKILL.md`.
- `skills.add` with `link` into an untrusted workspace answers `added` though the skills
  aren't offered until the workspace is trusted.
- `commands.list` and `workflows.list` carry no `skipped`; linked-out commands and
  workflows are listed only in the session's `files_skipped` and the daemon log.
- The TUI's `d` and `x` on a server whose layer is `session` or `request` say "a server
  from config.yaml is ... there"; a typed `/skills remove <name>` on an `.agents` skill
  still goes to the daemon and gets "no skill named".

Found by the #519, #522 and client fixers, 2026-10-10.

### D104 - Processes, the sandbox and git after #535, #537 and #540 (low)

- `Troupe.Agent.ACPAgent` starts its program with `Port.open` directly, not under the
  reaper; on a worker bubblewrap's `--die-with-parent` covers it, locally nothing does.
- Inside the sandbox `shell`'s `HOME` is the workspace, so a committed `.gitconfig` or
  `.npmrc` at the repository root is the user configuration of the commands it runs
  (contained in the sandbox).
- A worker doesn't check the sandbox when it starts, only at the first command, and `troupe
  doctor` has no sandbox line.
- The gateway's `git worktree remove` without `--force` runs git's own status, which
  recurses into a worktree's submodules under their own configuration.
- `Worktrees.list` runs git status in whatever directory `.git/worktrees/*/gitdir` names;
  it is neutral and confined, but tells that directory's dirty bit.
- On Linux a working directory gone when a command starts gives exit status 2 and no
  output ("spawn: Could not cd" on the VM's stderr) instead of the reaper's no-directory
  sentence (Decision 733).
- On Windows a port reports the exit status without waiting for end of file, so a
  background child's later output is lost.
- `troupe config` run with no daemon embeds one and leaves a `daemon.json` naming ports
  nothing listens on once it exits.

Found by the #528, #529 and #536 fixers, 2026-10-10.

### D107 - Commands from an activated window, and the palette's rows (low)

For the palette (#503), whose slot owns these.

- A repository command run while a branch's window is activated goes to the session's
  own agent, not the window's (`Client.run_command/3`, by design in Decision 763); the
  palette doesn't say so.
- `explore`, `general`, `implementer` and `reviewer` ship as subagents, so they have no
  palette row and nothing a person types starts one; #502 lists them as rows. (Both agents
  managers list and edit them since Decision 852.)

Found by the #502 audit, 2026-10-10.

### D110 - The start-up flow after #546, #544 and #550 (low)

- A workspace whose other tools' files give nothing to write (a `CLAUDE.md` linked to
  `AGENTS.md`) is planned at every session start, since the notice now repeats until
  answered.
- The desktop app's librarian start still reads `setup.get`'s `usable`, which is the
  machine's; `memory.get`'s `model` now says whether a model can be asked under the
  workspace's own config (Decision 854), as the TUI's `Config.key_problem` check does.
- The desktop app logged React's "two children with the same key" for workspace paths on
  every poll (`views/Local.tsx` keys rows by `path`): `worktree.list` drops repeated
  session workspaces by their exact string before listing each one's repository, so a
  checkout and its own worktree, or `C:\x` and `c:/x`, list the same trees twice. Not
  Windows only.
- In a repository not onboarded and with no other tools' files at its root, every start
  runs three git processes to look for nested ones (`found?/1`: rev-parse, `config
  --list`, `ls-files`); adding `ls-files` to `Troupe.Git`'s objects-only set would drop
  one, under Decision 833.
- A glob in opencode's `instructions` still walks `node_modules` before its matches are
  dropped, which is slow in a JavaScript repository.

Found by the #516 third-wave and #248 desktop fixers, 2026-10-10, and the chunk 27 fixers,
2026-10-11.

### D111 - Repository memory after #553 and #557 (low)

- Two daemons on one repository each re-read before writing, but a write replaces the
  whole `facts.jsonl`: the last writer wins a narrow race.
- The bench's budget for the tool definitions has been raised for each new tool (13,500,
  13,800 by Decision 853, 14,300 for `show`), and they were within 160 bytes of it when
  this was written, so the next tool needs room made for it rather than another raise.
- TUI Decision 54 still describes the file-count drift Decision 838 removed (a supersede
  can't cross the two numberings).
- For an anchor git doesn't track that is still on disk, the prompt says "`.env` is gone
  since it was checked".
- `memory.get` (scope `control`, Decision 854) still migrates or reads back a brief in
  whatever directory its caller names: a read that writes.

Found by the #248 fixers, 2026-10-10, and the chunk 27 fixers, 2026-10-11.

### D112 - Agents after #549, #551 and #563 (low)

- `agents.put` into the user scope takes `permission: auto` (`shell: auto` included) with
  no confirmation at the daemon, and a user agent's `auto` isn't gated by trust: both
  clients ask before such a save, a client of their own with `admin` need not.
- `agents.put` and `agents.delete` in the project scope take any `workspace` the daemon's
  user can write, as `mcp.add` does.
- Each `agents.list` row's `worktree` is `session.create`'s rule, the same for every row.
- A save into a layer that a higher one hides counts as a new file and asks about every
  `auto` (`agents.get`'s `also` gives paths, not permissions).
- The nearest-name suggestion for an unknown tool reads oddly ("teleport": import,
  delegate, todo_write).

Found by the #503 fixers, 2026-10-10.

### D113 - Command mode and branches after #556 and #560 (low)

- TUI Decision 39's diff stat when a person's own worktree finishes, and Decision 42's
  `/merge <name>` acting on the name, aren't there since branches became sessions.

Found by the #502 fixers, 2026-10-10.

### D114 - Watch after #558 (low)

- An `answer` branch can't remove its `AI?` comment, so each save of that file asks again.
- A trigger fired while no TUI was attached is in the journal, but its window opens only
  from a live event (not tested).

Found by the #502 watch fixer, 2026-10-10.

### D115 - Windows processes and connections after #552 and #562 (low)

What D115 named about `troupe daemon open`, `Troupe.MCP.Stdio`, the clipboard,
`Troupe.Protocol.Client` and `/upload` is Decision 849. Left:

- `System.cmd/3` with a bare name still resolves through `:os.find_executable` (the
  worker's `df`, the mix tasks' `zig`, `kubectl` and `kubeconform`); none runs from a
  workspace, and the credo check of Decision 846 has no test of its own.
- On Windows a stdio MCP server that closes its input but keeps running is never stopped:
  it runs outside the reaper (Decision 654), and closing the port doesn't end it.
- `Troupe.CLI.Daemon.exec`'s reaper branch falls back to a bare `cmd` when `COMSPEC` is
  unset, where Decision 846's `Troupe.Executable.comspec/0` would do.
- `Troupe.Protocol.Client` still answers a send that failed as `unavailable` with an
  inspected reason, which `closed?/1` doesn't recognise, so the TUI says plain
  "unavailable" until the disconnect arrives.
- `clipboard_command` is app configuration only, so an installed build can't set it.

Found by the #502 and #555 fixers, 2026-10-10, and the D115 fixer, 2026-10-11.

### D116 - A shell call's outcome after #545 (low)

- The TUI and the desktop app show a check mark for a command that exited non-zero: they
  read `ok`, not `exit_status`.
- A model's `timeout_ms` for `shell` isn't capped below the harness's tool timeout, so a
  long one ends as the generic "the tool timed out" (`ok: false`, no `timed_out`).
- On a worker, bubblewrap failing to set up one command (a missing bind source) would read
  as that command's `exit_status`.

Found by the #248 fixer, 2026-10-10.

### D118 - Delegation after #567, #572 and #575 (low)

- **Approvals and the gate.**
  - A parent definition's `permissions: {delegate: ask}`, or any other inline tool set to `ask`, is accepted and then ignored: inline tools check only `deny` (`Tools.authorize`). `delegation.ask` (Decision 850) is what asks.
  - An ordinary `ask` approval waits inside the tool's own timer (at least 180 s), while the delegation gate has none, so a slow person times out on one and not on the other.
  - After `approvals: deny` and a restart, a replayed unattended denial reaches the root as "The person denied...", and so does one the approvals process dropped by dying: the harness did it, not the person.
- **Background children.**
  - ACP (`troupe acp`) and A2A map every `user_input` to the user's message, so a background child's end, like the harness's notes, reads there as the user's words.
  - A background child's spend is lost across its parent's restart.
  - A stopped or cancelled child's model call in flight is not counted.
  - A person can stop background children only all at once, by cancelling.
  - No agent's instruction (`build`, `orchestrate`) mentions background delegation; #554's bench (slice 4) is to say whether to teach it.
- **What changed.** A child's `changed` is counted from its file tools' calls, so what its commands changed is said, never counted. A branch's full diff is rebuilt the same way, where its worktree's own `git diff` would count both.

Found by the #554 fixers, 2026-10-11.

### D119 - Sessions and state directories after #568 and #576 (low)

- **Erasure (security-relevant, low).** `session.erase` answers `erased: true` for a session it found nowhere, and its log stays. This happens to a session in a trusted project's own `state_dir`, after a daemon restart and before any session in that directory has started again: the index doesn't know the directory yet. Persisting the known state directories, or having erase say what it deleted, would close it.
- **Listing after a restart.** For the same reason, such dormant sessions aren't listed after a restart until a session in that directory starts.
- **Dead pids.** `Troupe.Registry.whereis/1` can answer a dead pid for a moment after the process exits (Elixir 1.20's `Registry.lookup` doesn't check liveness), and an input sent to it is lost. `Troupe.activate` checks; `whereis` itself doesn't.
- **Stop race.** A command that arrives between the sweep's decision to stop a session and the stop's claim on it (microseconds) still reaches the tree.
- **Slow MCP servers.** A slow MCP server makes every session using it take up to 4 s to stop (`MCP.Sessions.end_all`), and the killed request seems to leave its pooled connection busy for the next one.
- **Config schema wording.** The config schema still says `state_dir` is "where session logs go"; it holds the blobs and kept outputs too.

Found by the D117 and session lifecycle fixers, 2026-10-11.

### D120 - Command mode, agents and watch after #570 and #571 (low)

- **Merge and discard errors.** `worktree.merge` and `worktree.discard` still answer a git that didn't run (`{:elsewhere, ...}`, `:unlocated`, the reaper's errors) as `invalid_params` with an inspected term, through `dispatch.ex`'s shared `worktree_error/1`.
- **Forks of a branch.** A fork made with `/new --branch` runs in that branch's worktree. It isn't in the parent directory's picker, and its directory goes when the branch is merged or discarded.
- **Forking from the palette.** `/new` from the palette runs at once as a new session; forking needs Tab and a typed `--branch`.
- **Conflicted merges.** After a conflicted merge the branch's uncommitted work has been committed (`commit_pending`), so Decision 647's "the worktree is as it was" isn't literal.
- **TUI errors.** The TUI's link (`Link.error_message`) flattens a protocol error to "code: reason" and drops its `data`.
- **Desktop watch box.** It follows `watch_changed` only for the session it shows.
- **Team session palette.** A team session's palette rows have no agent facts: the desktop client has no `agents.list` over a worker.
- **TUI kept edits.** The TUI keeps an unsaved agent edit by name, so a broken `.troupe/agents/plan.md` and the built-in `plan` share a slot.
- **Broken agent files (no new exposure).** `agents.get` (scope `observe`) returns the text of a user or project agent file that doesn't parse, from the same places it returned when the file parsed. A link swapped in between load and read is a theoretical race.
- **Headless duplicate.** The headless printer once printed `spawned /build (shared)` twice (a race between reading the journal and the live stream).

Found by the chunk 27 fixers, 2026-10-11.

### D121 - Keys, MCP servers and limits after chunk 28's fixes (low)

- **A malformed initialize answer.** `Troupe.MCP.Stdio`'s `after_initialize/2` matches an answer with a `result` or an `error`, and nothing else. A stdio server that answers `initialize` with neither crashes the server's process with a `FunctionClauseError`, where a status ("answered initialize with neither a result nor an error") would do.
- **The live bench's key.** `troupe bench --live` hands its key to sessions in `config_overrides`, which sits unredacted in the sessions supervisor's child spec and in a watch branch's start options. Decision 0857 redacts the `Config`, `MCP.Stdio` and `Session.MCP` states; these two places are plain maps.
- **Default limits.** The default limits #389 named were set, not tuned against measured runs: the tool output cap, the compaction threshold, and a turn's budget. #389 closed with that owed. #465's measurement (chunk 28) gave the first numbers for Anthropic's models, but none of them was tuned from it.

Found by the chunk 28 fixers and the coordinator, 2026-10-11.

### D122 - Updates, the prompt prefix and the plane's checks after chunk 29 (low)

- **Building a test release key.** Restoring `apps/troupe_core/priv/release-keys.txt` with a copy keeps the file's old timestamp, so `Troupe.Release.Keys` isn't rebuilt. A worktree's `_build/prod` can then trust only a throwaway test key, and an install from it would refuse every real release. After a test build, touch the file or delete `_build/prod/lib/troupe_core` (Decision 865's test-build method).
- **Pre-releases aren't signed.** `prerelease.yml` can be dispatched on any branch, so it has no access to the release key, and `troupe update` refuses its builds. Whether pre-releases get a key of their own is undecided.
- **Releases reach `troupe update` only once marked Latest.** `release.yml` publishes a `-beta` version as a GitHub pre-release, and `/releases/latest` skips pre-releases. A machine with no plane, and the installers' default, see a release only after it's marked Latest by hand. A signed-in client follows its plane's `recommended` (Decision 868).
- **The daemon's own update.**
  - A machine with the daemon alone, no `troupe` and no desktop app, has no updater: `troupe-daemon` can't replace the directory it runs from on Windows. The desktop app updates the daemon beside it (Decision 874).
  - A turn can start in the 250 ms between `daemon.stop` answering and the stop, and a client can restart the old daemon before the swap. Decision 865 records both.
- **What the plane's version check is.** Client versions are what the client says, so `update_required` is a service to the person, not access control: a client that lies, a script, or a client from before 0.13.0 is never refused.
- **Wording.**
  - The no-key refusal says the same thing twice ("installs no release; nothing is installed").
  - `troupe login` against a plane that refuses the version keeps the credentials and exits 1 with the sentence, where "signed in, but..." would read better.
- **`notify_url`.**
  - A network-specific NAT64 prefix (`64:ff9b:1::/48`, a provider's own) and Teredo (`2001::/32`) also carry an IPv4 address that neither `Reach` nor the plane reads; covering them needs a setting naming the cluster's prefix.
  - An `https` receiver, which gets its name through Mint's `hostname` for SNI and the certificate check, has no test.
- **The prompt prefix.**
  - The summariser's refused-and-resent call isn't logged (`compacted` has no `thinking_resent` or `prefix_mismatch`), so `Troupe.Bench.Prefix.count/1` misses it.
  - With a context window close to the base prompt's size, compaction fires before every call, since what is left stays over the threshold, and nothing stops the loop.
  - `llm_request.prompt_bytes.brief` is 0 under the stable prompt (the brief counts as conversation bytes, Decision 815), so Decision 769's breakdown no longer shows it.
- **The live bench.** Its plan text and cost cap ignore a scenario's own config, such as `long_turn`'s `max_turns: 20`. Since #648 the run itself uses the scenario's limits, so they can exceed the plan's cost cap, which the runner still enforces.

Found by the chunk 29 fixers, 2026-10-11.

### D123 - Tools, the scratchpad, sign-in and installs after chunk 30 (low)

- **What an organisation enforces** (Decision 869).
  - The desktop app's model panel still writes `provider` and `base_url` into the user file under an enforced provider. The value is held on load, with a warning.
  - The desktop app's settings view doesn't show where a value came from (#57, #56).
  - `managed.yaml` has no JSON Schema of its own.
- **Binding models.**
  - `binds_thinking` says a model binds, but doesn't bring an alias's thinking back between calls (Decision 805 decides that by effort or name). An alias of a binding model with no `reasoning_effort` still drops its reasoning.
  - The live bench's worst-case estimate for one configuration can exceed a slot's spend cap; its guard is the estimate only.
- **The scratchpad.**
  - A `show` call whose arguments exceed 16 KiB arrives as a blob reference. Until `scratch_updated` arrives a moment later, the TUI's card reads " · " and the desktop app's card is disabled.
  - If a profile sets `show` to `ask`, the approval shows the whole document.
  - Sizes read "2.3 kB" in the TUI (1000-based) and "2.3 KB" in the desktop app (1024-based).
  - `Troupe.fork_session/2` copies the log but not the parent's blobs, so a fork's events that refer to a blob may read as missing. Not verified.
- **The pod's session-token guard.** `Troupe.Worker.Auth`'s `@session_methods` is a hand-kept copy of "every command whose schema requires `session_id`". A new session-scoped method must be added there too, and only the worker's `auth_test` catches a miss, in the full suite only. `scratch.list` was missed once (#614). Deriving the list from the protocol schema, or a test comparing the two, would close it.
- **A person's own MCP server's sign-in.**
  - A sign-in still waiting in the browser isn't stopped by `mcp.sign_out` or `troupe logout`; if it completes afterwards, the server is signed in again.
  - `troupe logout` revokes one provider after another, up to 5 s each, so several unresponsive providers can outlast the client's call timeout and report the sign-ins kept although they were forgotten.
  - A server that keeps answering `insufficient_scope` for a scope already granted makes every sign-in ask again; nothing notices the loop.
- **The sessions index.**
  - A listing still asks each running session's summary one after another, each with a 5 s timeout.
  - The core suite's global index reads the developer's real state directory (`test_helper` unsets `TROUPE_STATE_HOME`).
  - `Troupe.erase_session`'s `named_dirs` still walks through the file server (`Path.wildcard`); it runs only on erase.
  - `WatchSessionTest` can also time out on the watcher's `set_enabled` call under load.
- **An install elsewhere** (Decision 873).
  - It stops its own `troupe.exe`, but the runtime that program started from the shared payload can keep running until its window closes; PowerShell 5.1 can't tell which install a payload process belongs to.
  - `-Purge` still deletes the shared config and state directories, as the plan says.
  - On Linux, `--gui` overwrites the shared menu entry to point at its own app, and its uninstall then removes that entry.
- **The terminal UI.**
  - The side box's title, " tokens · tasks · agents · pending ", is cut at 30 columns.
  - "This turn" shows the window's own agent; while ←→ views a subagent, that subagent's turn line stays in its transcript.
  - In tests, `TUIHelpers.resize/4` doesn't change the size the headless runtime renders at; start a new server, or call `View.render` directly.

Found by the chunk 30 fixers, 2026-10-11.

### D124 - Updates, frames, addresses and the turn's tools after chunk 31 (low)

- **The desktop app's update** (Decision 874).
  - When the plane refuses the desktop app's version, the rail shows "This computer" and offers no Sign out until the app is updated.
  - The desktop app's own `client_info` versions to workers and the daemon are hard-coded (`connection.ts`, `attach.ts`, `daemon.ts`). Only the plane's `initialize` gets the real version.
  - `daemon_start` is a synchronous Tauri command that can loop for up to 30 s. The update banner appeared only after the daemon search gave up, which suggests it holds up other IPC. Not proven.
  - A desktop app installed from its own setup, without the installers, has no daemon to update. The terminal client has no daily check of its own; it says the plane's `suggest` only when it meets the plane.
  - The macOS and Linux update paths (`.app.tar.gz`, AppImage) and `app.restart()` there haven't run. The first release run that signs desktop updater artifacts is 0.15.0's.
- **Frames** (Decisions tui/0161 and 877).
  - The desktop app's main bundle is 576 KB (171.5 KB gzip), above Vite's 500 KB warning.
  - The TUI's curtain flourish isn't padded, so the facts beside it shift a few columns. A strip can't be opened with the mouse in the TUI.
  - `Model.without_turn_lines/1` is unused in `lib` but named by Decision tui/0160.
- **Addresses and ceilings** (Decision 875, #622).
  - When an enforced ceiling leaves less room than the budget question's smallest step, the question offers only "stop", although a typed "+1" is accepted.
  - The plane's trigger notifications keep their own resolve-and-pin code (Decision 866) beside the daemon's `Troupe.MCP.Address`.
- **The turn's tools** (Decision 876).
  - The session log now holds the held tools' definitions (including a person's offered tools) and the skill directories' absolute paths, each written once and again on a change.
  - On a binding model, compaction, an `AI?` turn's `plan` prompt and a profile or model switch still change the prefix; what an enforcing account does after such a change is D92's first item.
- **The scratchpad at compaction** (Decision 878, #616). The compaction summariser once wrote a whole plan from only the prompt and two files, and once a one-sentence summary that dropped all earlier context.
- **Personal tools on a pod** (Decision 879). `personalTools: forbid` takes effect at a session's next activation. A session that is awake when an administrator changes it keeps accepting registrations until it is activated again.
- **The terminal client's connection.** Every fleet call goes on one connection, and the gateway answers a connection's calls one at a time, so one slow call blocks the rest (`worktree.list` now has its own, #621).
- **A fresh daemon's first `session.create`.** Twice, a `session.create` sent about 2 seconds after an installed daemon started got no answer for over 120 seconds; one sent later answered in under a second. Not confirmed: it may be the test harness or a startup race. The release runs with distribution off, so it couldn't be attached to.

Found by the chunk 31 fixers, 2026-10-12. Its test items were fixed in chunk 32 (D8 says
what is left).

### D125 - Docs, policy, ceilings and workspaces after chunk 32 (low)

- **The plane and its chart.**
  - A TeamVolume's `status.claimName` says `team-<team>`, but the claim is `troupe-team-<team>`.
  - The Trigger CRD's `notifyUrl` description says only "not loopback". The console's Bundles page names a removed `troupe admin bundle publish` command. The plane's index page still shows `troupe mcp`. `admin.profile.put`'s description lists `mcpServers` as admin-set.
  - Bundles' `@builtin_primaries` (`build`, `plan`) is hand-kept, and eight built-ins are primary.
  - `dev/kind`'s plane policy lacks the `people/` paths, and its role lacks the audience.
  - The audit chain is an unkeyed hash. It catches a changed or removed row, not a rewrite of the whole table (stated in `docs/admin/security.md`).
- **Upgrading to 0.16.0** (Decisions 883 and 884).
  - A live `TroupePolicy` holding an egress entry that isn't an exact host or `*.domain` refuses every profile after the upgrade, naming the entry.
  - Helm doesn't upgrade CRDs, so the new rules apply once the CRDs are applied.
  - A GUI served anywhere but the plane's host needs `operator.workerAllowedOrigins`.
- **The daemon and the gateway.**
  - Command-id replay is keyed by the principal's subject, and every local connection shares it. Two local clients counting their own ids could collide; every real client uses random ids.
  - A worker advertises `watch: true` but refuses `watch.*` to every token a plane mints.
  - `Link.call` answers a failed write with a bare `unavailable` and keeps the dead client until it hears of the disconnect.
- **Ceilings** (Decision 880).
  - An OpenAI-compatible reasoning model under a low ceiling can spend all of `max_completion_tokens` reasoning and answer nothing; Troupe sends the effort unchanged and says nothing.
  - Models that think unasked still think at their own default inside the ceiling when thinking is "off" (recorded in 880).
- **Workspaces inside a repository** (Decision 881).
  - Instruction files in an ignored folder are still read up to the enclosing repository's `.git`.
  - `onboard.apply`'s refusal in an ignored folder says it "is in no git repository".
  - In `auto` mode, a session at the checkout's top and one in a tracked subfolder share the checkout without a worktree.
  - A `worktree.list` row the time budget didn't reach can't be fetched later.
  - `/worktree <prompt>` in an ignored folder works in the folder and doesn't say no worktree was made.
- **The clients and the CLI.**
  - The VS Code Files row opens a plane's organisation document URL as a file.
  - `docs/user/updating.md`'s `TROUPE_BIN_DIR` doesn't change what `troupe update` updates; the running binary's path wins.
  - With `TROUPE_INSTALL_DIR` set, Burrito prints a line on stdout that corrupts `--json`; `clients/tui/scripts/build-local` uses the same variable.
- **Stale strings and comments.** `scripts/remote-up`'s WebSocket URL; `gateway/daemon.ex`'s supervision strategy (it is `rest_for_one`); `plane/harness.ex`'s `session.create` order; the source file `status.ex` names; `tokens.json`'s `$meta` and motion notes; `signal.tokens.json`'s `default`; `Approval.tsx`'s "runs on the platform" for a local shell; the TUI's empty state suggesting `/code`; and comments citing another repository's decisions.
- **Releases and tests.**
  - Pre-releases carry no signed manifest, so the installers refuse them where `minisign` is installed.
  - Recorded fixture logs stop at 0.3.0; nothing in the release path runs `troupe.fixtures.record`.
  - `TROUPE_IDLE_TEST_MS` is set in CI but read by nothing.
  - `DoctorCLITest --bench` once found entries under `state/remote` missing afterwards. Protocol `ClientTest` (a `serve/0` receive timeout) and gateway `LoopbackTest` ("a refused upgrade is logged at warning level") each failed once under load; `CrashLoopTest` is in D8.
- **Unclear, to check.** Whether `backup-restore.md`'s `eval 'Troupe.Plane.Index.rebuild()'` starts what it needs; how clients reach a registered machine (it advertises no endpoint without `TROUPE_POD_ORDINAL` and `TROUPE_WORKERS_DOMAIN`); `egress.fqdns` entries with a port against the policy check; whether the project owns `troupe.dev`, the config schema's `$id`.

Found by the chunk 32 fixers, 2026-10-12.

### D126 - Workers, the GitHub App, the console and providers after chunk 33 (low)

- **Worker pods** (Decision 890).
  - `procMount: Unmasked` is refused by the `baseline` and `restricted` Pod Security levels even with `hostUsers: false`, so worker namespaces need `privileged`. The operator doesn't label them; on a cluster whose default level is stricter, every worker pod is refused at creation.
  - Team volumes on NFS-like RWX storage are expected to stop a user-namespaced worker pod from starting (no idmapped mounts); not tried.
  - containerd's default AppArmor profile denies `mount`, which would block bubblewrap on AppArmor nodes; not verified.
  - The shipped `Localhost` seccomp profile was tried only on a local kind; CI's kind runs workers `Unconfined`.
  - The kind cluster's OpenBao runs in memory, and a one-shot Job configures it, so after a restart it has no transit key, Kubernetes auth or policies until that Job runs again.
  - `troupe-worker-mcp-identity` equals `Troupe.KMS.Policy.worker_policy_name("mcp-identity")`, so a profile named `mcp-identity` would collide with it.
- **The GitHub App** (Decision 885).
  - Any team may name any repository the App's installations cover; per-team narrowing is #653.
  - Installation tokens aren't revoked when a session goes dormant; they run out their hour.
  - `git.credential` is answered synchronously on the pod's control connection, so a slow GitHub delays that pod's other traffic.
  - `sessions.workspace_source` is stored from the client and never read.
  - A pod that enrols marks dormant a session placed on it a moment earlier that it didn't report; the tests allow for it, and `person_credentials_test.exs` has the same latent race.
- **The console** (Decision 886).
  - An upgraded deployment serves `/console` before its identity provider allows the redirect URI, so sign-in fails until it is registered (the error says what to register).
- **Providers** (Decision 887).
  - Catalogue listings send the HTTP library's default User-Agent, not Troupe's.
  - An organisation that enforces `provider: azure_openai` without enforcing `base_url` leaves a session-wide Azure provider without a URL unrefused.
  - OpenRouter's `reasoning_details` isn't handed back (Anthropic models with tools through OpenRouter), and its usage `cost` isn't used.
- **Orchestration** (Decision 888). The bench has no task where `orchestrate` could pay off (larger multi-file work, a reviewer catching a mistake), and `docs/user/bench.md` says a by-name scenario's limits are printed by the plan, where `describe/1` prints only the plan-wide ones.
- **The clients.**
  - A `fleet` subscription has no per-session access filter; on a pod, authorisation limits it to tokens without a session id.

Found by the chunk 33 fixers, 2026-10-13.

### D127 - The GitHub fix loop, control TLS, the scratchpad and providers after chunk 34 (low)

- **The GitHub fix loop** (Decision 891).
  - `git_push` commits the whole working tree (`git add -A`). Anything the agent can read and copy into the workspace, a secret on one of its mounts included, can land on a `troupe/*` branch, which is public for a public repository. Until a later slice's policy can refuse public repositories or restrict paths, grant the App private repositories only.
  - CI output reaches the agent fenced as data, but text in it can still steer the agent within its own branch, pull request and comments; the rules enforced in code hold.
  - A profile that grants neither checks nor statuses gets no round counting, only its budget.
  - Installation tokens still aren't revoked when a session goes dormant (D126).
- **Control TLS** (Decision 893).
  - `OwnerOnly` was added to the TUI's harness doors and the TUI's own `icacls` code removed, with no TUI decision recording it.
- **Team admins and namespaces** (Decisions 896, 897).
  - A team admin's audit list leaves out `profile.put`, `host.*` and `pod.drain` as rows about the plane as a whole, so a team admin no longer sees changes to profiles their team is granted. Whether to show them is a product question.
  - The enrolment prefix comes from the chart's `policy.namespacePrefix`, not the live TroupePolicy; a separately installed policy with another prefix gets its pods refused (with a log line).
  - D124's other half is open: one connection for every fleet call.
- **The scratchpad** (Decision 895).
  - A session near the compaction threshold compacts mid-turn and then reads the same document again.
  - Asked for "the whole plan again", models show the document again rather than patch it.
  - The default `max_tokens` of 8192 cuts a whole-document `show` short on Sonnet 5.5.
  - Agents still try `grep` and `edit_file` on `scratch:` paths.
  - The desktop app draws a `patch` call as a generic tool row.
  - The "only when asked, or past about 80 lines" wording hasn't been measured live.
- **Tests.**
  - Plane suites run at once against the shared `troupe_plane_test` database deadlock (`40P01`).
  - The core and gateway suites in one VM make gateway tests fail on sessions core left behind; CI runs them apart.
  - The gateway's `PrivateTest` (two tests) fails under load.
  - A `helm upgrade` from `dev/kind/values.yaml` alone, on a development cluster `scripts/remote-up` set up with a gateway URL, narrows the policy back to the placeholder host, after which every write to the dev profile is refused.
- **History.** Merge commits b41e250f and 13f907b3 keep git's `# Conflicts:` lines in their messages.

Found by the chunk 34 fixers, 2026-10-13.

### D128 - AppArmor, identity, control TLS and the console after chunk 35 (low)

- **Worker AppArmor** (Decision 898).
  - The profile is written for `abi <abi/3.0>`, because the release images' parser is Debian 12's AppArmor 3.0.8, and user namespaces are allowed because that ABI doesn't mediate them. An explicit `userns,` rule (and `deny io_uring,`) waits for images on Debian 13.
  - `ci.yml`'s test job still lifts `kernel.apparmor_restrict_unprivileged_userns` on its runner for the host bubblewrap tests; loading the worker profile there and running bwrap under it would let the lift go.
  - kind still runs workers with seccomp `Unconfined`, so CI never starts bubblewrap under the shipped seccomp profile.
  - On a 6.17 kernel, containerd's default profile as Debian 12's parser compiles it refuses every unix socket; kind's nodes now take the host's compile. A node whose runtime compiles its default with an old parser would meet the same.
- **Identity** (Decision 899).
  - There is no admin action to fold a claim-named group into SCIM's UUID group, so the stale one stays, empty.
  - Session lists show a removed owner as `removed:<uuid>`, not the tombstone's display name.
  - A session read-only because its grant was revoked, whose index row is gone entirely, rebuilds as dormant.
- **Control TLS** (Decision 902).
  - `scripts/verify-local.ps1` can't pass on scratch homes: it compares the listening process's path with `$env:LOCALAPPDATA\Programs`.
  - OTP 28.5's `:inet.getfd/1` raises on an `inet_backend: socket` socket (upstream).
- **The audit** replaces `secretRef.key`, `tokenUrl` and `transitKey` values with `[redacted]` in profile diffs, so changes to those names don't show.
- **The desktop app.** Nothing checks the desktop crate's Rust formatting.

Found by the chunk 35 fixers, 2026-10-14.

### D129 - The complete console, GitHub webhooks, rules and extends after chunk 36 (low)

- **Identity** (Decision 906).
  - SCIM's subject is the `externalId` itself (Decision 751), so a mapping that is wrong from the first push can't be detected.
- **GitHub** (Decision 905).
  - GitHub makes each reply in a review thread its own review, so a burst of replies becomes several turns.
  - Conversation comments on a draft don't resume its session, and `issues.assigned` and a scheduled sweep aren't done.
  - An org member whose membership is private may be reported as `CONTRIBUTOR`, so their command comment is ignored. Not checked against real GitHub.
  - The Trigger CRD's repository pattern is looser than the plane's own check.
- **The console** (Decision 904).
  - In a break-glass session, `/admin` can reset sign-in and the admin group to the deployment's values, so it isn't strictly read-only. 904 names what to remove to make it so.
  - A plane deployed with `console.enabled: false` has no editing screens.
  - The organisation's enforced-set editor writes an object-typed key such as `permissions` as JSON text; a rules editor would serve better.
  - `admin.trigger.run` and `admin.trigger.key.rotate` are still owed.
  - `--color-table-changed-cell` is an unused token.
- **Per-tool rules** (Decision 907).
  - Shell rules read the command line and aren't a sandbox: `sh -c`, scripts and aliases run what no rule sees.
  - Path rules match only the path a call names, so a search over the whole workspace isn't caught by a rule on `secrets/**`, and symlinks aren't resolved.
  - A person's own `!cmd` isn't a tool call, so no rule applies to it.
  - On a call a rule made ask, "allow for the session" still records an allow for that tool's other calls.
  - A worker profile can't carry rules yet (#724).
- **Extends** (Decision 908).
  - A child on its own channel has its parent's MCP servers on its resource but not in the bundle its pods load, and a child's `override: true` is lost when its own channel next publishes (slice 2).
  - GitOps has only the `troupe.dev/extends` annotation to carry `extends` (slice 4).
  - A profile created after its channel's bundle was published gets no `mcpServers` until the next publish (#722).
- **The plane.**
  - A 413 for a body over the limit answers generic JSON, not SCIM's error schema or a JSON-RPC error.
  - The shared MinIO test bucket holds about 2,500 sessions left by earlier runs, never cleaned.
  - Two worktrees running the plane suite at once still deadlock in the shared test database.
- **CI.**
  - The desktop crate's new `cargo test` job runs only on pull requests into `main`, and its apt package names are untested before then.
  - Nothing checks Rust formatting.

Found by the chunk 36 fixers, 2026-10-16.

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
| A person's own remote MCP server that needs their OAuth sign-in (found by the deployment's first profile); then the `initialize`/session handshake and the desktop app's half of the pod path (the TUI's half has landed since; client registration is #585) | #300, PR #310; #319, PR #323; #308, PR #322 |
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
| D99 - `.agents/` and skills: the TUI's layer labels, the desktop app's remove, the clients' skipped lists, unreadable `SKILL.md` and `.agents/AGENTS.md`, and the check's paths in `.agents/AGENTS.md` | PRs #530, #532, #533 |
| D101's first item - `files_skipped` shown as a bare line | PR #530 |
| D100's first item - a linked `opencode.json` gave no servers | #522, PR #531 |
| D98's librarian item - its prompt said other tools' files are in every prompt | #516, PR #534 |
| D84's last item - an instruction file that couldn't be read only logged a warning | #516, PR #533 |
| D93 - Tab completed a command name without its slash | #502, PR #547 |
| D105's first items - `/cancel` kept the window, `/worktree <existing>` and `<name>:` weren't read, a dismissed branch wasn't in `/sessions`, a refused merge said "conflicts", `read_branch` listed its parent, `/dismiss` on a pod, `worktree.remove` inside the tree | #502, PR #556 |
| D106 - a watch trigger ran on the session's own agent with its permissions, unseen, with no state on the protocol | #502, PR #558 |
| D107's first and palette items - a slash command typed in a window went to the agent, the palette dropped the window, Tab matched summaries, an argument hint ran empty, `/agents` listed `worktree` | #502 and #503, PRs #560 and #563 |
| D108 - an upload over 16 MB, or a connection closed mid-call, took the connection or the screen down | #502, PR #552 |
| D109 - `/copy` and Ctrl-Y on Windows | #502, PR #552 |
| D115's first five items - `troupe daemon open` from the TUI lost its daemon on Windows, an MCP stdio server that exited early crashed its start, `clip` got UTF-8, `/upload` read an oversized file first, a dropped protocol client's pending calls exited | PR #566 |
| D117 - the sessions index blocked on a slow stop, the shared cause of most load flakes | PR #568 |
| D113's first six items and D105's last two - an approval asked before a worker restart went to the parent, `/new --branch` forked the empty log, a conflicted merge said to resolve, `worktree.remove` answered an inspected string, `worktree.list` ran four git calls a tree, rows had no model, a dismissed one was titled by its path, the focus named a closed window, `/ask` never said none had finished | #502, PR #570 |
| D107's subagents item, D112's conflict and unparseable-file items, D114's desktop watch box and headless line | #565, PR #571 |
| D102's, D110's and D111's items, and D68's empty `TROUPE_DAEMON_SOCKET` - untracked anchors hashed on read, the old `remember` form, `scope`, anchor case on Windows, `memory.get`'s scope and model, onboarding outside a repository, onboarded files said not read, nested files, second runs, opencode globs and keys | #248, #516, PR #574 |
| Sessions found by the chunk 27 fixer of slot B - erasure ignoring a configured `state_dir`, dormant sessions there unlisted, a slow stop blocking every start, a command reaching a stopping session, the sweep dropping a running session, listings reading every log | PR #576 |
| D26's headless item - `troupe run --headless` exited at the first rest, so a reply to a line queued mid-turn was never printed | PR #262 |
| D26's A2A item - a task stayed `working` after the failure guard stopped its turn | PR #266 |
| D36's dead code - the printer's and the model's dead clauses, the view's recount, the picker's empty branches column, `Troupe.Codec`'s `to`/`reason` (the dead `truncated` and `compaction` clauses were left for #301) | PR #262 |
| D43's subagent-name half - a subagent's window had no name in the TUI | PR #570 |
| D52 - nothing writes a profile's OpenBao role and policy | #627 |
| D55's first item - every worker pod logs in as the one role `troupe-worker` | #627 |
| D64's build.md item - section 3 had no row for `mix troupe.config.schema` | #422 |
| D69's summariser item - the compaction summariser got another model's signed thinking | #590, PR #604 |
| D73's `FakeRemote` item - its `/rpc` could answer errors only without `data` | PR #605 |
| D75's `symbols:` item - a decision's `symbols:` is not checked against the code | #422 |
| D82's last item - the prefix binding of thinking blocks | #465, PR #601 |
| D90's `FakeRemote` item - `commands.list` answered without aliases | PR #547 |
| D100's subagents item - a `.troupe/agents` subagent's trust note reached no client (the desktop app's half is in D103) | PRs #563, #571 |
| D112's choosers item - the TUI's two agent choosers, Ctrl-N and Tab | #594 |
| D115's `open` item - the daemon CLI ran `open` and `xdg-open` by a bare name | PR #562 |
| D118's closed-call item - the desktop app showed a stopped child's closed call as failed without the reason | PR #647 |
| D122's two plane-check items - a connected client isn't judged again when the policy changes, and the plane doesn't record client versions | #657 |
| D123's guardrail item - an organisation's enforced set is a guardrail, not a lock | #657 |
| D124's three frames items - reasoning on replay, Afterglow dark's `--bg-sunken`, no desktop control for `transcript.detail` | #659 |

## Checked and not a defect

- **The Authentik provider is Confidential, but the clients are public.** This was D4.
  Checked on 2026-09-23 against the live plane: the GUI's code exchange (PKCE, no
  secret) and its refresh grant both return 200, so Authentik does not ask a public
  client for the secret. The live sign-in loss (#53) was the provider missing the
  `offline_access` scope mapping, so no refresh token was issued. Martin added the mapping.
- **`done ●` and "1 done" after every reply from the command line.** This was in D36: the
  TUI marks the session's own window done until it is opened (PR #241). A question for the
  design, not a defect.
- **A forced `tool_choice`, which the newest Anthropic models refuse.** This was in D82.
  Checked on 2026-10-12: nothing in `apps/` or `clients/` sends a `tool_choice` at all.
- **A team renamed under its sessions' keys.** This was in D88. Checked on 2026-10-12: no
  path renames a team (`team_update` changes its settings only), so a team session's key
  named by the team's name stays the right one.
- **A raw `Port.open` of a console program without `:hide` on Windows.** This was in D115.
  It does nothing on OTP 28, but every raw spawn in the code passes `:hide` (checked on
  2026-10-12); it is a trap for new code, not a defect.
- **A daemon older than 0.8.0 writing `provider: anthropic`.** This was in D63: such a daemon
  reads a `config.set` without `provider` as a model-panel save. The clients of this
  release never send one, and a daemon that old is past support ([SECURITY.md](../../SECURITY.md)).
