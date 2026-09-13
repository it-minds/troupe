**Troupe Remote: daemon, protocol, remote workers, and control plane**  
This extends ../troupe/spec.md and assumes that build is finished and green. Same rules apply: work autonomously, do not ask me questions, record every judgment call in DECISIONS.md, and prove every done item with command output.  
The goal is to move sessions out of the TUI process, first into a local daemon, then into remote workers on Kubernetes. An Elixir control plane and an Elixir operator orchestrate those workers. Platform admins get a panel where they see configured workers, provision new ones, and grant teams access. Users sign in from their harness, their teams are discovered, and they see the workers and sessions available to them. Several harnesses can attach to the same session and see the same work.  
Build in four stages. Each stage ships on its own, and a stage is not started until the previous one is green.  
**Invariants**  
A session has exactly one authority: its actor tree, fed through one mailbox. The session log is the session: every client view, every restart, and every audit is a fold over it. Clients are subscribers and never backpressure an agent. No orphans, no agent-to-agent synchronous calls.  
Organisational state (users, teams, grants, budgets, config bundles, session index) lives in the plane. Infrastructure desired state (what runs where, with which image, volumes, and egress) lives in Kubernetes. Neither is a second source of truth for the other. Session content lives in object storage, encrypted with a per-session key held only in the KMS, and pod volumes hold disposable working copies. Nothing in this spec may weaken these rules.  
**Architecture**  
                 ┌──────────────────────── troupe-system ────────────────────────┐  
  IdP ──OIDC/SCIM▶│ plane: Phoenix, 2+ replicas, clustered          ──▶ Postgres  │  
                  │   harness API (JSON-RPC/WSS)   admin panel (LiveView)         │  
  harness ──────▶ │   SCIM   JWKS   discovery      worker control (internal only) │  
  (TUI/HQ,        │ operator: leader-elected       ──▶ Kubernetes API, OpenBao    │  
   later GUI)     └───────────────────────────────────────────────────────────────┘  
     │                                   ▲ control connection (projected SA token)  
     │ wss + short-lived session token   │  
     ▼                                   │  
  <ordinal>-<profile>.workers.<domain> ──▶ troupe-w-<profile>: StatefulSet of workers,  
                                           PVC per pod (working copies), team volumes  
                                              │                        │  
                                           OpenBao: session keys    object storage: segments,  
                                                                    snapshots, workspaces, blobs  
   
