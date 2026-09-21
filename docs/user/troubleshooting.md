> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> ## Deprecated — kept as an artifact
>
> This page documents the `troupe` terminal client. That client left this repository on
> 2026-09-14: `apps/troupe_tui` and `apps/troupe_ctl` were deleted, the packaged binary
> and its installers with them, and nothing here builds an executable any more. The
> source citations under each section point at files that now exist only in git history
> (`git show 20fe871 -- apps/troupe_ctl` and the tree at that commit).
>
> On 2026-09-21 the terminal client came back to this repository as `clients/tui`
> (Decision 666), rebuilt since as a client of the daemon, and its current documentation
> is [`clients/tui`](../../clients/tui/README.md); the graphical client's is
> [`clients/gui/docs`](../../clients/gui/docs/README.md). This page describes the client as
> it was in `apps/`, and is not brought up to date.
>
> Nothing in this directory is maintained against the code. It is here because the prose
> is worth keeping until the client repository can take it, and for no other reason.

# Troubleshooting

Symptoms as you see them, what they usually mean, what you can do, and when it is a
platform setting only an administrator can change. "Admin" below means your team
admin or the platform operator ([../admin/README.md](../admin/README.md)).

Contents: [Login](#login) · [After login](#after-login) · [Tokens and access](#tokens-and-access) ·
[Sessions](#sessions) · [Watch and worktrees](#watch-mode-and-worktrees) · [Budgets and capacity](#budgets-and-capacity) ·
[GUI](#the-gui) · [Binary and daemon](#the-binary-and-the-daemon)

---

## Login

### The identity provider refuses with `AADSTS650053` or "invalid scope"

**Symptom.** `troupe login` prints `the identity provider answered 400: … AADSTS650053
… groups …` (Microsoft Entra), or another provider's "invalid_scope", before you are
asked for a code.

**Cause.** The plane advertises the scopes a client must ask for, and one of them is
not a scope at that provider. `groups` is the usual offender: at Entra it is a token
claim, not a scope. This build's default scope list is `openid profile email
offline_access`; a plane deployed with an older default or an explicit override may
still send `groups`.

**Do.** Nothing on your side fixes it. Ask the admin to set the plane's OIDC scope
override (`TROUPE_OIDC_SCOPES`) to the four scopes above, or to remove `groups`. Note
the override is uncommitted in the working tree at this audit
([AUDIT.md](../AUDIT.md) §4 question 14).

### `this plane does not publish a device authorization endpoint`

**Cause.** The plane's discovery document has no device-code endpoint: the provider
does not support the device grant, or the plane was deployed without the endpoint
configured.

**Do.** Admin: configure the device authorization URL on the plane, or use a provider
that supports the device grant. Until then the GUI (which uses a browser redirect
flow) may still work for you.

### `the login code expired before it was used`

**Cause.** You took longer than the provider allows (usually ten minutes).

**Do.** Run `troupe login` again and enter the new code.

### `<url> answered 404; is it a Troupe plane?` or `could not reach <url>`

**Cause.** Wrong URL, a path on the end, or no network path to the plane.

**Do.** Use the plane's origin only (`https://troupe.example.com`, no trailing path);
check VPN.

### `the plane refused the login (403): …`

**Cause.** The provider accepted you but the plane did not: the token's audience or
issuer does not match what the plane expects, or a required claim (`sub`) is missing.

**Do.** Admin: check the plane's client id, issuer and audience configuration.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/login.ex:48-73, 126-132, 137-150
- config/runtime.exs:259-263, 328-331
- apps/troupe_plane/lib/troupe/plane/web/router.ex (discovery scopes default; see docs/admin/configuration.md)
- docs/AUDIT.md preamble, §4 question 14

## After login

### "No profiles" after login

**Symptom.** `troupe login` ends with `You are not in any team this plane has enabled.
Ask a platform admin.` or `Teams: … No profiles are granted to them yet, so there is
nothing to create on.` Later, `troupe --remote` says `no profiles are granted to your
teams on this plane yet`.

**Cause.** Login worked. Either none of your identity-provider groups has been enabled
as a team, or your team has no profile grant yet. Membership itself is never edited in
Troupe; it comes from the provider.

**Do.** Ask a platform admin to enable the group as a team (`troupe admin team enable
GROUP`) and grant a profile (`troupe admin team grant TEAM PROFILE`). You do not need
to log in again afterwards: `troupe --remote` asks the plane for your current grants
each time.

### Several profiles or teams

**Symptom.** `several profiles are available (dev, review); name one with --agent`, or
the plane answers `choose a team` with a list.

**Do.** `troupe --remote --agent review`. For the team case there is no CLI flag; use
the GUI's start dialog or a script passing `team` to `session.create`.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:338-354
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:172-192
- apps/troupe_plane/lib/troupe/plane/harness.ex:432-456

## Tokens and access

### `the identity provider refused the refresh (400): … Run: troupe login <plane>`

**Cause.** The stored refresh token is no longer valid: it expired, was revoked, or a
rotating provider issued a new one that another copy of `troupe` on a different
machine consumed.

**Do.** `troupe login <plane>` again. If it recurs on one machine only, that machine's
credentials file is stale; log in there.

### The UI shows `lost the daemon: …` after about fifteen minutes on a remote session

**Cause.** Pod tokens last at most 15 minutes. The pod sends `auth.expiring` two
minutes before expiry; the client must mint a new token from the plane and present it
on the same connection. If the plane cannot be reached at that moment (laptop asleep,
VPN dropped), the pod closes the connection shortly after expiry.

**Do.** `troupe --remote resume <id>`; the session is intact. In the GUI the page
reconnects with a backoff on its own.

### `unauthenticated` with `wrong_audience`

**Cause.** A token minted for one pod was presented to another. Tokens and endpoints
travel together; a script that cached an endpoint and later got a token from a
different `session.open` mixes them up.

**Do.** Use the `endpoint` and `token` from the *same* `session.open` or
`session.create` answer.

### `forbidden` with `access revoked`

**Cause.** Your access to the session was withdrawn since your token was minted: the
team's grant on the profile was revoked, or your ACL entry was removed. Access is
re-checked on every command.

**Do.** Ask the team admin. A session whose team lost the profile is `read_only`; it
can be read but not continued.

### `forbidden` with `required_role: "owner"` or `required_scope`

**Cause.** You are a collaborator or viewer trying to pin, erase, archive or create,
or a viewer trying to steer.

**Do.** Ask the owner or a team admin to do it, or to grant you a higher role
(`session.grant`).

Sources:
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:103-128
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:160-168, 475-478
- apps/troupe_protocol/lib/troupe/protocol/token.ex:98, 124-135
- apps/troupe_worker/lib/troupe/worker/auth.ex:206-219
- apps/troupe_plane/lib/troupe/plane/harness.ex:585-591, 832-838
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:202-204
- PROTOCOL.md:522-582

## Sessions

### A session is stuck waiting on an approval nobody sees

**Symptom.** Status `waiting`; nothing happens; the person who started it closed their
terminal.

**Cause.** An `ask` tool is blocked until somebody answers. Approvals wait
indefinitely.

**Do.** Locally: `troupe hq` lists every pending approval in every local session;
answer with `y`/`a`/`n`. Remotely: the GUI's "Waiting for you" inbox lists them across
the sessions you may see; or `troupe --remote resume <id>` and answer in the popup;
or a script sends `approval.respond`. For unattended jobs, run with `approvals: deny`
(config or plane `terms`) or `--auto-approve` so nothing waits.

### After a restart the session says `interrupted` and does nothing

**Cause.** By design. A session that was mid-turn when the daemon or pod restarted
comes back dormant and interrupted and makes no model call until you send something.

**Do.** `troupe resume <id>` (or `--remote resume`) and type "continue". The
unfinished tool calls are closed as errors so the model sees a result for each. Set
`resume_on_restart: true` locally if you want automatic continuation.

### `resync_required` / "reconnected the event stream"

**Cause.** Your client fell more than 10 000 durable events behind (a slow terminal, a
long sleep) and the server dropped the subscription rather than buffer forever. The
CLI and GUI re-subscribe from the last event they folded; headless mode carries on
without re-subscribing because it prints as it goes.

**Do.** Nothing; the notice is informational. If it recurs constantly the machine or
link is too slow for a detail-level stream; watch through the GUI or HQ instead.

### The session I created is not in `troupe sessions`

**Cause.** `troupe sessions` is per workspace (the current directory, or `-C`). A
session created in a worktree is recorded under the worktree path, not the parent
repository.

**Do.** Run it from the same directory, or `troupe sessions -C <worktree path>`.
`troupe hq` lists every local session regardless of workspace.

### `no session to resume in <path>`

**Cause.** No session has been recorded for this workspace.

**Do.** Name the id, or start a new session.

### `this session is read-only`

**Cause.** The team's access to the profile was revoked or the session is being
erased. Reading works; activating does not.

**Do.** Ask the team admin whether the grant will return; otherwise start a new
session and read the old one for context.

Sources:
- apps/troupe_core/lib/troupe/session/approvals.ex:53-68
- apps/troupe_tui/lib/troupe/ui/hq/server.ex:1-14
- apps/troupe_core/lib/troupe/agent/server.ex:280-320
- apps/troupe_core/lib/troupe/config.ex:53-57
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:7-8, 32, 751-766
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:197-200
- apps/troupe_ctl/lib/troupe/ui/headless.ex:86-89
- apps/troupe_ctl/lib/troupe/cli.ex:188-206, 222-233
- apps/troupe_plane/lib/troupe/plane/harness.ex:585-591

## Watch mode and worktrees

### Watch mode does not react to my `AI!` comment

Check, in order:

1. Is it on? The header shows ` · watch`; `/watch` toggles and prints the backend.
2. Is the comment a comment? The opener (`#`, `//`, `/*`, `--`, `;`, `%`, `<!--`) must
   not be inside a string; an odd number of quote characters before it disqualifies
   the line. `AI` must be the first or last word of the comment text, optionally
   followed by `!` or `?`.
3. Polling? `watch: poll` means no native watcher was available; changes are picked up
   about once a second. `watch backend stopped; falling back to polling` means the
   native watcher died; polling continues.
4. Is the file inside the session's workspace (or worktree)? Files outside are not
   watched.
5. On a pod, editing happens in the pod's workspace, not on your laptop; watch mode
   there reacts to files the agent or an upload changed.

### `watch: watch is exclusive per workspace`

**Cause.** Another session already watches this directory.

**Do.** Turn it off there (`/watch`), or let that session go dormant, then turn it on
here.

### Worktree removal refused

**Symptom.** `worktree.remove` answers `conflict` with `worktree has local changes`.

**Cause.** The worktree has uncommitted changes or untracked files, usually the only
copy of the agent's work.

**Do.** Commit or stash inside the worktree, then remove; or remove with `force: true`
(or `git worktree remove --force`) if you are sure.

### A second `troupe` in the same repository started in a different directory

**Cause.** `--worktree auto`: the workspace already had an active session, so the new
one got its own worktree on `troupe/<slug>`. The CLI printed the path before the UI
opened.

**Do.** Work there, and merge the branch when done; or start with `--worktree never`
to share the checkout (two agents editing one tree is usually worse).

Sources:
- apps/troupe_core/lib/troupe/watch/marker.ex:13-17, 88-108, 123-148
- apps/troupe_core/lib/troupe/session/watcher.ex:146-150, 161-166
- apps/troupe_core/lib/troupe.ex:334-360
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:437-453
- apps/troupe_gateway/lib/troupe/gateway/worktrees.ex:25-35, 80-99
- apps/troupe_ctl/lib/troupe/cli.ex:417-419

## Budgets and capacity

### `budget exhausted (max_turns)` and the agent stops

**Cause.** The agent reached one of its limits: 40 turns, 2 000 000 input tokens,
400 000 output tokens, or 30 minutes by default; a subagent has a slice of its
parent's. The agent ends with reason `budget_exhausted`.

**Do.** Locally raise `max_turns`, `wall_clock_ms` and the token limits in
`config.yaml` (or the agent definition's `max_turns`), and start a new session or send
a new input; a headless run exits 1. On a pod the session's `terms` were fixed at
creation; create a new session with larger `terms` (script) or ask the admin whether
the profile's defaults should change.

### `budget_exhausted` when creating or resuming a remote session

**Cause.** The *team's* money budget has nothing left to reserve (default reservation
5 000 000 micros per session). Distinct from the per-agent limits above.

**Do.** Ask the team admin to raise the team's `budget_micros` (`troupe admin team
update TEAM FILE`) or to wait for the period. The session stays dormant and can be
read meanwhile.

### `pending` — a session with no endpoint yet

**Not an error.** `session.create` answered with a session id, `"state": "pending"` and no
endpoint: the profile is full and the plane has already asked for another worker. The
session exists and is yours.

**Do.** Nothing. Ask again after `retry_after_ms`; the same call answers with an endpoint
once there is somewhere to connect to. A cold worker takes roughly half a minute — the same
wait as waking a dormant session.

### `capacity` — `<profile> allows N session(s) at once, and they are running`

**Cause.** A ceiling somebody set. This is now the only capacity refusal there is: a
profile with no ceiling grows instead of refusing.

**Do.** Try later, or ask the administrator to raise `max_sessions` on the profile — the
refusal quotes the number they set, so it is a specific thing to ask for.

### `unavailable` — `the pod did not accept the session` / `the pod is gone`

**Cause.** The chosen pod is draining, restarting or unreachable from the plane.

**Do.** Retry; the plane picks another pod. If it persists, the admin should check the
profile's pods.

### `rate_limited` or `model request failed: …`

**Cause.** The model provider or gateway refused or timed out (300 s per request). The
session retries with backoff up to four times before logging `llm_error`; a headless
run then exits 1.

**Do.** Send the input again once the provider recovers. Persistent failures on a pod
are an admin matter (gateway key, endpoint, egress policy).

Sources:
- apps/troupe_core/lib/troupe/budget.ex:11-14, 48-55
- apps/troupe_core/lib/troupe/config.ex:27-30
- apps/troupe_plane/lib/troupe/plane/harness.ex:29-35, 461-491, 540-557, 624-638, 840-852
- apps/troupe_protocol/lib/troupe/protocol/error.ex:14-38
- docs/AUDIT.md §1.7 (retries, request timeout)

## The GUI

### CORS error in the browser console; "cannot reach the plane" on sign-in

**Cause.** Two allowlists must both name the GUI's origin, and neither is yours to
set:

1. The plane's `TROUPE_CORS_ORIGINS` must include the exact origin the GUI is served
   from (scheme, host, port). Without it the browser blocks `/rpc`,
   `/auth/exchange` and the discovery document. The GUI's error names the origin to
   add.
2. The identity provider must register the GUI's origin as a single-page-application
   redirect URI (Entra error `AADSTS50011` points at this).

**Do.** Send both to the admin. A GUI served from the plane's own origin under a path
(`/app`) needs no CORS entry.

Sources:
- config/runtime.exs:265-270
- apps/troupe_plane/lib/troupe/plane/web/cors.ex:3-7, 36-42
- ../../clients/gui/docs/AUDIT.md §1.4, §2

## The binary and the daemon

### macOS: "cannot be opened because the developer cannot be verified"

**Cause.** The binary is unsigned and carries the quarantine attribute from a browser
download.

**Do.** `xattr -d com.apple.quarantine troupe`, or install with the script (curl does
not set the attribute).

### Windows: "Windows protected your PC"

**Do.** More info → Run anyway. The installer's download does not carry the
mark-of-the-web. Some antivirus products flag self-extracting binaries; ask your IT
for an exception if it is quarantined.

### `could not reach the daemon: the daemon did not come up in time` / `there is no daemon running, and no way to start one`

**Cause.** The daemon failed to start within the start-up window, or the binary
cannot find itself to spawn one (a build outside the packaged binary with no
`TROUPE_DAEMON_COMMAND`).

**Do.** Run `troupe daemon` in another terminal to see its error directly. Check that
the socket directory exists and is writable (`$XDG_RUNTIME_DIR/troupe/`, or
`~/.troupe/run/troupe/`). A stale start-up lock (`daemon.sock.lock` or `daemon.lock`
next to the socket) blocks starts for 30 seconds after a killed client; wait or delete
it. On Windows the daemon listens on loopback TCP and writes `%LOCALAPPDATA%\troupe\daemon.json`;
if that file names a port nothing listens on, delete it and start again.

### `this build has no TUI in it` / `this build has no terminal UI in it` / `this build has no fleet view in it` / `this build has no daemon in it`

**Cause.** You are running a build that does not include that component (a worker
image, or a development build with the UI app excluded).

**Do.** Use the packaged `troupe` binary from the release. `troupe run "…" --headless`
works without a TUI; `troupe --remote … --headless` works without a daemon.

### `could not start the terminal UI: no usable terminal`

**Cause.** No real terminal (a pipe, CI, some IDE consoles).

**Do.** Use `--headless`.

### `unknown command` / usage printed, exit 2

**Do.** Check the command word; `troupe ctl …` and `troupe token …` from older docs do
not exist.

Sources:
- README.md:61-77
- apps/troupe_ctl/lib/troupe/cli.ex:97-117, 170-179, 299-308, 447-458, 484-492, 661
- apps/troupe_protocol/lib/troupe/protocol/daemon.ex:11-28, 132-147, 214-243
- apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:112-130
- apps/troupe_tui/lib/troupe/ui/tui.ex:55-67
- PROTOCOL.md:516; docs/AUDIT.md §2
