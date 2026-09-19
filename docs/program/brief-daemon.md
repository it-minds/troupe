# Brief: the daemon — one harness under the TUI, the GUI and the worker

*Drafted 2026-09-19 from a session that made the TUI work against the live plane.
Written to be picked up cold. Section 0 is the prompt to paste into a new session;
the rest is what that session will need and what it should not re-derive.*

---

## 0. The prompt

Paste this into a new Claude Code session opened in `C:\Users\admin\dev` (so all four
`troupe*` directories are reachable), or in `troupe-remote` with `troupe-tui`,
`troupe-gui` and `troupe` added as working directories.

```
Read C:\Users\admin\dev\troupe\docs\brief-daemon.md in full before anything else, then
the files it points at. Do not re-derive its findings; verify a claim only where the code
has moved since 2026-09-19.

The job: make one harness serve three clients. Today `troupe-tui` (a laptop TUI) and
`troupe-remote/apps/troupe_core` (the harness a Kubernetes worker pod runs) are a fork of
one agent loop that has drifted ~2,400 lines apart in `agent/server.ex` alone, and the
GUI (`troupe-gui`) can only talk to the remote. The target is a **daemon** —
`troupe_core + troupe_gateway + troupe_protocol` packaged as one binary — that speaks
PROTOCOL.md's local transports, so the TUI, the GUI and the worker pod run the same agent
code and emit the same events. PROTOCOL.md §1 already specifies the daemon's transports
and `Troupe.Gateway.Loopback` already exists; what is missing is the release, the TUI as
a client of it, and the TUI-only features ported into the core.

Work the phases in section 4 in order. Each phase has done items; a phase is finished
when every done item is proven by a test or a smoke that is named in the report. Land
each phase as its own branch and PR per repository; do not start the next phase's code
in the same branch. Follow each repository's own rules (section 5) — in particular
`DECISIONS.md` gets one numbered entry per deviation, `mix compile --warnings-as-errors`
is the bar, and nothing in `Troupe.UI` may call anything but `Troupe.Client`.

Before writing code in phase 1, answer the open decisions in section 7 for me in one
message and wait; everything else in phase 0 does not depend on them.
```

---

## 1. Why: what is known, with evidence

**The two harnesses are one harness, forked.** 29 modules share a path between
`troupe-tui/lib/troupe` and `troupe-remote/apps/troupe_core/lib/troupe`; none is
identical. `agent/server.ex`: 1,378 lines (TUI) vs 1,650 (core), 2,446 lines differ.
`config.ex` 808 vs 204. `session/log.ex`: JSONL single-writer vs a hash-chained,
upcasted, sealed log. Same states (`idle → thinking → acting → compacting → done`), same
supervision (`Agent.Node` one_for_all, rebuild from own log), same nine base tools.

**The GUI can only talk to a remote.** `troupe-gui/apps/desktop/src/shell.ts` has a
stage-2 `findDaemon` (read `daemon.json`, start the daemon if absent) and
`packages/client/test/support/daemon.ts` fakes one, but no daemon exists to find.

**The daemon is already designed, not built:**

| already there | where |
|---|---|
| Local transports: Unix socket (`$XDG_RUNTIME_DIR/troupe/daemon.sock`), loopback TCP + `daemon.json` with token (Windows), loopback **WebSocket for graphical clients** with an `Origin` fence that admits `http://localhost:*`, `127.0.0.1:*` and a desktop shell's origin | `troupe-remote/PROTOCOL.md` §1 |
| The loopback server — "deliberately the *same* server a worker pod runs", same `Gateway.Connection`, handshake, scopes, dispatch | `apps/troupe_gateway/lib/troupe/gateway/loopback.ex`, `web.ex` |
| Handshake capabilities a daemon would report: `worktrees`, `watch`, `private_sessions`, `remote: false` | `PROTOCOL.md` §3 |
| "The daemon" as a first-class actor in the release plan: private sessions need the sealer moved from `troupe_worker` into `troupe_protocol` (W1b); ACP served on the daemon's loopback (W5) | `troupe/RELEASE.md` |
| A TypeScript client that already speaks it, browser or Node | `troupe-gui/packages/client` (`@troupe/client`) |
| An Elixir client that already speaks it (built this week against the live plane) | `troupe-tui/lib/troupe/remote/*`, `lib/troupe/client/remote.ex` |

