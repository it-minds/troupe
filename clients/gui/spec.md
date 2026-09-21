**Troupe GUI: one client for team, local, and private sessions**  
This extends ../../spec.md and assumes the remote's stages 1–4 and stage 5 (bundles, skills, MCP servers, unattended sessions, service principals, the A2A facade) are finished and green. Same rules apply: work autonomously, do not ask me questions, record every judgment call in DECISIONS.md, and prove every done item with command output.  
The goal is a graphical client that is the first thing a person opens and the last thing they close: their team's sessions on remote workers, the sessions running in the daemon on their own machine, and the sessions that are theirs alone, sealed to the remote under their own key so they follow them to another device. It signs in once, shows one list, and speaks nothing but the protocol.  
Build in four stages. Each stage ships on its own, and a stage is not started until the previous one is green.  
**Invariants**  
The GUI is a protocol client and nothing else. Everything it can do, a program written from PROTOCOL.md can do; there is no private endpoint, no bundled server, and no path that bypasses the plane's grants or a worker's access checks. It holds no session state of its own: every view is a fold over events it subscribed to, and closing it loses nothing.  
It holds no long-lived secret. The identity provider's refresh token lives in the operating system's credential store when a desktop shell provides one and in memory otherwise; plane tokens and pod tokens are short-lived and never written to disk. A local daemon's token is read from the file the daemon writes, never copied.  
A private session runs in the daemon on the person's machine, never on a worker, and is sealed under a key only that person's identity can read. The plane lists it and presigns its storage; the plane never holds its key and never sees its content. Nothing in this spec may weaken these rules or the remote's.  
**Architecture**  
   
  ┌──────────────── GUI (Vite + React, TypeScript) ─────────────────┐  
  │  @troupe/client   protocol: JSON-RPC/WS, PlaneClient, SessionView│  
  │  fleet store      one list: team ∪ local ∪ private, folded       │  
  │  views            Sessions · Session · Review · Approvals · Admin│  
  │  shells           browser (plane only) · Tauri (desktop + daemon)│  
  └───────┬──────────────────────┬─────────────────────┬────────────┘  
          │ https /rpc, /auth     │ wss /v1/socket       │ ws 127.0.0.1 /v1/socket  
          ▼                       ▼                     ▼  
        plane                  worker pods          local daemon (troupe)  
    lists, places,           team sessions          local + private sessions  
    presigns, mints                                 seals private ones to object storage  
   
