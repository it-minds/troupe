# The daemon — phase 0: does it boot?

*2026-09-19. The spike named in `../troupe/docs/brief-daemon.md` §4, phase 0. What ran,
what it proved, and every place the harness still assumes a pod. This list is the input
to phase 1 and to the brief's section 7.*

## What ran

`scripts/daemon-spike` boots `troupe_core + troupe_gateway + troupe_protocol` from this
checkout as a local daemon and drives it with `@troupe/client`, the GUI's TypeScript
client, over the loopback WebSocket the daemon publishes in `daemon.json`:

```
$ scripts/daemon-spike ../troupe-gui/packages/client
daemon: unix:/tmp/troupe-spike-EMLb/run/troupe/daemon.sock
{"path":".../daemon.sock","transport":"unix","ws":{"port":40613,"token":"…"}}
initialize: {"instance_id":"cAKYSgYQNNY","name":"troupe-daemon","version":"0.2.0"}
            {"private_sessions":false,"remote":false,"watch":true,"worktrees":true}
principal: {"display_name":"martin","kind":"user","subject":"local:martin"} scopes: ["observe","control","admin"]
session.create: {"session_id":"20260919T181156-wEtY2w","workspace":"…","worktree":null,"branch":null,"syncing":false}
input.send acknowledged
llm_response: … "Hello from the daemon. Listing the workspace." … list_files …
llm_response: … "Listed. Done." … finish …
events: {"agent_started":1,"session_created":1,"input_accepted":1,"user_input":1,
         "llm_request":2,"agent_state":5,"llm_delta":10,"llm_response":2,
         "tool_call_started":2,"tool_call_completed":2,"tool_results":2,"agent_done":1}
SPIKE OK
```

Provider `fake` with `scripts/daemon-spike.json` as the script; no network; no plane,
no worker link, no object store, no bundle, no enrolment token. The session log on disk
is the hash-chained `events.jsonl` a worker writes.

The spike is three files: `scripts/daemon-spike.exs` (the daemon half, a `mix run`
script), `scripts/daemon-spike.mjs` (the client half, Node against the built client
package) and `scripts/daemon-spike` (runs both under a scratch state directory).

## What did not need doing

The brief was written from the outside and understated what exists. Already here, and
exercised by the spike or by the gateway's own suite:

| the brief said | what is there |
|---|---|
| "the loopback server already exists" | The whole daemon: `Troupe.Gateway.Daemon` (commands ledger, plane link, private sealers, connections, listener, loopback, idle shutdown), `Troupe.Protocol.Daemon` (discover, lock, spawn), `Troupe.Protocol.Endpoint` (Unix socket, loopback TCP, `daemon.json`). `daemon_test.exs`, `loopback_test.exs`, `autospawn_test.exs`, `private_test.exs` cover it. |
| phase 1.3: "move the `Sealer` from `troupe_worker` to `troupe_protocol`" | Done: `Troupe.Sessions.Sealer` is in `troupe_protocol`; `Troupe.Gateway.Private` seals a laptop session with a key obtained through the plane's `session.assertion` and a presigned store. |
| phase 1.5: "`initialize` reports capabilities honestly" | Done: `remote: false`, `worktrees: true`, `watch: true`, `private_sessions` computed per handshake (false until an identity is linked and a plane answers). |
| phase 3: "port the marker grammar" | `Troupe.Watch.Marker` exists with `AI!` / `AI?`. |
| phase 3: "worktrees per branch" | `Troupe.Gateway.Worktrees`: `session.create` with `worktree: "auto"` gives a second session in a busy repository its own worktree on `troupe/<slug>`; `worktree.list` / `worktree.remove` are served. |
| section 7.5: "which key manager on a laptop?" | None. The plane signs an assertion for the person, the daemon logs into OpenBao with it, and no key-manager credential ever sits on the laptop. |

Also known, and relevant to where the release goes: this repository *had* a Burrito
binary (`troupe_tui` + `troupe_ctl`, five targets, installers, four CI jobs) and removed
it on 2026-09-14 — `DECISIONS.md` 319–324. The daemon's code stayed; the packaging left.