**What is missing:** `troupe-remote/mix.exs` releases are `troupe_operator`, `troupe_plane`,
`troupe_worker`, `troupe_a2a` — no daemon. The TUI's local path (`Troupe.Client.Local`)
calls the harness in-process and never touches the protocol; the TUI's own event
vocabulary (`assistant_message`, `branch_spawned`, `approval_answered`, `input`) differs
from the protocol's (`llm_response`, `tool_call_started`, `approval_decided`,
`user_input`), bridged today by `Troupe.Remote.Translate` (Decision 98 in troupe-tui).

---

## 2. Target shape

```
                 ┌─────────────────────┐   ┌──────────────────────┐   ┌──────────────────┐
                 │  troupe (TUI)       │   │  troupe-gui (Tauri)  │   │  Zed / ACP client│
                 │  UI + dispatcher    │   │  web bundle          │   │                  │
                 └────────┬────────────┘   └──────────┬───────────┘   └────────┬─────────┘
   in-process or unix sock│                 loopback ws│                 loopback ws (ACP)│
                          ▼                            ▼                                ▼
                 ┌────────────────────────────────────────────────────────────────────────┐
                 │  troupe_daemon  =  troupe_core + troupe_gateway + troupe_protocol      │
                 │  one Burrito binary per platform; log sealed to a local directory      │
                 └────────────────────────────────────────────────────────────────────────┘
                                          same three apps, one line of config away
                 ┌────────────────────────────────────────────────────────────────────────┐
                 │  troupe_worker (pod)  =  troupe_core + troupe_gateway + plane link     │
                 └────────────────────────────────────────────────────────────────────────┘
```