Three packages in one pnpm workspace: packages/client (the protocol in TypeScript, browser and Node), packages/bench (the throughput test), apps/desktop (the GUI). The desktop app is a plain web bundle; a Tauri shell wraps it and adds two things a browser cannot do: read the daemon's daemon.json to find the loopback port and token, and keep the refresh token in the OS credential store. The browser build works against a plane alone and says so on the connect screen.  
Boundaries are enforced by the build: apps/desktop imports @troupe/client and nothing from the platform's code in ../../apps; @troupe/client depends on no framework; nothing in the GUI reads a file under $TROUPE_STATE_HOME except daemon.json.  
**How the GUI maps onto the protocol**  
**Fleet store.** One store, three sources. The plane's sessions.list plus a summary subscription fed from its index; the daemon's session.list plus a fleet subscription; and, for private sessions, the plane's rows joined with the daemon's copies by session id. Every row carries kind (team | local | private), state, status, done_reason, pending_approvals, cost, and for private sessions sync (synced | pending | conflict | this-device-only). The merge is client-side; no server merges anything.  
**Session view.** One SessionView per open session over the connection that owns it: a worker socket for team sessions, the daemon socket for local and private. It subscribes at detail from the last seq it processed, folds durable events into a transcript, paints llm_delta ephemerals, and reconciles optimistic sends on input_accepted carrying its command_id. On resync_required it resubscribes from its cursor. On auth.expiring it calls token.mint on the plane and auth.refresh on the same socket.  
**Connections.** At most one socket per session and one per daemon. Pod tokens are per session; the store keeps them in memory only. A connection that closes is reopened from the plane's session.open with the mode the view needs: read for looking, activate for typing.  
**Stage 1: the shell, team sessions, and sign-in**  
**Sign-in.** The Plane tab runs the device authorization grant against the provider the plane's /.well-known/troupe names: it shows the code and the link, polls with backoff and honours slow_down, exchanges the id token at /auth/exchange, and persists the rotated refresh token. Signing out forgets it. A plane whose TROUPE_CORS_ORIGINS does not name the GUI's origin is reported as exactly that, with the origin to add.  
**Sessions list.** Every session the person can see, from sessions.list and the summary subscription, with kind, state, status, title, profile, last activity, cost, and pending approvals; filters by state, profile and status; a New session action that shows, before creating, what a profile carries (profiles.list: agents, skills, MCP servers, bundle version) and lets the person choose the agent.  
**Session.** Transcript with user and assistant messages, tool calls as collapsible blocks with arguments and results, blobs fetched on demand with blob.get, approvals inline with allow / allow for session / deny, presence of other people, the agent's state and the bundle version it runs under, cancel, profile switch, and a composer. A second GUI on the same session sees the same order.  
**Files.** fs.list and fs.read over the session's mounts, read-only in this stage, and the fs_changed feed.  
**Approvals.** A global inbox over the summary subscription: every approval waiting on the person across every session, answerable without opening the session.  
**Stage 2: local sessions over loopback**  
**Server change (the platform, `../../apps`).** The daemon starts Troupe.Gateway.Web on 127.0.0.1 at an ephemeral port and writes {"transport": "ws", "port", "token"} into daemon.json beside the TCP entry. The upgrade admits only http://localhost:* and the desktop shell's origin, through the TROUPE_ALLOWED_ORIGINS mechanism workers already have. The daemon accepts identity.link {subject, display_name, plane_url} on the local socket (admin scope, which the local principal has); thereafter its principal is the person, every actor in the log names them, and session_created carries kind and owner. identity.unlink reverses it.  
**Desktop shell.** Finds daemon.json, spawns the daemon on demand the way the CLI does (a lock file, one daemon), and connects with the token in auth.token. The browser build offers a Connect to local dialog that takes the port and token instead.  
**One list.** Local sessions appear beside team sessions with kind local; New session offers a directory picker (shell) or a path field (browser) for the workspace, the worktree choice, watch mode, and the agent. session.list gains a kind filter and the daemon's fleet carries kind.  
**Local-only features.** Watch mode toggle, worktrees list and remove, workspace.recent and workspace.search, client-hosted tools: the shell reads the person's mcp.json and offers each server per session behind the consent challenge, exactly as the TUI does.  
**Stage 3: private sessions that follow you**  
**Server changes (the platform, `../../apps`).** The worker's Sealer moves to troupe_protocol and the daemon uses it for sessions created with config.private: true: segments, snapshots, workspace tars, blobs, a plaintext manifest, under sessions/<id>/ as a worker would write them. The key path gains troupe/people/<subject>/sessions/<id>; OpenBao gets a JWT auth role troupe-person bound to the identity provider's issuer with a policy templated on the subject; no pod role reads under people/, and the plane's delete-only policy widens to cover it. The plane gains session.register {session_id, kind: "private", device, head_hash, last_seq} creating a row with no team, the caller as owner, visibility private; session.seal-report updating last_seq, head_hash and object_bytes; session.presign {session_id, keys, method} answering short-lived PUT and GET URLs for the caller's own private sessions only; and a conditional epoch bump on session.register with mode activate. Three log fixes: start_session appends session_created only when the log is empty and session_resumed otherwise; local resume falls back to <state>/workspaces/<id> when the recorded directory is missing and an archive exists; session_created carries kind and owner.  
**Creating.** A Private checkbox on New session, and Start syncing on an existing local session. Both need a linked identity and a signed-in plane; without them the control says why.  
**Sealing.** The daemon seals every 500 events or at dormancy and archives the workspace on the worker's five-minute cadence; the GUI shows sync as pending until the plane row reflects the head hash, then synced.  
**The other device.** Signing in lists private sessions from the plane rows. Opening one downloads manifest and live segments through presigned GETs, verifies the chain, and serves history from the daemon with no agent started. Resume here restores the workspace tar under <state>/workspaces/<id>, logs session_resumed with moved: true and the device name, and continues; Bind to a directory records a mounts_resolved with the chosen root instead of extracting.  
**Conflict.** Two devices resuming within the same epoch is fenced by the plane: the loser sees stale_version on its next seal report, stops sealing, marks its copy conflict, and the GUI names the device that has it. Nothing is merged; the loser's local log stays read-only until archived.  
**Erasure.** session.erase on a private session destroys the key's metadata through the plane and every object version under the prefix, then removes the local copies on every device the next time they sign in.  
**Stage 4: HQ, review, and administration**  
**Review.** A Review view over sessions.list(origin: trigger, needs_review: true) grouped by trigger: title, fired at, status, done reason, cost, pending approvals, the run's filtered event; open, answer, mark reviewed with session.review. Runs that ended in budget_exhausted or llm_error first. The same view lists A2A-created sessions under origin: a2a.  
**Fleet health.** Per profile: pods, capacity, health, bundle version and adoption, from profiles.list and admin.overview when the person is an admin.  
**Administration, for admins only.** Views over the admin.* methods and nothing else: bundles (current version's agents, skills and MCP servers; publish JSON with validation errors inline; adoption per pod), teams and grants, service principals and triggers (create, rotate, disable; enable, run now, history), audit. Each view calls one public method per action and shows the audit row it produced.  
**Forbidden**  
- Any call that is not a public protocol or plane method.  
- A refresh token, plane token, pod token or daemon token written to disk by the GUI.  
- The plane holding, seeing, or being asked for a private session's key or content.  
- A private session running on a worker, or a worker profile involved in one.  
- Merging two devices' logs. Fencing decides; nothing is reconciled.  
- Session content in analytics, crash reports, or logs the GUI emits.  
- A bundled copy of the daemon, the plane, or any server code inside the GUI.  
- An admin view reachable by a non-admin, or one that shows session content.  
**Working order**  
For each stage, update ../../PROTOCOL.md for any new method or field first, land the server change in `../../apps` with its own tests, in the same pull request as the client change, then write the stage's done items as failing tests here, then implement until green.  
Stages 1 and 4 run against the kind cluster from ../../scripts/remote-up. Stages 2 and 3 run against a daemon built from this repository (`../../apps/troupe_daemon`) with the Fake provider, and stage 3 additionally against the kind cluster's MinIO and OpenBao with the JWT auth role configured by ../../dev/kind/dependencies.yaml. The Fake provider stays the model for every automated test; browser tests run under Playwright in CI.  
**Done means all of these pass, with command output shown**  
Stage 1:  
1. From a clean profile, sign in against the kind cluster's Dex, list sessions, create one on the dev profile choosing the plan agent, send a prompt, and watch the answer stream; the rotated refresh token is persisted and a relaunch needs no new sign-in.  
2. A plane without the GUI's origin in TROUPE_CORS_ORIGINS produces the exact message naming the origin; adding it makes the same build work with no other change.  
3. Two GUIs on one session each send 50 inputs; both transcripts are identical in order and author, and every optimistic send reconciles on its input_accepted.  
4. The approvals inbox lists approvals from three sessions without any of them open; answering one from the inbox continues that session's turn; a second answer from another GUI shows approval_resolved and has no effect.  
5. A pod token's auth.expiring is followed by token.mint and auth.refresh on the same socket, and a turn in progress is not interrupted; with refresh disabled, the socket closes after exp and the view reconnects from its cursor with no gap and no duplicate.  
6. A blob over 16 KiB in a tool result is fetched with blob.get on expand, by range, and never on transcript load.  
Stage 2:  
1. The daemon writes a ws entry into daemon.json; the desktop shell connects with its token; an upgrade from http://evil.example is refused at the handshake.  
2. One list shows a team session and a local session, each labelled; the daemon's session.list {filter: {kind: "local"}} returns only the latter.  
3. After identity.link, a local session's input carries the person's subject as actor; after identity.unlink, local:<user> again.  
4. Watch mode toggled from the GUI acts on an AI comment saved in the workspace; a second session in the same workspace gets a worktree on troupe/<slug>.  
5. A personal MCP server from mcp.json is offered per session, registered only after the consent challenge is confirmed in the GUI, served through tool.invoke, and shows as session_tainted to a second GUI.  
Stage 3:  
1. A private session's prefix in object storage holds segments, snapshots, a workspace tar, blobs and a manifest; mix troupe.index.rebuild lists it; the plane row has no team, and the admin panel shows bytes and no title.  
2. A pod's KMS token cannot read a key under people/; the person's JWT-auth token cannot read a key under teams/; the plane's token can delete metadata under both.  
3. Delete $TROUPE_STATE_HOME on machine A; sign in on machine B; the session's full history renders with the chain verified and zero agents started; Resume here restores the tree and the next input continues the conversation; the log shows session_resumed with moved: true.  
4. Bind to a directory on B records mounts_resolved with the chosen root and extracts nothing; fs.read through the GUI reads the bound tree.  
5. Resume on A and B within one second: exactly one wins, the other shows conflict naming the winner, and the object store holds one live epoch.  
6. session.erase from the GUI removes every object version under the prefix and the key's metadata; both devices drop their local copies at next sign-in.  
7. Start syncing on an existing local session with 1,200 events seals it in three segments and a snapshot, and B opens it.  
Stage 4:  
1. A triggered session that asked for approval appears in Review with pending_approvals: 1 without the GUI replaying its log; answering from Review completes the turn; mark reviewed records reviewed_by and an audit row.  
2. A non-admin's build shows no admin navigation and every admin.* call returns forbidden; a team_admin sees their team's sessions and spend and nothing else; a platform_admin sees everything and no session content.  
3. Publishing a bundle with a bad definition from the GUI shows the validation error inline and publishes nothing; a valid one shows adoption reach every pod within 10 s.  
4. Creating a service principal shows its secret exactly once; the same view never shows it again; rotating it makes the old one fail within one token lifetime.  
**Out of scope**  
Sharing a private session with another person (it becomes a team session by import, a later plan), sync of plain local sessions, a mobile build, notifications outside the app, editing files in the GUI, and a terminal. Keep them possible: the fleet store must not assume a session has one owner forever, and the file view must not assume read-only mounts.  
**Final report**  
Each done item with the command that proves it, every deviation with its DECISIONS.md entry, the Tauri-versus-browser decision with what each shell can and cannot do, measured time from sign-in to first streamed token on kind, and known limitations per stage.  