## What broke, or would

Nothing broke at boot. What the spike had to work around, and what a release must
settle:

1. **No release.** `mix.exs` has four releases and no daemon. `TROUPE_DAEMON_AUTOSTART`
   exists in `runtime.exs` and starts `Gateway.Daemon` under `Gateway.Application`, but
   only a release gives it a supervision tree of its own: under `mix run` the daemon is
   linked to the script, and when the script returns the supervisor goes down with it and
   takes `daemon.json` away (the spike sleeps forever for that reason).
2. **Nothing can spawn it.** `Troupe.Protocol.Daemon.command/1` refuses to start a daemon
   without `TROUPE_DAEMON_COMMAND` or an explicit `:command` — "this repository ships no
   client". Every client has to say what binary to run, and with the idle shutdown at
   ten minutes it will have to say so often.
3. **The reaper.** `shell`, `grep`, worktree creation — every OS process — needs the
   `reaper` helper for the host triple in `priv/reaper/`. Decision 323 limits a server
   release to the two Linux triples; a laptop binary needs macOS and Windows too, which
   `mix compile.reaper` can build (its table has all five) and which needs `zig` on the
   build host. A daemon without it fails every `shell` call with "reaper helper not
   built" — the exact failure seen on the live `dev` pod this week.
4. **Logs go nowhere.** `Protocol.Daemon` detaches the process and says it "logs to its
   own state directory"; nothing configures a file handler. A daemon started by a client
   has no stdout anybody reads.
5. **Configuration is a pod's.** `Troupe.Config` reads `config.yaml` (global and
   `.troupe/`), `TROUPE_PROVIDER/MODEL/BASE_URL/API_KEY`, and knows `anthropic`,
   `openai`, `fake`. It has no model catalog, no opencode fallback, no usage log, no
   headroom — `troupe-tui/lib/troupe/config.ex` (808 lines against 204) and `llm/catalog.ex`
   are what a laptop that pays for tokens has today. `usage_sink` is `nil` on a laptop by
   design, so nothing is recorded.
6. **Four agent definitions, not twelve.** `priv/agents/` here has `build`, `explore`,
   `general`, `plan`; the TUI ships eight more (`code`, `reviewer`, `implementer`,
   `librarian`, `quick`, `answer`, `ask`, `workflow`, `worktree`). Global
   `~/.config/troupe/agents/` and project `.troupe/agents/` are honoured, so nothing
   blocks — the product differs.
7. **Tools.** The core lacks `ask_user`, `web_fetch`, `git_read`, `glob`, `read_output`,
   `remember`, `read_branch`; it has `publish`, `import`, `output` the TUI lacks. Policy
   for `web_fetch` on a pod is an egress question (`docs/egress-allowlist.md`).
8. **`private_sessions` is false on a laptop until three things hold**: a client has
   called `identity.link`; `Gateway.Plane` holds a plane token (in memory, re-linked
   after every restart); and the OpenBao address the plane hands back in
   `session.assertion` is reachable from off the cluster. Today it is
   `openbao.troupe-system.svc`, which is a deployment item, not code.
9. **Discovery path vs. PROTOCOL §1.** The code writes `%LOCALAPPDATA%\troupe\daemon.json`
   (and, since `LOCALAPPDATA` is checked before `XDG_RUNTIME_DIR`, honours it on any
   platform where it is set); §1 says `%LOCALAPPDATA%\troupe\run\daemon.json`. One of them
   moves; the GUI's `findDaemon` and the TUI's discovery must agree with the winner.
10. **Windows is untested here.** `Endpoint` probes `AF_UNIX` at runtime and falls back to
    loopback TCP; the spike ran on Linux (WSL). The TUI's Burrito Windows target and the
    `x86_64-windows` reaper triple exist; nothing has run the daemon on Windows yet.
11. **Node 20 has no global `WebSocket`.** `@troupe/client` needs `WebSocketImpl` passed
    on Node below 22; a Tauri webview and a browser are fine. Only matters for scripts.