One `Agent.Server`, one event vocabulary (the protocol's), one tool set with per-place
policy. The TUI keeps what is above the harness — the TUI itself, and the dispatcher's
*idea* of many branches — and stops owning a second agent loop.

---

## 3. Should this be a new repository? (comments for Martin)

**Not yet. Add the daemon as a fifth release inside `troupe-remote` first.** Reasons:

* The daemon is 90% `troupe_core + troupe_gateway + troupe_protocol`, which live in
  that umbrella and are not published packages. A new repo would have to consume them
  as git/path deps into another umbrella, and every core change would then be a
  two-repo change with a version bump in between — exactly the drift you are trying
  to end.
* Phase 1 is wiring (a release, a config, a packaging script). Doing it where the code
  is proves the shape in days. Moving repositories is a week of its own with no
  behaviour change to show for it.
* It does contradict `troupe-remote/README.md`'s identity — "ships no client, no binary,
  no installer". That sentence should change to "ships four images, a chart, and the
  daemon binary the clients stand on"; the *clients* (TUI, GUI) are still elsewhere.

**When to extract, and what to call it.** Once the daemon release exists and the TUI
runs on it, the boundary is proven. Then, if you still want a repo per artifact:

* `troupe-harness` — `troupe_core`, `troupe_gateway`, `troupe_protocol`, the daemon
  release, its Burrito packaging and installers. Publish the three apps to a private
  Hex organisation (or consume by git tag). `troupe-remote` keeps `troupe_plane`,
  `troupe_operator`, `troupe_a2a`, `troupe_worker`, the chart, and depends on the
  harness by version. `troupe_tui` and `troupe-gui` depend on the harness the same way
  (the TUI as a Mix dep; the GUI only on the protocol document and the daemon binary).
* Do the extraction with `git filter-repo` on the three app directories so history
  survives; do not copy files.
* The umbrella directory `troupe/` (this one) stays the home of cross-repo documents;
  add the new repo to its README table.

If you create the repo now anyway: name it `troupe-harness`, make it an Elixir umbrella
with the three apps moved (not copied), keep `troupe-remote` building against a path
dep for one release cycle, and do phase 1 there. The phases below do not change.

---

## 4. Phases

### Phase 0 — spike: does the daemon boot? (½ day, no decisions needed)

Goal: `troupe_core + troupe_gateway` started on a laptop, one local session created and
driven over the loopback WebSocket by `@troupe/client`, nothing else.

Done when:
1. A `mix run` script in `troupe-remote` starts the gateway with `Loopback` transport,
   writes `daemon.json`, and `pnpm --filter @troupe/client` (or a tiny Node script)
   does `initialize → session.create → input.send` against it and receives
   `llm_response` events, using the `fake` provider. No packaging, no TUI.
2. A written list of what broke: every place the core assumed a pod (S3 object store,
   plane control link, bundle registry, enrolment token). This list is the input to
   phase 1's design and to section 7.

**Done 2026-09-19.** `troupe-remote/scripts/daemon-spike` (branch `daemon/phase-0-spike`)
boots the daemon and passes `initialize → session.create → input.send` from
`@troupe/client`; `troupe-remote/docs/daemon.md` is the list. Two corrections to section 1
came out of it: the daemon is *built*, not only designed — `Troupe.Gateway.Daemon`,
`Troupe.Protocol.Daemon`, `Endpoint`, the sealer already in `troupe_protocol`, worktrees,
markers, honest capabilities — and this repository shipped a Burrito binary until
2026-09-14 and removed it on purpose (`DECISIONS.md` 319–324), which bears on section 7.1.

### Phase 1 — `troupe_daemon` release

Goal: a binary a person installs that is the local harness.

Done when:
1. `mix.exs` has a `troupe_daemon` release: `troupe_core`, `troupe_gateway`,
   `troupe_protocol`; no plane, no operator, no worker link. Boots with no network.
2. The three local transports from PROTOCOL §1 work and are tested: Unix socket on
   Linux/macOS, loopback TCP on Windows, loopback WebSocket everywhere; one
   `daemon.json` describes them all; tokens are owner-only files.
3. The log is sealed to a local directory (the `Sealer` moved from `troupe_worker` to
   `troupe_protocol` per `RELEASE.md` W1b), so a daemon session and a worker session
   have the same on-disk format. A session sealed by the daemon restores on a worker
   and the reverse (this is RELEASE.md's stated done item; reuse its test).
4. Configuration for a laptop: providers and keys from `~/.config/troupe/config.yaml`
   and `TROUPE_*` env (port the TUI's `Config` resolution including the opencode
   fallback and the model catalog — the daemon is what pays for tokens now).
5. `initialize` reports `remote: false`, `worktrees`, `watch`, and `private_sessions`
   honestly (`false` for anything not yet ported).
6. Packaging: one Burrito binary per platform, `troupe daemon` starts it, `install.sh`
   / `install.ps1` from `troupe-tui` moved here and pointed at a real release
   (`github.com/it-minds/troupe/releases` currently 404s — decide where releases live).
7. `bin/troupe_daemon eval` works (Decision 634 in troupe-remote: no
   `to_existing_atom` in `runtime.exs`).
8. `troupe-remote/README.md` says what the repository now ships.

**Phase 1 landed 2026-09-19** across three branches: `troupe-remote` PR #10
(`daemon/phase-1-harness`: the apps build outside the umbrella, a laptop's providers in
`Troupe.Config`, the TCP listener's bound port, `troupe-daemon` on the `PATH`; Decisions
639–642 and `docs/daemon.md`'s phase 1 table), this repository's `daemon/phase-1-release`
(`daemon/`: the `troupe_daemon` release — a plain Mix release per platform rather than a
Burrito binary, `daemon/DECISIONS.md` 1 says why — with the reaper built in, the
`troupe-daemon` wrapper for `run`/`status`/`config`/`models`/`version`, file logging, an
eval-safe `runtime.exs`, no Erlang distribution, `install.sh` / `install.ps1`,
`.github/workflows/release.yml`), and `troupe-tui`'s `daemon/phase-1-client` (`troupe
daemon` hands off to the binary; the installers left). Proven on this machine: the
unpacked Linux release answers `version`, `status`, an idempotent second `run`, `eval`,
serves `@troupe/client` end to end (`initialize → session.create → input.send →
agent_done`) and runs `shell` through its own reaper. The release workflow's first run
built and smoked Linux x86_64/aarch64 and macOS x86_64/aarch64; Windows left the matrix
because `ezstd`, the harness's zstd NIF, had no Windows build (`daemon/DECISIONS.md` 4)
and came back on an it-minds fork that builds it with Zig (`daemon/DECISIONS.md` 5).
Item 6's "release at a real URL" is proven the first time a `v*` tag is pushed here.

### Phase 2 — the TUI becomes a client of the daemon

Goal: delete `Troupe.Client.Local` and the TUI's copy of the harness; the TUI is a
front-end over the protocol whether the session is on this machine or a pod.

Done when:
1. `troupe` (the TUI binary) boots the daemon in the same BEAM when none is running and
   connects to it through `Gateway.Connection` — same dispatch table, no socket
   needed — or connects over the Unix socket / loopback TCP when one is. Both paths
   are tested with the fake provider.
2. `lib/troupe/agent`, `session/log`, `session/approvals`, `tools/*`, `llm/*`,
   `reaper`, `watch` are gone from `troupe-tui`; their tests moved or dropped with a
   note per test in `FINAL_REPORT.md`.
3. `Troupe.Remote.Translate` is gone: `Troupe.UI.TUI.Model` folds protocol events
   directly (`user_input`, `llm_response`, `tool_call_started`, `approval_requested`,
   `agent_state` ephemerals). `mix troupe.xref` still passes: the UI calls
   `Troupe.Client` only, and `Troupe.Client` is now the one remote client.
4. Every TUI test that drove a local session (`start_session!`, the `Fake` provider
   scripts keyed by agent path) drives a daemon session instead, through the socket.
   The 420-odd test suite stays green; the two known environmental misses
   (`inotify-tools`, the 4 MB backpressure bound) are documented, not deleted.
5. `mix troupe.remote.smoke` against `https://troupe.itmindsinternal.dk` still passes
   end to end, including `TROUPE_REMOTE_APPROVE=1` (approval round trip).

### Phase 3 — port what the TUI harness has and the core lacks

Each item is its own PR in `troupe-remote`, behind a capability the daemon reports and
a worker may or may not. Order by how much the TUI's own product depends on it.

| feature | TUI module(s) | lands in core as | capability |
|---|---|---|---|
| Branches: many concurrent agents per session, each a window; `/code`, `/worktree` commands; `read_branch`; `branch_spawned`/`branch_failed`/`window_dismissed` | `session/dispatcher.ex`, `session/branches.ex`, `session/locks.ex` | a session holds N root agents; new events in PROTOCOL §4 (decide with Martin: section 7.3) | `branches` |
| Git worktrees per branch, merge/discard | `session/worktree.ex` | `worktree.*` methods already in §6 | `worktrees` |
| Workflows (named multi-step orchestrations) | `workflow.ex`, `priv/agents/workflow.md` | an agent definition + `delegate` (the core's `delegate` already runs subagents) | — |
| Project memory (`.troupe/memory.md`, `remember`) | `memory.ex`, `session/memory.ex`, `tools/remember.ex` | tool + mount rule (`session:/` vs workspace) | — |
| Kept tool output (`read_output`) | `session/outputs.ex`, `tools/read_output.ex` | `Blobs` already exist; expose as `blob.get` + a tool | — |
| `ask_user`, `web_fetch`, `git_read`, `glob` | `tools/*` | tools, policy-gated per profile (a pod's `web_fetch` is an egress question) | — |
| `read_roots` (read outside the workspace) | `workspace.ex`, `config.ex` | a `Mounts` entry with mode `read` | — |
| Local MCP servers (stdio/SSE from `~/.config`) | `mcp/*` | the core's `mcp.ex` takes servers from bundles; add a local source | — |
| Watch markers `AI!`/`AI?` | `watch/markers.ex` | the core has `watch.ex`; port the marker grammar | `watch` |
| Provider catalog, usage log, `--full-send`, `Headroom` | `llm/catalog.ex`, `llm/usage_log.ex`, `agent/headroom.ex` | `Budget` + `Usage` exist; add price catalog and headroom | — |
| 12 agent definitions | `priv/agents/*.md` | bundle content for the daemon's default channel | — |

Done when each row has: the core feature, a PROTOCOL.md change if any, a capability
flag, tests in the core, and the TUI using it through the protocol.

### Phase 4 — the GUI gets local sessions

Done when `shell.ts` stage 2 is real: the Tauri shell starts `troupe daemon` as a
sidecar (or finds the running one via `daemon.json`), the session list shows the
machine's sessions beside the team's (as `docs/client-ux.md` describes), and every
approval, todo and tool line renders from the same events as a remote session. The
"Keep it private" control appears because the daemon reports `private_sessions`.

### Phase 5 — worker parity and cleanup

The pod runs the same core; verify the ported features under policy (a pod with
`web_fetch` denied, a pod with worktrees allowed), rebuild the worker image (the
deployed `0.2.1` predates the reaper build step; the profile's image tag must move),
delete dead code and decisions that described the fork.

---

## 5. House rules per repository (do not relearn these)

**`troupe-remote`**
* Toolchain pinned in `.tool-versions` (Erlang 28.5.0.5, Elixir 1.20.4-otp-28, Zig
  0.16.0); `mix check` = compile `--warnings-as-errors`, format, credo `--strict`,
  `mix troupe.boundaries`, test. Plane tests need Postgres on `localhost:55432` (the
  `troupe-dev-*` compose stack under Docker Desktop is already up; `scripts/dev-up`
  collides on ports but the containers serve).
* Umbrella tests need `cd apps/<app>` for file paths to resolve.
* `Troupe.Log.Fold.witnessed_types/0` must list every event type the agent's replay
  reads — a test enforces it. New durable events go in PROTOCOL §4, the fold, the
  summary projection, and the manager's lifecycle where relevant.
* `runtime.exs`: never `String.to_existing_atom` on an environment value (Decision 634).
* `DECISIONS.md` is at 635. `REPORT.md` and `docs/admin/*` are kept current.
* Current branch with unmerged work: `fix/draining-pod-visibility` (Decisions 633–635:
  draining pods, eval-safe config, wake a finished agent). Base on it or merge it first.

**`troupe-tui`** (GitHub: `it-minds/troupe_tui`, underscore)
* `CLAUDE.md` is authoritative for commands. Always `mise exec -- mix …`. Zero
  warnings including type warnings. `mix troupe.xref`: UI calls only `Troupe.Client`.
* Tests: `assert_receive`, never `Process.sleep` to wait. `FakeRemote`
  (`test/support/fake_remote.ex`) is a plane + worker + OIDC issuer in-VM and now
  mirrors the live plane (exchange door, token gate, envelope, string version,
  required `session_id`). `remote_translate_test.exs` pins the protocol vocabulary.
* `DECISIONS.md` is at 98. `ARCHITECTURE.md §9.3` and `FINAL_REPORT.md` list remote proofs.
* Current branch with unmerged work: `fix/live-plane-client` (Decisions 92–98; the TUI
  works against the live plane end to end, `mix troupe.remote.smoke` proves it).

**`troupe-gui`**
* pnpm 10.15; `pnpm build`, `pnpm test`, `pnpm fake` (a fake plane + worker + IdP on
  loopback), `pnpm first-token`. `@troupe/client` is the reference protocol
  implementation in TypeScript — when the Elixir and TypeScript clients disagree about
  the wire, the plane's code decides, then PROTOCOL.md is corrected.

**This machine**
* Windows has no Erlang. The toolchain is in **WSL Ubuntu** via `mise` (user `martin`);
  clones on ext4 at `~/dev/troupe-tui` and `~/dev/troupe-remote`, synced from the
  Windows checkouts by a patch made with *Windows* git (`git diff HEAD > patch`, then
  `git reset --hard && git clean -fd && git apply` in the clone). `core.autocrlf=false`
  in the clones. A Docker fallback (`elixir:1.20.4-otp-28` with the mise Zig dir
  mounted at `/zig`) also works.
* `kubectl` for the live cluster runs from **Windows** (`.local/scaleway/kubeconfig.yaml`
  authenticates through `scw.exe`). The plane is unclustered, so `bin/troupe_plane rpc`
  never works; use `eval` (after Decision 634 is deployed) or `psql` from a one-off pod.
* The Claude Code Bash tool mangles backslashes and long heredocs here; write scripts
  to files with the Write tool and run them by path.

---

## 6. Verification toolkit that already exists

| what | how |
|---|---|
| Client against a plane+worker with no network | `troupe-tui`: `mix test test/troupe/remote_*_test.exs` against `FakeRemote` (36 tests + 6 translate) |
| Client against the live plane | `TROUPE_REMOTE_URL=https://troupe.itmindsinternal.dk mix troupe.remote.smoke`; `TROUPE_REMOTE_CREATE=1` forces `session.create`; `TROUPE_REMOTE_APPROVE=1 TROUPE_REMOTE_DECISION=allow_session TROUPE_REMOTE_PROMPT="Use the shell tool to run exactly this command: echo x. Then finish."` drives an approval round trip; `TROUPE_REMOTE_SESSION=<id>` attaches to one |
| The real TUI, headless, against anything | `MIX_ENV=test mix run <script.exs>` with `Troupe.TUIHelpers.start_tui/1`, `press/2`, `screen_text/2` — a `CellSession` terminal; press `1` to activate window 1 before `y`/`n`/`a` |
| GUI against fakes | `pnpm fake` then `pnpm dev`; `pnpm test` (49 tests) |
| Core agent loop | `troupe-remote/apps/troupe_core`: `mix test` (248), `resilience_test.exs` for restart/replay/wake; `Troupe.LLM.Fake` scripts by step |
| Live cluster state | `kubectl -n troupe-w-dev get pods`; the plane's `admin.profile.get` via `Troupe.Remote.Plane.call/3` from a `mix run` script with the saved credentials |

Sign-in for anything live is the Entra device flow; the refresh token this session
saved lives in WSL at `~/.config/troupe/credentials.json`.

---

## 7. Open decisions (answer before phase 1 code)

1. **Where does the daemon's code live?** Fifth release in `troupe-remote` now (section 3
   recommends), or a new `troupe-harness` repo from day one?
2. **Where do releases live?** `github.com/it-minds/troupe/releases` is what the TUI's
   installers point at and it has none. Pick the org/repo for binaries, and whether the
   plane's `cliUrl` should point there.
3. **Session model for branches.** (a) One local session holds many root agents — the
   dispatcher's model, ported into the core, so the GUI gets branches too; or (b) a
   branch is its own session and the TUI groups sessions client-side. (a) is more work
   in the core and the better product; (b) ships sooner. This decides the shape of
   half of phase 3.
4. **Does the daemon talk to a plane?** A laptop daemon that can *also* attach to team
   sessions is the GUI's stated UX ("one list of four kinds of session"); if the TUI
   embeds the daemon, the remote client moves into the daemon too, or stays in the TUI.
   Recommend: stays a client concern (TUI and GUI each hold their own plane client);
   the daemon knows nothing about planes.
5. **Private sessions on a laptop:** which key manager? RELEASE.md W1b assumes OpenBao
   for pods; a laptop needs a local key (OS keychain via the shell, or a file the way
   `credentials.json` is done today).
6. **Do the two Sep-13 `dev` sessions on the live plane get erased?** They are `active`
   in the index with erased workspaces (`not_a_directory` on activation) — a leftover
   of the drain incident, unrelated to this plan but on the way.

**Answered 2026-09-19 (Martin):**

1. Not a fifth release in `troupe-remote` (Decision 319 stands) and no new harness repo.
   The three apps are consumed as sparse git dependencies pinned to a `troupe-remote`
   commit; `troupe-remote` PR #10 is what made them consumable. The daemon-only binary,
   `troupe-daemon`, is built in **this** repository under `daemon/`; the TUI embeds the same
   apps in phase 2.
2. No rename. This directory became the `it-minds/troupe` repository: cross-repository
   documents, `daemon/`, the installers, and the releases at
   `github.com/it-minds/troupe/releases` — which is where the installers always pointed.
3. **(b).** The core already does it: `session.create` with `worktree: "auto"` gives a
   second session in a busy repository its own worktree; the TUI groups by workspace.
4. Yes as recommended: the daemon holds a plane token only for sealing private sessions
   (`identity.link`, in memory); team sessions are the clients' own plane clients.
5. No local key manager: the plane signs an assertion, the daemon logs into OpenBao with
   it. Deployment item: the OpenBao address the plane returns must be reachable from off
   the cluster.
6. Archive, do not erase.

---

## 8. Pointers

* This directory: `README.md`, `HANDOFF.md`, `RELEASE.md` (W1b sealer, W5 ACP on the
  daemon), `docs/client-ux.md` (the GUI's one-list-of-sessions), `docs/brief-gui.md`.
* `troupe-remote/PROTOCOL.md` §1 (transports), §3 (capabilities), §4 (events), §6
  (commands); `apps/troupe_gateway/lib/troupe/gateway/{loopback,web,connection}.ex`;
  `apps/troupe_core/lib/troupe/agent/server.ex`; `apps/troupe_protocol/lib/troupe/protocol/schema.ex`.
* `troupe-tui/lib/troupe/client/{local,remote}.ex`, `lib/troupe/remote/{worker,plane,translate}.ex`,
  `lib/troupe/session/{dispatcher,branches,worktree}.ex`, `lib/mix/tasks/troupe.remote.smoke.ex`,
  `test/support/{fake_remote,remote_helpers,tui_helpers}.ex`.
* `troupe-gui/apps/desktop/src/shell.ts` (`findDaemon`), `packages/client/src/{connection,session,plane}.ts`,
  `packages/client/test/support/daemon.ts`.
* Branches with this week's unmerged work: `it-minds/troupe_tui@fix/live-plane-client`,
  `it-minds/troupe-remote@fix/draining-pod-visibility`.