Four releases come out of one umbrella. troupe is the Burrito client binary and local daemon. troupe_worker, troupe_plane, and troupe_operator ship as OCI images built from plain mix release. Umbrella apps: troupe_core, troupe_protocol, troupe_gateway, troupe_tui, troupe_ctl, troupe_worker, troupe_plane, troupe_operator.  
Boundaries are enforced by xref:  
- troupe_tui and troupe_ctl depend only on troupe_protocol.  
- troupe_plane never depends on troupe_core, because the plane does not run agents.  
- troupe_operator depends on neither the plane nor core.  
The plane and operator are separate on purpose. The plane is internet-facing and may only write WorkerProfile and TeamVolume resources. The operator holds the cluster privileges and has no public surface. Compromising the plane gets an attacker requests that still pass policy, not a cluster.  
**How the orchestration maps onto actors**  
**Operator.** Built on Bonny 1.5 over the k8s client. Spike it on 1.20 first; if it fails, write plain watch-and-reconcile GenServers on k8s and record why. It runs one reconciler process per WorkerProfile and per TeamVolume under a DynamicSupervisor, driven by watch events plus a periodic resync. Reconciliation is level-triggered and idempotent, so a crash only ever means reconciling again from current state. A Kubernetes Lease elects the leader.  
**Plane.** Replicas cluster via libcluster with the Kubernetes DNS strategy, over Erlang distribution confined to plane pods by NetworkPolicy. It runs one process per worker control connection, per harness connection, and per LiveView. Serialisation points are cluster-unique actors registered with :global:  
- One Placement actor per profile serialises capacity reservations, so there is no overbooking and no locks.  
- One TeamBudget actor per team serialises spend reservations.  
Their durable state lives in Postgres, so after a replica loss or netsplit resolution they respawn on a survivor and reload. Worker presence is :pg groups keyed by profile, so any replica can reach any pod's connection. Singleton jobs (GitOps committer, retention) hold Postgres advisory locks.  
**Workers.** Session trees are unchanged. One Plane.Link process holds the control connection and reconnects with backoff. Losing it never affects running sessions.  
**Stage 1: protocol and local daemon**  
**Structure and daemon**  
Troupe.Events becomes internal to core. The built-in TUI is the first protocol client and gets no private access: if it cannot do something through the protocol, nobody can.  
troupe daemon owns all sessions for the user:  
- **Auto-spawn.** Clients spawn it on demand, using a lock file so concurrent clients start exactly one.  
- **Idle shutdown.** It shuts down after a configurable idle period with no running sessions and no clients.  
- **Restart.** A restart restores all sessions from their logs. A session that was mid-turn comes back interrupted and makes no LLM call until new input arrives, unless config opts into resume.  
- **Dormancy.** Local sessions follow the lifecycle defined in stage 2, minus the object tier and KMS. After the idle timeout the actor tree stops, subscribing serves history from the log without starting agents, and the next activating command restarts the tree. Local files rely on the user's disk encryption.  
**Transport and handshake**  
JSON-RPC 2.0. Locally, newline-delimited JSON over a Unix socket at $XDG_RUNTIME_DIR/troupe/daemon.sock with mode 0600. On Windows, loopback TCP with a random token in a user-only file, unless OTP 28 supports AF_UNIX there (decide and record). Remotely, WebSocket with one JSON-RPC message per text frame. The messages are identical on every transport.  
A connection starts with initialize. The client sends protocol_version, client_info, and capabilities. The server answers with its info, the negotiated version, its capabilities, the authenticated principal, and the granted scopes.  
**Events**  
Durable events carry seq (monotonic per session), prev_hash, ts, actor (the principal who caused it, or system), agent (the agent path), type, and data. They are persisted and replayable.  
Ephemeral events (LLM deltas, progress, presence) have no seq, are never persisted, and may be dropped. Every completed LLM message also lands as a durable event, so dropping ephemerals loses nothing.  
Payloads are semantic: markdown text, diffs as structured hunks, tool calls and results as objects, and todo lists as data. They never contain ANSI codes, layout, or client state. Tool results over 16 KB become {"blob": "sha256:...", "preview": ...} and are fetched with blob.get, which supports byte ranges.  
**Subscriptions**  
subscribe takes:  
- a topic: fleet or session:<id>  
- a level: summary or detail  
- an optional from_seq  
It returns head_seq, replays durable events from the cursor, then switches to live delivery with no gap and no duplicate at the boundary.  
Every session tree gains a Session.Summary projection actor. It folds the session into a compact snapshot: per-agent state and profile, current todo item, active tool, tokens, cost, pending approvals, and last error. It publishes throttled diffs, at most 4 per second, to a :pg group. fleet carries only session lifecycle events.  
**Commands**  
session.create, session.list, session.get, session.archive, input.send, turn.cancel, profile.switch, approval.respond, todo.edit, blob.get, worktree.list, worktree.remove, workspace.recent, workspace.search, watch.set, session.pin, session.unpin, session.erase.  
Every command carries a client-generated command_id. The response is an acknowledgement, never the effect itself. Effects arrive as events carrying the originating command_id. Replaying a command_id is a no-op that returns the original acknowledgement.  
PROTOCOL.md defines a stable error code table, including forbidden, not found, conflict, stale version, capacity, and resync required.  
**Scopes**  
- observe: subscribe and read.  
- control: inputs, cancel, approvals, todo edits, and profile switch.  
- admin: create, archive, worktrees, and fleet settings.  
Locally, socket permissions authenticate the user. troupe ctl token --scope observe mints read-only tokens for status bars and similar.  
**Backpressure and versioning**  
Each connection is its own process with a bounded outbound queue. Under pressure it coalesces ephemerals, then drops them. If the durable backlog passes the bound, it sends resync_required and drops the subscription, and the client re-subscribes from its last seq.  
Protocol structs generate JSON Schema into protocol/schema/v1/, committed to the repo. Changes are additive only within a major version, and clients must ignore unknown event types and fields. mix troupe.schema.diff fails on any removed field, renamed field, changed type, or newly required field.  
**Workspaces and clients**  
**Worktrees.** session.create in a workspace that already has a live session defaults to a new git worktree on troupe/<slug>. worktree.remove refuses a dirty tree unless forced.  
**Watch mode.** Exclusive per workspace.  
**Budget.** The daemon holds a fleet budget and allocates a slice at session.create.  
**troupe** **.** Attaches to or creates a session for the current directory.  
**troupe hq** **.** Mission control:  
- a fleet table: repo, branch, profile, status, tokens, cost, age  
- drill-down into agent trees and plans  
- a global approvals inbox  
- notifications when a session blocks or finishes  
- a launcher: recent workspaces or fuzzy directory search, then profile and prompt  
Enter swaps full-screen into that session's TUI and Esc returns.  
**troupe ctl** **.** Exposes every command with --json output.  
**Documentation and reference client.** PROTOCOL.md is standalone for third-party client authors: someone must be able to write a client from it without reading any Elixir. clients/python/troupe_client.py uses only the Python standard library and stays under 200 lines.  
**Stage 2: platform core and remote workers**  
**Hosting reference**  
Required:  
- Kubernetes 1.30 or later, for GA ValidatingAdmissionPolicy.  
- An ingress controller with WebSocket support.  
- cert-manager with a wildcard certificate for *.workers.<domain> via DNS-01.  
- Managed PostgreSQL 16.  
- RWX-capable storage (NFS or equivalent) for team and org volumes.  
- S3-compatible object storage with versioning, for the durable session tier.  
- OpenBao, or another KMS behind the Troupe.KMS behaviour, with Kubernetes auth and KV v2.  
- Point-in-time recovery on PostgreSQL, with at least 7 days of retention.  
Cilium is optional and enables FQDN egress rules. Without it, generate standard NetworkPolicy and document the limitation. Secrets are created out of band or by External Secrets Operator; Troupe only references them.  
Document Scaleway Kapsule with managed PostgreSQL as the tested reference. Keep all code provider-neutral.  
Ship a Helm chart charts/troupe with the CRDs, the operator, the plane, a default TroupePolicy, and the admission policies. Add an example Flux HelmRelease under deploy/flux/.  
**Custom resources**  
**WorkerProfile** (namespaced, in troupe-system) fields:  
- image (repository plus digest or tag)  
- replicas, sessions per pod, resources  
- LLM endpoint and secret reference  
- MCP servers, each with name, URL, and secret reference  
- egress FQDN patterns and git hosts  
- config bundle channel  
- orgMount: whether the org volume from TroupePolicy is mounted, always read-only  
- teams: each granted team's volume and mode  
The plane is the only writer of teams. It derives the field from team grants, so the field is a projection of plane state, not a second source of truth.  
**TeamVolume** (namespaced, in troupe-system): team name, backing storage class or NFS path, and size. The plane creates it when a team is enabled.  
**TroupePolicy** (cluster-scoped, owned by cluster admins, not writable by the plane): allowed image repositories, maximum replicas and resources, allowed egress patterns, allowed storage classes, the org volume source, and the namespace prefix troupe-w-. It is enforced at admission by ValidatingAdmissionPolicy (CEL) and checked again by the operator, which marks violations with a PolicyViolation condition and creates nothing.  
**What the operator reconciles, per profile**  
- Namespace troupe-w-<profile>.  
- ServiceAccount with token automount disabled, plus a projected token with audience troupe-plane.  
- StatefulSet with a PVC template and updateStrategy: OnDelete.  
- Headless Service.  
- One Service and Ingress per pod at <ordinal>-<profile>.workers.<domain>.  
- NetworkPolicy, plus CiliumNetworkPolicy for FQDNs when available. Ingress only from the ingress controller. Egress only to the plane's control Service, OpenBao, the object storage endpoint, the LLM endpoint, the MCP servers, the git hosts, and DNS.  
- PodDisruptionBudget.  
- Per-namespace PV/PVC bindings for each listed team volume, and for the org volume when enabled.  
- An OpenBao Kubernetes-auth role for the profile's ServiceAccount, whose policy allows creating and reading session keys only under the paths of the profile's granted teams.  
- Status conditions: Ready, PolicyViolation, SecretMissing, Draining, UpgradePending.  
**Pod lifecycle.** Pods only restart for image, config, or volume changes when they have no active sessions. An admin can force a restart, which drains the pod to dormant first. Until then the profile shows UpgradePending.  
**Scale-down.** Drains the highest ordinals first. The plane stops placing sessions on a draining pod, running turns finish (up to the drain timeout, after which they are cancelled), every session on the pod goes dormant, and then the pod is removed. Dormant sessions live in object storage, so scale-down strands nothing and the PVC can be deleted.  
**Worker enrollment and control connection**  
Workers dial the plane's internal control listener, which is never exposed through ingress, presenting their projected ServiceAccount token. The plane validates it via TokenReview. The namespace determines the profile, so a pod can only enroll as its own profile.  
The control channel uses the same JSON-RPC framing and carries:  
- **Heartbeats:** capacity, active sessions, PVC usage, loaded config bundle hash, version.  
- **Session index updates, metadata only:** id, owner, team, visibility, lifecycle state, status, tokens, cost, taint flags, and sealed segment heads, which double as audit anchors.  
- **Usage records:** one per LLM call, carrying the gateway request id, for the spend ledger.  
- **Plane-to-worker pushes:**config.updated, drain, session.restore, session.erase, ACL changes, JWKS rotation.  
No session content ever crosses this channel.  
**Identity, teams, and discovery**  
The plane is an OIDC relying party (oidcc) against any provider. It serves /.well-known/troupe with the issuer, client id, and endpoints.  
Users and groups arrive by SCIM 2.0 push to the plane's /scim/v2 Users and Groups endpoints. When SCIM is disabled, they are created just in time from the groups claim at login. A team is an IdP group that a platform admin has enabled as a team: via troupe admin in this stage, via the panel in stage 3. Membership always comes from the IdP and is never edited in Troupe.  
**Grants.** A grant links a team to a profile with role use. Each team also has a budget and a team volume.  
**Session visibility.** private (owner plus explicit ACL) is the default. team gives team members observe, and control if the team setting allows it.  
**Harness.** troupe login <plane-url> runs the device authorization grant and stores the refresh token in a user-only file. troupe --remote opens HQ in remote mode, laid out as teams, then granted profiles with pod health and capacity, then the sessions the user can see.  
Creating a session asks for:  
- the team context, when the user has several  
- the profile  
- a source: empty, or a git repo and ref cloned with the worker's own identity  
- visibility  
- the prompt  
HQ can show local and remote sessions side by side.  
**Plane API.** The plane speaks the same JSON-RPC for fleet-level commands: me, teams.list, profiles.list, sessions.list, session.create, session.open, session.pin, session.erase, token.mint, plus fleet and summary subscriptions fed from the session index. detail streams always go directly to the worker.  
**Placement, tokens, and budgets**  
session.create works like this:  
1. The profile's Placement actor reserves a slot on the least-loaded, healthy, non-draining pod below its disk high watermark.  
2. TeamBudget reserves the session's budget slice.  
3. The plane forwards the create to that pod over its control connection.  
4. The plane returns the pod's endpoint and a session token.  
**Tokens.** JWTs signed by the plane, with aud set to the pod's worker id. They carry sub, session_id (or a create grant), role, scopes, and team, with a lifetime of at most 15 minutes. Workers validate them offline against the cached JWKS. Before expiry, the worker sends auth.expiring, and the client calls auth.refresh on the same connection. Nothing is accepted past exp.  
**Roles and ACLs.** Roles map to scopes: owner gets admin, collaborator gets control, viewer gets observe. ACLs are durable events in the session log (acl.granted, acl.revoked), mirrored to the plane, and applied immediately to connected clients.  
**Persistence.** An active session lives on exactly one pod. Durability, dormancy, relocation, and fencing are defined under Session lifecycle and storage.  
**Audit chain.** Every durable event includes prev_hash, the SHA-256 of the previous event's canonical JSON. troupe ctl verify SESSION walks the chain offline and names the first bad seq. Sealed segment heads are anchored in the plane.  
**Session lifecycle and storage**  
**States.** A session is in one of four states:  
- active: its actor tree runs on one pod.  
- dormant: no processes. It is durable in object storage, and a pod may hold an encrypted local cache.  
- read_only: dormant and not activatable, because its profile is gone or its team lost the grant.  
- erased: a tombstone only.  
There is no separate archived state. An archived session is simply a dormant one with no local cache.  
**Storage layout.** Object storage is the durable tier. Per session, under sessions/<session_id>/:  
- segments/<epoch>-<first_seq>-<last_seq>.seg: sealed log segments, zstd JSONL.  
- snapshots/<seq>.snap: fold snapshots.  
- workspace/<seq>.*: workspace snapshots. For git-sourced sessions this is a git bundle of unpushed commits plus the uncommitted diff and untracked files, restored by re-cloning. Otherwise it is a tar archive.  
- blobs/<sha256>: tool-result and upload blobs, deduplicated within the session only.  
- manifest.json: plaintext ids only (session, team, owner subject, profile, epoch, latest segment, key path). No content.  
Everything except the manifest is encrypted with the session's data key. The pod PVC holds working copies: the open segment, the plaintext workspaces of active sessions, and encrypted caches of dormant ones.  
**Sealing.** The worker seals and uploads a segment at every turn completion, and at least every 60 seconds while events are pending, then reports the sealed head to the plane. Losing a PVC therefore costs at most the unsealed tail. If the plane is unreachable, sealing continues and the reports are replayed later. The manifests in object storage are enough to rebuild the plane's session index, which troupe admin index rebuild does.  
**Keys.** Each session gets a random 256-bit data key. The worker creates it at session.create and stores it only in OpenBao KV v2 at troupe/teams/<team>/sessions/<session_id>. Workers authenticate through OpenBao's Kubernetes auth and hold keys in memory for active sessions only, never on disk. The plane's OpenBao policy allows destroying key metadata but never reading keys, so even a compromised plane cannot decrypt session content. JWT signing keys also live in OpenBao, as transit keys, and the plane signs through it.  
**Going dormant.** A session goes dormant after the team's idle timeout (default 30 minutes) with no running turn. The worker then:  
1. Seals the final segment.  
2. Writes a snapshot.  
3. Archives the workspace.  
4. Uploads all three.  
5. Reports session.dormant to the plane.  
6. Deletes the plaintext workspace.  
7. Stops the actor tree.  
Pending approvals do not block dormancy. They are durable events and survive it.  
**Disk.** Dormant caches on the PVC are evicted in least-recently-used order above the disk low watermark (default 70%). Placement skips pods above the high watermark (default 80%). Active workspaces are never evicted. Per-session workspace size is measured, and exceeding the soft quota blocks new turns with a visible event.  
**Reading.** Subscribing to a dormant session never activates it. The plane's session.open with mode read picks a pod of the session's profile, preferring one with a cache. That pod serves history through a short-lived Session.Reader process: no Agent.Server, no LLM call. The reader exits after its last subscriber leaves.  
**Activating.** input.send, approval.respond, todo.edit, and profile.switch activate a dormant session. The harness calls session.open with mode activate, and the plane:  
1. Checks the ACL.  
2. Asks the profile's Placement actor for a pod, preferring the one with a warm cache.  
3. Increments the session's epoch in PostgreSQL, conditional on the session still being dormant.  
4. Pushes session.restore with the new epoch to that pod.  
5. Returns the endpoint with a token whose audience is that pod.  
Activation needs the plane. Live sessions do not.  
On the pod, activation is lookup-or-start. The session's Registry name either resolves to a running tree, or the tree is started under the DynamicSupervisor, and a racing second start gets {:already_started, pid}. The tree loads the newest valid snapshot, replays only the tail segments, restores the workspace, and appends:  
- session.activated, with the epoch and pod.  
- session.resumed, with how long it was dormant and whether it moved. This tells the model that no processes, shell state, or environment from before survived.  
- config.upgraded, only when the pinned bundle version is no longer valid, in which case the session moves to the channel's current version.  
If the context exceeds the compaction threshold, compaction runs before the first LLM call.  
**Fencing.** Epochs are minted only by the plane. Segment object keys include the epoch, the plane rejects seal reports from stale epochs, and index rebuilds follow the highest epoch's contiguous chain. A pod that reconnects after being presumed lost is told which sessions it still owns, and it terminates the rest and discards their caches before serving anything.  
**Pod loss.** When a pod misses heartbeats past the lease timeout, the plane marks its active sessions dormant as of their last sealed segment. Activating one elsewhere bumps the epoch.  
**Snapshots and log compatibility.** Snapshots are written at dormancy and every 500 events. They are pure cache: any mismatch in snapshot format or code version discards the snapshot and forces a full replay. Every event carries a schema version v, and replay runs old events through an upcaster chain, Troupe.Log.Upcast. Fixture logs from every released version live in test/fixtures/logs/<version>/, and CI replays each one to a recorded fold hash.  
**Retention.** Retention is configured per team:  
- idle timeout  
- cache eviction age (default 7 days)  
- erase-after since last activity (default 12 months)  
Owners can pin a session to exempt it. Pins are audited and visible to team admins, and a team policy can disallow them.  
**Erasure.** Erasure runs from a singleton job, or on session.erase from the owner, a team admin, or a platform admin. It:  
1. Destroys the session's key in OpenBao, all versions.  
2. Deletes the session's objects.  
3. Pushes session.erase to pods holding caches. A pod applies pending erasures on enroll, before serving anything.  
4. Writes a tombstone with the final head hash, reason, and actor.  
Once the key is destroyed, no copy in object storage, PostgreSQL, PVCs, or their backups can be decrypted. The only residual is OpenBao's own backups, whose retention must not exceed the documented erasure SLA (default 30 days).  
**Plane database.** At minimum:  
- users, groups, memberships, teams, grants  
- team budgets and retention policies  
- config bundles and versions, and profile channels  
- sessions: id, owner, team, profile, visibility, state, epoch, pod, last active, last seq, head hash, object and workspace bytes, pinned, retention class, bundle version  
- a session ACL mirror, anchors, tombstones, and the audit log  
- an append-only usage ledger: session, team, owner, model, tokens, cost, and gateway request id, unique on request id  
TeamBudget reserves against the ledger. A nightly job reconciles the ledger with the gateway's spend records and reports drift above a configured threshold. Backups use PITR, and a restore drill is a done item.  
**Worker runtime**  
**Mount table.** Resolved at session.create:  
- session:/ is private and read-write on the PVC.  
- team:<name>/ is the session's team volume, ro or rw per grant.  
- org:/ is the org volume from TroupePolicy, always read-only, when the profile enables it.  
The resolved table is a durable event. File tools resolve every path through it. shell runs under bubblewrap, launched by reaper, with only the session's mounts bound at their modes, private /tmp and /proc, and --die-with-parent. Pods mount the union of their granted team volumes. Each session sees only its own team context.  
publish and import are the only tools that copy between session:/ and shared roots. They default to ask, and each copy is a durable event with source path, destination path, and hash.  
**Files over the protocol.** fs.list, fs.read, and fs.upload are resolved through the mount table and scope-checked. Durable fs.changed events (path, hash, size, actor) fire for every change in session:/, including changes made by shell, which an inotify watcher inside the pod catches.  
**LLM and MCP.** The worker holds the profile's LLM credential. Every request is tagged with the session owner as end user, plus team and session id as metadata. Collaborator inputs are billed to the owner's team budget; record this as the default policy in DECISIONS.md. The MCP client is a Troupe.Tool adapter using streamable HTTP. System MCP servers authenticate with service credentials from the referenced secrets, and user tokens are never forwarded to them. Their tools appear as mcp.<server>.<tool> under the same allowlists, permissions, and approvals as built-ins.  
**Config bundles.** A bundle is a versioned set of agent definitions, skills, tool allowlists, and MCP server entries (secret references only), stored in the plane and assigned to profiles by channel. Publishing pushes config.updated. Workers fetch the bundle, verify its hash, and apply it to new sessions. Running sessions stay on the version recorded in session.created. Heartbeats report the loaded hash, and any mismatch with the published version surfaces as a condition.  
**Stage 3: admin panel and self-service provisioning**  
The panel is Phoenix LiveView in the plane at /admin, behind OIDC login. There are two roles:  
- platform_admin, from an IdP group named in config.  
- team_admin, assigned per team by a platform admin.  
Pages:  
- **Overview:** fleet health, active sessions, spend per team.  
- **Workers:** profiles with conditions, pods with load and drain state, image versions, drain and upgrade actions, and an effective config view that combines the CR spec, the policy verdict, and the published versus reported bundle hash.  
- **Profile editor:** a form that renders the resulting CR as a diff before applying.  
- **Teams:** enable IdP groups as teams, manage grants, budgets, volumes, retention, and default visibility, and see pinned sessions. Members are read-only.  
- **Sessions:** metadata only, including lifecycle state, storage size, and pins, with erase for authorised roles.  
- **Config bundles:** edit, import from a git ref, publish, and roll back.  
- **Audit:** who changed what, with diffs.  
**Provisioning modes**  
Both modes use the same form, the same validation, and the same audit trail.  
**Direct.** The plane's ServiceAccount may only create, update, and delete WorkerProfile and TeamVolume in troupe-system, and read TroupePolicy. Nothing else.  
**GitOps.** The plane commits CR manifests to a configured repo path with a deploy token, and Flux applies them. The panel shows Pending until the CR's observedGeneration matches the committed generation.  
The panel validates against TroupePolicy for fast feedback. Admission and the operator remain authoritative.  
**Rules**  
- **Secrets.** The panel stores and shows secret references only, never values. A reference to a missing secret shows the SecretMissing condition.  
- **Session content.** No admin role grants access to session content. Reading content requires being on the session's ACL. Break-glass access is out of scope.  
- **Parity.** Every panel action goes through the Plane.Admin context, which is also exposed as admin JSON-RPC and through the troupe admin CLI. LiveViews call nothing else, and xref enforces it.  
**Stage 4: collaboration and client-hosted tools**  
**Several harnesses, one session**  
Any number of clients with the right role can attach to one session. All inputs enter the session actor's mailbox, so the log order is the single order everyone sees.  
- An input sent while the agent is busy produces a durable input.queued, visible to all.  
- When the session takes an input, input.accepted carries the author and the command_id, so clients can render optimistically and reconcile.  
- Presence (joined, left, focused agent, typing) is ephemeral only.  
- Any control client can cancel a turn.  
- Approvals are first-wins. Later responses get approval.resolved, naming who resolved it.  
**Client-hosted tools**  
A harness can offer locally hosted tools, typically personal MCP connections, to a session it is attached to. tools.register requires control scope and a consent step: the worker issues consent.challenge, the harness shows it to the user, and the registration carries the user's confirmation. The worker then appends tools.registered and session.tainted (kind personal_connector, with actor and tool names), and every participant's summary shows the taint.  
Invocation is a server-to-client tool.invoke request sent over the registering connection. That connection process owns the tool, and the agent's tool task monitors it under the tool timeout. On disconnect or timeout the call returns an error result and the agent keeps running. A dropped registrant also triggers tools.unregistered. Only the registering connection can serve its tools.  
The TUI implements the harness side. It reads personal MCP servers from local config and offers them per session when the user opts in.  
**Forbidden**  
- Erlang distribution reachable from outside the plane's own pods.  
- The plane in the data path of a live session.  
- The plane holding cluster privileges beyond writing WorkerProfile and TeamVolume.  
- An operator with a public endpoint.  
- Session content in the control channel, the plane database, or the admin panel.  
- Secret values anywhere in the plane.  
- Team membership edited in Troupe.  
- User tokens on system MCP calls.  
- Path checks as the only enforcement for shell.  
- Any client, including our own TUI and panel, using anything but public APIs.  
- Presence or deltas in the durable log.  
- Key material in PostgreSQL, object storage, or on any PVC.  
- A plaintext workspace left on a PVC after its session goes dormant.  
- Blob deduplication across sessions, which would let one session's key protect another's data.  
- Any plane credential that can read session keys.  
**Working order**  
For each stage, update ARCHITECTURE.md and PROTOCOL.md first, then write the stage's done items as failing tests, then implement until green.  
Stage 2 and later run on a local kind cluster started by test/e2e/kind.sh, with:  
- a mock OIDC issuer  
- a SCIM push script standing in for the IdP  
- a mock LiteLLM endpoint  
- a mock MCP server  
- an in-cluster NFS provisioner for RWX  
- a bare git repo standing in for the GitOps remote  
- an S3-compatible server with versioning enabled  
- an OpenBao server with Kubernetes auth and KV v2  
The Fake provider stays the model for every automated test.  
**Done means all of these pass, with command output shown**  
Stage 1:  
1. The xref boundary checks listed under Architecture fail CI on violation.  
2. The Python stdlib client runs in CI against a daemon with the Fake provider. It initializes, lists the fleet, subscribes to a session from seq 0, sends input, and answers an approval.  
3. mix troupe.schema.diff passes on an added optional field and fails on a removed field, a renamed field, a changed type, and a new required field.  
4. Property test: random disconnects and reconnects with from_seq always yield a durable sequence identical to the log.  
5. A client that subscribes at detail and never reads leaves agent turn latency within 10% of baseline and daemon memory within a fixed bound, and it receives resync_required.  
6. kill -9 the daemon with three sessions, one mid-turn. After restart, all three are listed, the mid-turn one is interrupted, and the Fake call count does not increase until new input arrives. A session idle past the timeout stops its actor tree, and subscribing to it serves history without starting one.  
7. Ten concurrently started clients spawn exactly one daemon.  
8. A second session.create in a live workspace creates a worktree on troupe/<slug>. worktree.remove refuses a dirty tree without force.  
9. With approvals pending in three sessions, HQ lists all three. Responding from HQ resolves each, and a later response from a second client gets approval.resolved with no second effect.  
10. Sending the same command_id twice produces exactly one effect.  
Stage 2:  
1. helm install on kind plus WorkerProfiles for dev and ux reach Ready within 3 minutes, and the test asserts every reconciled resource listed above exists.  
2. A profile with a disallowed image, or an egress pattern outside policy, is rejected at admission, or marked PolicyViolation where admission policy is unavailable, and no pods are created.  
3. Killing the operator mid-reconcile converges with no duplicate resources. Manually deleting a managed Service gets it recreated within 30s.  
4. A pod enrolls as its own profile. A ServiceAccount token from another namespace cannot enroll as dev. A killed pod is marked unhealthy within 15s.  
5. Killing one of two plane replicas brings worker control connections back within 10s, attached sessions are unaffected, and creates keep succeeding.  
6. A SCIM push creates users and groups, and enabling a group makes it a team. With SCIM disabled, the JIT groups claim yields the same teams.  
7. After troupe login, a user sees exactly their granted profiles and exactly the sessions they own, are on the ACL of, or can see through team visibility. A user in no granted team sees nothing and cannot create.  
8. 50 concurrent creates, split across both plane replicas, against a profile with total capacity 20: exactly 20 succeed, 30 get a capacity error, and no pod exceeds its cap.  
9. Concurrent creates across replicas never exceed a team's budget.  
10. Scaling a profile from 2 to 1 replicas with a live session on ordinal 1 stops placements there, lets the turn finish, and makes the session dormant before the pod is removed. Deleting the PVC afterwards loses nothing: the next input activates the session on ordinal 0 with its full history and workspace.  
11. Publishing bundle v2 makes every pod report the v2 hash within 10s. New sessions record v2 and a running session stays on v1.  
12. A token minted for a ux pod is rejected by a dev pod on audience.  
13. A connection refreshes after auth.expiring and continues. Without a refresh, the next command after exp is rejected and the connection closes.  
14. A viewer's input.send and approval.respond are forbidden while events keep flowing. A revoked collaborator's next command is rejected.  
15. With the team volume granted read-only, write_file to it is rejected and shell writing to it fails with a read-only filesystem error. Another team's volume and another session's workspace do not exist inside the sandbox.  
16. publish produces a durable event with source, destination, and hash, and asks by default.  
17. A file created by shell reaches every subscriber as fs.changed within 1s, and fs.read returns the same hash.  
18. troupe ctl verify passes on a clean log, and the plane holds every sealed segment head. Flipping one byte in any stored event makes verify fail at that seq.  
19. A pod presumed lost that reconnects after its session was activated elsewhere has its seal reports rejected, terminates that session, and discards the cache. The rebuilt index contains no events from the stale epoch.  
20. The mock LiteLLM records owner, team, and session id on every request.  
21. With the plane stopped, an attached harness completes its session and sealing continues. session.create and activation of a dormant session fail with a clear plane-unavailable error, and seal reports replay once the plane is back.  
22. The mock MCP server only ever receives the service credential.  
23. A unique marker string sent as session input never appears in a plane database dump or in captured control-channel traffic.  
24. Deleting a pod's PVC mid-session loses at most the events since the last seal, never more than 60 seconds' worth. The session then activates elsewhere from object storage.  
25. 10,000 dormant sessions assigned to one pod keep its memory within the idle baseline plus a fixed bound.  
26. Subscribing to a dormant session serves its full history with zero Agent.Server processes started and zero LLM calls.  
27. An approval requested before dormancy and answered three simulated days later activates the session, and the turn continues from the resolved call.  
28. Two concurrent activations of the same dormant session produce exactly one actor tree and one epoch increment.  
29. Activating after the pinned bundle version is retired appends config.upgraded. Removing the team's grant makes the session read_only: reads still work and activation is refused.  
30. Fixture logs from every prior release replay to their recorded fold hash. A corrupted or version-mismatched snapshot falls back to full replay with the same result.  
31. Filling a pod's PVC past the high watermark stops placements there, and evicting dormant caches brings it below the low watermark without touching active workspaces.  
32. After session.erase, the key is gone from OpenBao, and no object under the session's prefix decrypts, including prior versions in the versioned bucket. The plane database and PVCs hold nothing but the tombstone. A pod that was offline during erasure applies it on enroll, before serving anything.  
33. troupe admin index rebuild against an empty sessions table reproduces the index from object storage, matching the original on every state, epoch, and head hash.  
34. A PITR restore of the plane database, followed by an index rebuild and ledger reconcile, loses no session. The ledger accepts each gateway request id once, and the nightly reconcile against the mock gateway reports injected drift.  
35. The plane's OpenBao credentials cannot read any session key, and a ux pod's credentials cannot read keys of a team granted only to dev.  
Stage 3:  
1. The panel lists profiles, pods, conditions, and load, and killing a pod is reflected within 2s. Tested with Phoenix.LiveViewTest against the kind cluster.  
2. Direct mode: a profile created in the panel becomes a Ready CR. kubectl auth can-i as the plane's ServiceAccount returns no for creating pods, secrets, and namespaces.  
3. GitOps mode: a profile created in the panel appears as a commit in the fixture repo. The panel shows Pending until the test applies it and observedGeneration matches, then shows Ready.  
4. Granting a team to a profile makes it visible in a member's troupe --remote on the next token mint without re-login. The profile shows UpgradePending until its pods restart idle with the team volume mounted.  
5. A missing secret reference shows SecretMissing. A known secret value never appears in API responses, panel HTML, or a plane database dump.  
6. A team_admin sees only their own team's sessions and spend, and a platform_admin sees everything. Neither can fetch session content.  
7. A test enumerates Plane.Admin and asserts that every function has an admin API method and a troupe admin command. xref asserts that LiveViews call only Plane.Admin.  
8. Every admin change creates an audit record with actor and diff, listed by troupe admin audit.  
Stage 4:  
1. Two harnesses each send 100 inputs concurrently to one session. Both observe the identical event order, every input carries the right author, and every optimistic render reconciles.  
2. Presence reaches other clients and never appears in the durable log.  
3. Harness A registers a client-hosted tool after consent, and the agent's call is served by A and logged. B's summary shows session.tainted. Registration without consent is rejected.  
4. When A disconnects during tool.invoke, the agent gets an error result within the timeout and keeps running, tools.unregistered is logged, and B cannot invoke A's tool.  
5. With five clients attached over WebSocket on kind, p95 from input.send to input.accepted is under 100ms.  
**Out of scope**  
**The GUI (** **troupe --remote --gui** **).** Do not build it, but keep it cheap. Its intended shape: the harness serves a local LiveView bound to 127.0.0.1 with a one-time URL token and opens the system browser, and each view is a protocol client process. So the client SDK must work from any process that receives messages, and nothing in the protocol may assume a terminal.  
**Remote triggers.** Do not build them, but the lifecycle above is their foundation, so keep them possible. Creating and activating a session must work for a service principal with no attached client, calling the plane under the same grants, budgets, and retention, with results waiting in the log for whoever attaches later. Triggers never get an endpoint on workers.  
Also out of scope: autoscaling, multi-cluster, break-glass content access, mirroring teams into LiteLLM, the A2A facade, live migration of active sessions between pods, pod-per-session sandboxing, local encryption beyond the user's disk encryption, and a tiling window manager. Keep them possible: the event model must map onto A2A tasks, and nothing may assume a session never moves.  
**Final report**  
Each done item with the command that proves it, every deviation with its DECISIONS.md entry, the Bonny spike outcome, measured seal lag and activation latency (warm cache and cold), and known limitations per stage.  