12. **Two `open`s race in the client.** `DaemonClient.open` registers the view after an
    `await`, so two concurrent opens of one session create two views and the last one
    wins. Harmless for the GUI (one view per session); the spike hit it. Worth a guard
    in `@troupe/client`.

Not on the list because they are by design and already right for a laptop: `kind:
local` and `visibility: private` in `session_created`; `Troupe.Identity` naming the
person `local:<username>` until linked; `attribution: %{}` (nobody to bill);
`Worktrees.resolve` falling back to the plain workspace outside a git repository.

## Phase 1 — what landed here

The binary lives in the `troupe` repository (Decision 639; sections 7.1 and 7.2 of the
brief, as answered). What this repository had to change for that, and what proves it:

| item | change | proof |
|---|---|---|
| 1 — a release | none here, by decision; the three apps compile as another project's sparse git dependencies: `version/0` and `Troupe.Version` fall back to `TROUPE_VERSION`, `harness/1` declares siblings, the reaper source moved into `troupe_core` | `mix troupe.boundaries` reads `harness/1`; `Troupe.VersionTest` unchanged; `troupe/daemon/` builds from these |
| 2 — three transports | the TCP listener publishes its bound port (Decision 642) | `tcp_transport_test.exs` (TCP: bound port in `daemon.json`, token admits, wrong token refused), `daemon_test.exs` (Unix socket), `loopback_test.exs` (WebSocket, origin fence) |
| 3 — one on-disk format | already so; `Troupe.Sessions.Sealer` is in `troupe_protocol` | `storage_test.exs`, `private_test.exs` |
| 4 — a laptop's configuration | `Troupe.Config` gained named providers, the opencode fallback and the model catalog; `Config.target/2`; requests aimed per model; bearer auth on the Anthropic adapter (Decision 640) | `config_providers_test.exs` (19 tests), `providers_test.exs` "auth schemes" |
| 5 — honest capabilities | already so | `daemon_test.exs` handshake |
| 6 — packaging | in `troupe/daemon/` | that repository's release workflow and smoke |
| 7 — eval-safe config | no `to_existing_atom` on environment values here; the daemon's `runtime.exs` is in `troupe/daemon/` | Decision 634's test |
| 8 — README | says what the repository ships now | — |
| spawn (list item 2) | `Protocol.Daemon.command/1` finds `troupe-daemon` on the `PATH` (Decision 641) | — |
| discovery path (list item 9) | `PROTOCOL.md` §1 now matches the code and the Tauri shell | — |

Still open from the list above and deliberately not here: logging for a detached daemon
(the release's `runtime.exs`), the twelve agent definitions and the TUI-only tools
(phase 3), `private_sessions` needing an off-cluster OpenBao address (deployment).

## Phase 2 — what the harness needed

Two things. `agents.list {workspace}` (Decision 645), so a client can offer the agents a
session may be created with. And a JSON fake script with per-agent `routes` (Decision 644), so a client
that speaks only the protocol can drive a deterministic multi-agent session by putting
`provider: fake` and `fake_script:` in the workspace's `.troupe/config.yaml`. The
daemon still refuses `provider` from a client; the machine chooses it.

## Phase 3 — what the harness lacked, feature by feature

Each row of the plan's phase 3 table is its own change here, behind a capability where a
worker may not have it, and the TUI takes it up through the protocol in a PR of its own.

| row | here | proof |
|---|---|---|
| branches | a branch is a session with `parent` (Decision 646): `session.create` records it, `session.list` filters on it, `read_branch` gives the parent's agent a finished branch's prompt, summary and task list; `branches: true` at `initialize` | `branches_test.exs`, `read_branch_test.exs` |
| worktrees per branch | `worktree.merge` commits, merges with a merge commit, removes; a merge git cannot complete is aborted and answered `conflict`; `worktree.discard` removes tree and branch (Decision 647) | `branches_test.exs` |
| workflows | `Troupe.Workflow` (steps from `.troupe/workflows/<name>.json` or the default pipeline, rendered into the orchestrator's plan); the `workflow`, `implementer` and `reviewer` definitions; `session.create` with `workflow`, `workflows.list` (Decision 648) | `workflow_test.exs`, `workflows_test.exs` |
