# Decisions

Every deviation from `spec.md`, and every ambiguity resolved, with the reasoning.
Newest at the bottom. `../troupe/DECISIONS.md` covers stage 0 and still applies.

## Stage 1 — structure

1. **The umbrella root has no `lib/`.** An umbrella project does not compile its own
   `lib/`, so `Mix.Tasks.Compile.Reaper` and `Troupe.Release` — both of which the root
   `mix.exs` references — moved into `apps/troupe_core/lib/`. Mix tasks are found in
   any app's `ebin`, so `mix troupe.boundaries` and `mix compile.reaper` still run from
   the umbrella root.

2. **Dev and build Mix tasks live in `troupe_core`.** There is no natural home for them
   — a ninth app for two tasks is worse than the small untidiness — and a Mix task is
   not part of the runtime dependency graph, so nothing is coupled by it.

3. **`mix troupe.boundaries` reads beam import chunks, not an `:xref` server.** The
   spec says "enforced by xref". A cross-reference of the compiled beams is exactly
   what `:xref` computes; reading the `imports` chunk directly gets the same
   information without starting and populating a server, and it is trivially
   deterministic. The task additionally checks that every cross-app call is declared in
   the caller's `mix.exs`, because the declared graph and the real one drift.

4. **`Troupe.Gateway.Endpoint` became `Troupe.Protocol.Endpoint`.** Discovery — where
   the daemon listens, and how to read the file it published — is something a *client*
   must know, and clients may only depend on `troupe_protocol`. It has no server-side
   behaviour in it.

5. **`Troupe.UI.Supervisor` moved from `troupe_core` to `troupe_ctl`.** A view is a
   protocol client now. Leaving its supervisor in the core's tree would have meant
   `troupe_core` naming modules it must not know about, and would have put a client's
   failures inside the tree that owns sessions.

6. **`troupe daemon` is dispatched through a configured module, not a direct call.**
   `troupe_ctl` may not depend on `troupe_gateway`, but the same binary is both the
   client and the daemon, so the CLI has to be able to start one. It reads the module
   from `config :troupe_ctl, :daemon` and calls it by name at runtime. This is the same
   seam already used for `:frontend`, and it is deliberately not private access: the
   CLI can *boot* a daemon, and then has to talk to it over the socket like anyone
   else.

## Stage 1 — events and the log

7. **`Session.Log` is the sole publisher of durable events.** Carried over from stage 0
   and now load-bearing: a subscriber that saw a fact from the agent *and* from the log
   would see two shapes of it, and the difference would only surface under replay.
   Agents publish ephemerals and nothing else.

8. **Approvals are durable.** The spec lists pending approvals as state that survives
   dormancy, which is only possible if they are in the log. `approval_requested` and
   `approval_decided` are therefore persisted, not transient as in stage 0.

9. **`Troupe.LLM.Delta` is serialised explicitly rather than encoded as a struct.**
   Ephemeral `data` has to be JSON, and absent fields are dropped rather than sent as
   `null`: a delta is the highest-volume thing on the wire, and a client that has to
   tell "missing" from "null" for no reason will get it wrong.

10. **`Sessions.Index` monitors each session's supervisor.** "Live" has to mean a tree
    that is actually running, not one the index was once told about. Without the
    monitor a crashed session stays listed as active forever, and a listing after a
    crash is exactly when the truth matters. Anything not live is read from its log.

11. **A session's first durable event is `session_created`.** It carries workspace,
    profile and visibility, so a listing — including one for a dormant session on a
    machine that has never run it — can be rebuilt from the log alone.

## Stage 1 — daemon

12. **The acceptor transfers socket ownership to the listener before announcing it.**
    `:gen_tcp.controlling_process/2` may only be called by the owner, and the accepting
    process is the owner. Without the hand-off the listener cannot pass the socket on
    to the connection, and the connection cannot legally read from it.

13. **The idempotency ledger claims a `command_id` before running the command.** If it
    recorded results afterwards, two concurrent deliveries of the same retry would both
    pass the check and both take effect. A claim that is still in flight answers
    `{"accepted": true, "duplicate": true}` — the caller wanted to know it was
    accepted, and it was.

14. **`Endpoint.unix_sockets_available?/0` decides by trying.** `AF_UNIX` support is a
    property of the OTP build, not of the operating system's name.

## Stage 1 — clients

15. **`Troupe.UI.Supervisor` was removed rather than moved again.** A view is a
    protocol client with one connection and one owner. Headless rendering runs *in the
    command's own process* — the command has nothing else to do while a turn is in
    flight — and the TUI is one process the command links to and waits on. Neither
    needed a DynamicSupervisor, and the one that existed had become a shared name two
    apps that may not depend on each other both reached for.

16. **`troupe daemon` is supervised by `Troupe.Ctl.Application`, not run by
    `Troupe.CLI`.** A daemon is a tree that stays up; every other command is a task
    that finishes and halts the VM. Blocking inside an application's `start/2` for the
    life of a daemon would leave the release half-booted for as long as it ran, so the
    application decides from the parsed command what to supervise.

17. **`troupe_ctl` and `troupe_tui` depend on `troupe_gateway` in the test
    environment only.** To test a client you need a server. It is never a runtime
    dependency, and `mix troupe.boundaries` reads the compiled beams rather than
    `mix.exs`, so a call from `lib/` would still be caught.

18. **Closing the TUI leaves the session running.** `/quit` and `Ctrl-C` detach; the
    session stays in the daemon and `troupe resume` reattaches. That is the whole point
    of moving sessions out of the TUI process, and the old behaviour — quitting the
    view ends the work — would have quietly undone it.

19. **`Client.connect/1` does not link.** A refused or reset connection is an ordinary
    outcome a caller handles as `{:error, :closed}`; linking would turn it into the
    caller's own exit. The client monitors its owner instead, so it still goes away
    when the owner does.

20. **The event envelope carries `session_id` as well as `topic`.** An event does not
    carry its own session id — in the log, the file it is in says which session it
    belongs to — and a `fleet` subscriber receives events from every session on one
    subscription. Without the envelope it cannot tell them apart.

## Stage 1 — backpressure

21. **Writes happen in a separate process, `Gateway.Writer`.** `:gen_tcp.send/2`
    blocks once the buffers fill, which is immediately for a client that has stopped
    reading. With the connection doing its own writing it would block there, its
    mailbox would grow without limit while it did, and the backpressure logic — which
    lives in that very process — would not run at all.

22. **No `send_timeout` on the accepted socket.** A timed-out send leaves an
    unspecified amount of a message on the wire, and the next write would append to a
    half-written line. Blocking one writer process costs nothing; a corrupted stream
    costs the client its session view. A peer that is truly gone arrives as
    `tcp_closed` instead.

23. **Two budgets, not one.** Ephemerals are refused past a byte bound on the outbound
    queue — that is the memory guarantee. Durable events are never dropped to save
    memory; they are queued regardless and counted, and past a separate backlog bound
    the subscription ends with `resync_required`. One combined bound would either drop
    durable events or let a delta flood hold a subscription hostage.

24. **`resync_required` and command responses survive a queue discard.**
    `resync_required` is queued behind the very backlog it is about to discard, so
    without an urgent class it would be the first casualty of its own arrival.

## Stage 1 — restarts and dormancy

25. **A session that was mid-turn comes back interrupted, and `resume_on_restart`
    opts back in.** Resuming by default means a crash loop spends money and re-runs
    shell commands nobody is watching. Interrupted tool calls are closed off as errors
    naming the interruption, because the model needs a result for every call it made
    and a log with a dangling `tool_call_started` would look incomplete forever.

26. **"Did the session come back, or did one agent crash?" is asked of
    `Session.Log`.** Its lifetime *is* the session tree's — it is the first child, and
    anything that takes it down takes the agents with it. A crashed agent inside a live
    session still finishes what it started, which is the at-least-once behaviour tools
    are written for and what the user watching it expects.

27. **The daemon does not restart actor trees at boot.** Sessions come back dormant and
    are served from their logs; the first activating command restores the tree. This is
    the same machinery as the idle timeout, and starting every session a user has ever
    had on every daemon start is not a restoration, it is a stampede.

28. **Dormancy is swept by `Sessions.Index`, which asks the agent.** "Nothing has been
    logged lately" is also true of an agent waiting on a twenty-minute test run, so
    idleness is asked of the agent rather than inferred from the log.

29. **Reads never activate.** `session.list`, `session.get`, `blob.get` and `subscribe`
    all work on a dormant session and start nothing. A session that woke up because
    somebody looked at it would never stay dormant.

## Stage 1 — schema

30. **`protocol/schema/v1/` is generated from `Troupe.Protocol.Schema` and
    committed.** A client author needs a machine-readable protocol without a checkout
    and without running Elixir, and a reviewer needs to see a field appear or disappear
    in a diff rather than in a release note. `mix troupe.schema.diff` fails on a
    removal, a rename, a retype, or a newly required field; a test validates a real
    session's log against the schema, so the table cannot drift from the code.

31. **`llm_request.messages` became `message_count`.** It was always the count — the
    whole conversation is in the log once already, and writing it again every turn
    makes the log grow with the square of the turns — and the name said otherwise. The
    protocol has not shipped, so the honest name is free now and expensive later.

32. **A second answer to a decided approval is an event, not an error.** Two people
    watching one session is the normal case, not a fault. The late responder gets
    `approval_resolved` naming who got there first, and nothing else happens.

## Stage 1 — blobs

33. **A large tool result is stored once and referenced twice.** Over 16 KiB it goes to
    content-addressed storage in the session directory, and both the
    `tool_call_completed` a client renders and the `tool_results` the model is sent
    carry `{"blob", "size", "preview", "truncated"}` instead of the bytes. Replay
    resolves the reference back to text, because the conversation a restarted agent
    rebuilds has to be the one the model actually saw — a pointer it cannot follow is
    not the same conversation.

34. **Blobs are deduplicated within a session and never across sessions.** Sharing them
    would put one session's content under another session's key, which is exactly the
    property that makes per-session erasure mean anything — and in the remote stages,
    the property that keeps one team's storage from being a probe for another's.

## Stage 1 — packaging

35. **Arguments are read from `:init.get_plain_arguments/0`, not from Burrito.** The
    Zig wrapper hands them to the VM as plain arguments, so `System.argv/0` is empty
    inside a packaged binary — but reading them through `Burrito.Util.Args` would make
    `burrito` a runtime dependency of `troupe_ctl` that the release then has to carry.
    It is two lines.

36. **`troupe daemon` blocks in `Troupe.CLI`, and `troupe_ctl` is listed last in the
    release.** Two things forced this. Elixir's CLI treats the first plain argument as
    a script to run, so a boot that *completes* with `daemon` still on the command line
    prints "No file named daemon" and halts — the command has to never return.
    And a command that never returns must not run before the applications it depends on
    have started, which is what the ordering in `releases/0` guarantees.

## Stage 2 — the operator

37. **Bonny 1.5 was spiked on Elixir 1.20 / OTP 28 first, as the spec asks, and it
    works.** It and `k8s` 2.8 compile and run there. It supplies the parts that are the
    same in every operator and easy to get subtly wrong — a watch that resumes from the
    right resource version, a periodic resync, leader election through a Kubernetes
    `Lease` — so the fallback of hand-written watch-and-reconcile GenServers was not
    needed.

38. **The reconciler is self-contained rather than a Bonny pipeline step.** Bonny's
    `register_descendant` + `ApplyDescendants` would have done the applying, but a pass
    can also be started by the resync or by one of the operator's own objects being
    deleted from under it, and all three want the same thing to happen. A reconciler
    that applies for itself can be called from any of them; one that only works inside a
    pipeline cannot. Bonny is left doing what it is good at: delivering events.

39. **Nothing in a worker namespace carries an owner reference.** They may not cross
    namespaces, and the `WorkerProfile` lives in `troupe-system` while its objects live
    in `troupe-w-<profile>`. Kubernetes treats such an owner as missing and garbage
    -collects the dependent — which it did, taking a whole StatefulSet seconds after the
    operator created it. Instead the operator **prunes**: it lists what carries its own
    marker and deletes whatever is no longer wanted. Deleting a profile deletes its
    namespace, and Kubernetes takes the rest.

40. **Pruning selects on a marker the operator writes, not on the profile label.** A
    StatefulSet copies its selector onto the PVCs it creates from its volume claim
    templates, so a pod's data volume — holding the working copies of live sessions —
    carries the profile's labels too. Selecting on those alone offered one for pruning.

41. **CRDs live in `charts/troupe/crds/`, not in `templates/`.** A custom resource
    cannot be rendered in the same release as its own kind, and the chart ships a
    default `TroupePolicy`. Helm installs `crds/` first, which resolves that, and never
    upgrades or deletes it — which is also a safety property, since removing a CRD
    removes every object of that kind. Changing one is a deliberate
    `kubectl apply -f charts/troupe/crds/`.

42. **The admission policy reads `TroupePolicy` through `paramKind`.** The limits are
    written once, in the policy resource, and the CEL reads them. Two copies of the same
    numbers would drift the first time an admin edited one.

43. **The operator watches its own objects, not only the resources it owns.** The
    periodic resync would eventually notice a deleted Ingress — that is what a resync is
    for — but "eventually" is a minute of a profile being unreachable. A watch on the
    objects turns that into a reconcile that starts as the deletion lands.

## Stage 2 — the plane

44. **Two things in the plane are decided by one process, not by a lock.** Capacity per
    profile and budget per team are both read-decide-write, and two replicas doing
    either at once is exactly how you overbook. Each is an actor registered with
    `:global`, so the question is serialised by a mailbox; callers on other replicas
    reach it by name. When the node holding one dies, `:global` forgets the name and the
    next caller starts it on a survivor.

45. **Every reservation is written before it is granted.** That is what makes respawning
    on a survivor safe: the new actor reloads from PostgreSQL and reads back exactly what
    was handed out. A reservation that lived only in a process would be lost with the
    replica that made it, and the next actor would hand the same slot out again.

46. **The placement actor re-reads the pod list on every call but not the session
    counts.** It is the only thing that grants a slot, so its own numbers are the
    authority between reloads; counting sessions again per reserve would put a group-by
    in front of every create. A pod it has never seen is the exception — that pod's
    sessions were placed by an earlier incarnation, so its count has to come from the
    database.

47. **SCIM and the JIT groups claim end in the same three functions.** A done item
    requires both to yield the same teams, and two parallel implementations would drift
    the first time one grew a rule. Membership is *replaced* on every push and every
    login, never merged, because both carry the whole list and a group's absence is a
    departure.

48. **A login creates groups it has never seen.** A group is not access — a team is, and
    only an admin makes one — so learning that one exists costs nothing, and it is what
    lets an admin enable a team without first asking the identity provider for a list.

49. **A budget of zero means no limit, not no money.** A team that has not been given a
    budget should be able to work; a team that has one of zero would be a team nobody
    could use, which is what disabling it is for.

50. **Reservations are not spending.** What a session promised and what its model calls
    cost are separate tables. The ledger is unique on the gateway's request id, so a
    worker replaying its reports after an outage is not a second charge — and that
    uniqueness is what makes the nightly reconciliation against the gateway meaningful.

51. **The two-replica tests use a real second node.** `:peer`, Erlang distribution, and
    its own connection pool against the same database. Faking the second replica would
    not exercise `:global` at all, and `:global` is the entire mechanism.

52. **A pod's profile comes from its namespace, never from what it says.** Enrolment is
    a `TokenReview` on the projected ServiceAccount token, and the namespace in the
    answer decides the profile. A ux pod cannot enrol as dev because it cannot mint a
    token from dev's ServiceAccount, and the audience — `troupe-plane` — is checked
    explicitly, because a token valid for the API server comes back authenticated with
    its own audiences listed rather than rejected.

53. **A control connection that fails to enrol is closed.** It has no identity and
    nothing it may say; leaving it open is an invitation to keep trying.

54. **A field a worker did not report is a field that has not changed.** Casting the
    nil would set the column to NULL, which for the byte counters is a constraint
    violation and for the rest is losing what was there.

55. **Presence is a lease, not a farewell.** A pod that fails cleanly closes its
    connection and the plane knows at once; the failure that matters is the pod that
    cannot tell anyone anything. So a heartbeat renews a fifteen-second lease and a
    sweep marks what has gone quiet — on every replica, because marking a pod unhealthy
    twice is the same as marking it once.

## Stage 2 — the object tier

56. **`Troupe.KMS` lives in `troupe_protocol`.** The spec fixes the umbrella's eight
    apps, the plane may not depend on `troupe_core`, and both the plane and the workers
    hold this contract — the plane destroys keys and the workers create and read them.
    `troupe_protocol` is the only place both can see, and it already holds the other
    contract the two sides share, endpoint discovery.

57. **Session keys are KV v2, not v1, because of one call.**
    `DELETE /metadata/<path>` removes every version. A v1 delete removes the current
    value and leaves the key readable at its previous version, which is not erasure.

58. **Creating a session key is idempotent.** A session whose key exists is a retry, not
    a second session; replacing the key would strand every segment already written under
    the old one — the session would still exist and none of it would decrypt.

59. **The session id is authenticated but not encrypted.** AES-256-GCM with the session
    id as associated data, so an object moved between two sessions' prefixes fails to
    decrypt rather than decoding into the wrong session's history.

60. **Object keys are zero-padded.** Object stores sort by byte, and unpadded `10`
    sorts before `9` — which is how a replay ends up reading the tail of a session
    first.

61. **The epoch is part of a segment's key.** A pod presumed lost comes back holding the
    old epoch, so its segments land under keys nobody reads. Reconstructing a history
    follows the highest epoch's *contiguous* chain, so an older epoch's segment covering
    ground already covered is skipped rather than merged — and a gap ends the chain
    rather than being stepped over, because a history with a hole in it and no way to
    know is worse than a short one.

62. **The manifest is plaintext and everything else is not.** A rebuild has to enumerate
    sessions from storage alone, without a key it is not allowed to have. So the manifest
    carries ids, sizes and where the key lives — and nothing that was said.

63. **S3 signing is `aws_signature` over Req, not an S3 client.** Four verbs, and an S3
    library with its own opinions about retries, streaming and error shapes would be a
    second HTTP stack to reason about. Two things had to be got right by hand: `host`
    must be among the signed headers, and S3 is the service that does *not* double-encode
    the path.

64. **A dormant session costs no process on the worker.** A pod is expected to be
    responsible for tens of thousands of sessions and to have almost all of them asleep,
    so dormancy stops the manager rather than parking it. Everything a dormant session
    *is* lives in object storage, and activation is the only path back — which is also
    what makes relocation and PVC loss the same operation, since neither has anything
    local to start from.

65. **Turn completion is an ephemeral event, so the sealer reads ephemerals for their
    timing and seals none of them.** An ordinary reply leaves the root agent idle and
    logs nothing to say so; `agent_done` is only written when an agent actually finishes.
    Sealing on the ephemeral transition is what makes "at every turn completion" true,
    and dropping the ephemerals themselves is what keeps the object tier the size of the
    session rather than the size of its typing.

66. **Seal, then report — never the other way round.** A segment the plane has been told
    about but that is not in storage would let a rebuild claim history it cannot produce.
    A segment in storage the plane has not heard of is merely un-anchored, and the next
    report fixes it. The same reasoning makes sealing carry on when the plane is
    unreachable: durability must not depend on the plane being up.

67. **Dormancy erases the event log as well as the workspace.** The Forbidden list names
    the plaintext workspace, but `events.jsonl` is plaintext session content on the same
    PVC and the durable copy of it is already encrypted in object storage. Both go, and
    the erase is checked rather than assumed: a file the pod cannot delete would leave
    plaintext behind while the code reported success.

68. **The restore runs inside the `await` call that asked for it, not in `init` or a
    continue.** A manager that failed before anyone called it could only report
    `:noproc`, and "why" is the difference between a storage blip worth retrying and a
    stale epoch that must never be retried. Concurrent activations queue behind that one
    call, which is where "one tree, one epoch" comes from inside a pod.

69. **A manager gives up its registered name in `terminate/2`.** The registry would do it
    on its own when it gets round to the monitor message, but a caller that has just put
    a session to sleep and is about to place it elsewhere would see the corpse in the
    meantime. `dormant/1` and `fence/2` wait for the process to be gone before returning,
    so the registry is authoritative the moment they do.

70. **A fenced pod uploads nothing and keeps nothing.** Its events belong to an epoch the
    session has moved past and its workspace is a copy of a tree somebody else now owns,
    so the sealer is killed rather than flushed and the local cache is erased. The
    cheaper check comes first: the manifest is plaintext, so a stale epoch is caught
    before anything is decrypted.

71. **Sealing before stopping, stopping before archiving, erasing last.** Sealing first
    keeps the last turn; stopping the tree before archiving keeps the archive from being
    torn halfway through a file write; erasing last means every byte is already in object
    storage under a key the plane cannot read by the time the plaintext goes.

72. **The worker dials the plane, so reconnection is entirely the worker's business.** A
    pod's address is a property of the cluster and a plane replica's is not, so a worker
    needs one Service name and the plane learns where the worker is when it arrives.
    That also makes losing a replica a sub-second event: the Service sends the next dial
    to a survivor, with a 250 ms floor and a 2 s ceiling on the backoff and jitter on
    top so a plane coming back does not take every worker's reconnect in the same
    millisecond.

73. **Enrolment is a blocking round trip on a socket that is not yet active.** Nothing
    else may be sent until the plane has said which profile this pod is, and a queued
    report sent before that would be refused and lost. The projected token is re-read on
    every connect, because one cached at boot expires while the pod is still running.

74. **A link that cannot reach the plane is not an error the rest of the worker hears
    about.** Sealing carries on and the reports queue, bounded at ten thousand and
    oldest-first — a worker out of touch for an hour has a session index that says
    everything the dropped reports would have, and the plane asks for one on reconnect.

75. **Pushed commands are handled off the link.** Activating a session can take seconds,
    and the link has heartbeats to send and other pushes to receive in the meantime.
    Every pushed method is idempotent, because the plane retries on a reconnect without
    knowing whether the first attempt landed.

76. **The "no session content" rule is tested by looking at the bytes.** A recording TCP
    relay sits between the worker and the plane and keeps everything that crosses, and
    the test sends a marker string as session input and greps the capture. Asserting on
    the worker's own idea of what it sent would prove nothing: the question is precisely
    whether the code is wrong about that.

77. **`troupe_worker` test-depends on `troupe_plane`, and only in that direction.** An
    end-to-end test of the control channel needs a real plane on the other end of the
    socket, and the worker is the client in that relationship. No `lib` code crosses,
    which is what `mix troupe.boundaries` checks — it reads compiled `imports` chunks,
    not `mix.exs`.

78. **Disk usage comes from `df`, not from summing the files this code knows about.** A
    PVC shared with anything else, or holding a deleted-but-open file, would make the sum
    a lie. Above the high watermark a worker puts its quietest sessions to sleep, which
    reclaims only bytes that are already in object storage; above the critical one it
    stops accepting placements, because a pod that runs out of disk mid-turn loses the
    turn.

79. **The plane signs session tokens through OpenBao transit and never holds a key.** A
    compromised plane can mint tokens while it is compromised and forge nothing
    afterwards, and the same credential that allows signing allows nothing under the
    session-key paths. ES256 over P-256, because the public half is a JWK a worker can
    cache and check offline, and because transit will marshal an ECDSA signature in JWS
    form directly — its default is ASN.1 DER, which no JWT verifier accepts.

80. **`kid` is the key's RFC 7638 thumbprint, not a name we assign.** The plane that
    minted a token and the worker that fetched the JWKS agree on it with nothing kept in
    step between them, and a JWKS carries every version of the transit key so a token
    minted moments before a rotation stays good until it expires.

81. **`aud` is the pod's worker id, not the profile.** A profile has many pods, and an
    audience naming the profile would make them interchangeable — which is exactly what
    a leaked token wants. The worker id is the narrowest thing the plane knows at mint
    time.

82. **Authentication is injected into the gateway, not branched inside it.** A Unix
    socket authenticates by its permissions, a loopback TCP endpoint by a token in a
    user-only file, and a pod by a signed token whose audience names it — so the endpoint
    carries an authenticator function and the gateway stays a gateway. There is one
    protocol implementation for local and remote sessions rather than two that drift.

83. **The role in a token is checked once; the ACL is checked on every command.** A token
    is a claim about the moment it was minted, and a collaborator whose access was
    revoked still holds one that verifies perfectly. The endpoint therefore carries a
    guard as well as an authenticator, consulted before every command against the ACL
    mirror the plane pushes — which is what makes a revocation take effect on a
    connection that is already open.

84. **A refresh happens on the connection that is already open.** Reconnecting to renew
    would interrupt a session mid-turn for no reason. Nothing is accepted past `exp`: the
    next command is refused and the connection closes, and a connection that sends
    nothing is closed shortly after `exp` anyway rather than streaming events on a token
    that has run out.

85. **The session row is written before capacity is reserved.** Reserving *places* the
    session, and a placement is a conditional write against the row rather than a note
    in a process — which is what makes it survive the replica that made it. A create that
    fails after the row exists deletes it: a session that never started is not a session,
    and leaving it would put a phantom in everybody's listing. A session that ever ran is
    erased rather than deleted, because a tombstone is the record that it existed.

86. **Only the winner of the epoch bump places the session.** Six clients activating the
    same dormant session all read "dormant"; the conditional update decides between them.
    If every caller then reserved capacity, one session would spend six slots. The losers
    wait for the winner's placement and are handed the same tree.

87. **A session nobody may see is `not_found`, not `forbidden`.** Whether a session
    exists is itself something a person who cannot see it should not learn.

88. **A user in two teams that both grant the profile is asked which.** The answer decides
    whose budget pays and whose volume is mounted, and guessing would be a billing
    decision made by a default.

89. **Erasure destroys the key first and deletes the objects second.** Once the key is
    gone nothing under the prefix decrypts, so the deletion is tidiness rather than the
    security property. The other order leaves a window where the ciphertext is gone and
    the key is not — which protects nobody — and a failure halfway would leave readable
    data behind.

90. **The plane drives erasure but does not perform it.** It holds no credential that can
    read a session key and none for object storage. A pod of the profile has both, so the
    plane asks one and records which pods have complied; a pod that was offline applies
    the erasure on enrol, before serving anything. That is the Forbidden list working as
    intended: the component that decides *whether* to erase is not the component that can
    read what it is erasing.

91. **A tombstone keeps the final head hash.** It is the last link of the audit chain, and
    an erasure that also erased the proof that the session existed would be
    indistinguishable from a session tampered out of the index.

92. **The object store and the session layout live in `troupe_protocol`, not in
    `troupe_worker`.** They are a contract both sides hold, for the same reason the KMS
    behaviour is: `troupe admin index rebuild` reconstructs the plane's index from
    storage, and the plane cannot depend on the worker. What the plane can read there is
    bounded not by where the code lives but by what it has a key for — and it has none.

93. **A segment's epoch, last sequence number and head hash are plaintext object
    metadata.** That is the whole of how a rebuild works without a key: the key names the
    epoch and the range, and `x-amz-meta-head-hash` names the head. None of the three is
    content.

94. **A rebuild trusts segments over the manifest.** The manifest is one key and a pod
    that was presumed lost can overwrite it under a stale epoch; the segments are what a
    worker would actually replay. Where they disagree the highest epoch's contiguous
    chain wins — the same rule a worker follows on restore, and the reason a stale pod's
    events never enter the index. A tombstone beats both, so an erased session cannot be
    resurrected by a stray object.

95. **A rebuild keeps the identity fields of a row it is overwriting.** Storage is
    authoritative about where a session *got to*, not about whose it is, and a manifest a
    ghost pod rewrote can be missing an owner the index still has.

96. **A session that cannot be indexed is reported, not skipped quietly.** A rebuild that
    silently dropped sessions would be worse than one that failed: the whole point of it
    is being able to say the index is complete.

97. **Reading a dormant session opens a reader, not a session.** A reader restores the
    event log to the pod's disk and nothing else: no `Agent.Server`, no model call, no
    workspace. It exits when its last subscriber leaves, which is what keeps a pod that
    serves a thousand glances a day from accumulating a thousand processes. A session
    that woke up because somebody looked at it would never stay dormant.

98. **Readers share the session registry under `{:reader, id}`, and are deliberately not
    counted as awake.** The heartbeat's `active_sessions` is what the plane places
    against, and a glance must not consume capacity.

99. **Dormancy keeps the encrypted archive and deletes the plaintext.** The cache is the
    same sealed bytes that went to object storage, under a key the pod must fetch from
    OpenBao to read, so keeping it turns reactivation on the same pod from a download
    into a local read without leaving a plaintext workspace anywhere. Uploaded first,
    cached second: a pod that ran out of disk while caching has still made the session
    safe, and one that cached but failed to upload would only look as if it had.

100. **Active workspaces are never evicted.** A cache is a copy of something already in
     object storage, so losing it costs a download; an active workspace is the only copy
     of work in progress. If eviction cannot get below the low watermark, the pod says so
     and stays above it rather than reaching for something it must not touch.

101. **The disk measurement is injectable.** `df` in a pod, because the number that
     matters is the filesystem's and not the sum of files this code knows about. A test
     cannot fill a developer's disk to prove what happens when a PVC fills, and the thing
     worth proving is the eviction policy; that `df` reports the truth is checked
     separately, against `df`.

102. **The mount table is what the tools check *and* what the sandbox is built from.**
     That is the point of having one: a read-only team volume is read-only to the kernel
     because the same entry that makes `write_file` refuse it is the `--ro-bind` the
     namespace is built with, so the two can never disagree. The Forbidden list says path
     checks may not be the only enforcement for `shell`, and they cannot be — a shell
     command can do anything a process can.

103. **Another team's volume does not resolve, rather than being rejected.** There is
     nothing to resolve it against: it is a path with no meaning in this session. The
     sandbox then makes that literally true, because the volume is absent from the mount
     namespace.

104. **A mount prefix is `session:`, `org:`, or `team:<name>` — and nothing else is one.**
     An unrecognised head is a session-relative path, which keeps every existing tool
     call meaning what it meant and stops a Windows drive letter being read as a mount.
     An absolute path stays absolute and is checked: reinterpreting `/etc/passwd` as a
     file inside the root would be an escape dressed as a convenience.

105. **`mounts_resolved` is recorded only when there is something to say.** A local
     session has `session:/` and nothing else, which is the default and not worth a line
     in every log. A session with a team or org volume records the table, so what it was
     allowed to see is part of its history after the pod that resolved it is gone.

106. **`publish` and `import` are tools of their own, and both ask by default.** Copying a
     file onto a volume the whole team can see is a different act from editing one in a
     scratch directory: it should look different in a log, and the person it becomes
     visible to cannot see what led to it. A copy that does not cross a mount boundary is
     refused, because `write_file` already does that and a durable record should mean one
     thing.

107. **Sandboxing is off by default outside a pod.** A laptop session has one mount, no
     team volumes, and a user who already owns every file the agent can reach, so a
     namespace would buy nothing and cost a dependency. Where it is *required* and
     bubblewrap is missing or mis-pathed, the command fails rather than running
     unconfined — the difference between a confined shell and an unconfined one is not
     something to fall back from quietly.

108. **`fs_changed` is separate from watch mode.** Watch mode turns AI comments into
     agent input and is a feature a user switches on. `fs_changed` is how a client
     attached to a remote session learns the working tree changed, including when the
     change was made by `shell` — which no tool call announces, because `shell` runs
     arbitrary commands and cannot say in advance what they will touch. Off locally,
     where the user can see their own files; on in a pod.

109. **A deletion is an `fs_changed` with a null hash, not a second event type.** A client
     rendering a tree folds one stream, and a separate `fs_removed` would mean every
     client had to handle two orders of arrival instead of one.

110. **Files over eight megabytes are identified by size and mtime, not hashed.** Hashing
     a gigabyte on every save would make the watcher the slowest thing in the pod. The
     value says what it is — `size-mtime:` — so nobody reads it as a content hash.

111. **`fs.*` resolves through the session's mount table, live or dormant.** A dormant
     session still has a table, recorded in its log, and a client reading one must be
     confined by exactly the rules the agent was. `fs.upload` needs `control`, because
     putting a file into a session's workspace is steering it, and the event names the
     person who did it rather than the session.

112. **A collaborator's input is billed to the owner's team budget.** The budget belongs
     to the session and a session has one owner, so `user` and `metadata.troupe_owner` on
     every gateway request name the owner rather than whoever is typing. Recorded here
     because it is a policy choice with a plausible alternative — billing the speaker —
     and the alternative would make a session's cost depend on who happened to answer.

113. **A call waiting for an approval is not an interrupted call.** A session can go
     dormant with a question outstanding and be answered three days later; closing the
     call off as an error on the way back would throw away the turn the person is about
     to say yes to. It is re-dispatched instead, which puts the request back in front of
     whoever is watching.

114. **The approval gate replays its decisions from the log.** Approvals are durable
     events precisely so they survive dormancy, and a gate that forgot them on the way
     back would be the half of that promise nobody kept — a re-dispatched call would ask
     the same person the same question again.

115. **The ten-thousand-dormant-sessions bound is measured as processes and process
     memory, not as total VM memory.** Those are the two things a regression would move:
     one process per dormant session would show in the count, and reading a cache into
     memory to index it would show in the bytes. Total VM memory in a test run measures
     the test suite as much as the pod.

116. **A running session's workspace is archived on its own interval, not only at
     dormancy.** The seal interval bounds what a lost volume costs in *history*; without
     this nothing bounded what it cost in *files*, and a pod deleted mid-session came back
     with a full log and an empty tree. Five minutes rather than sixty seconds, because an
     archive is the whole tree rather than the events since the last one, and skipped
     entirely when a cheap fingerprint — file count, total bytes, newest mtime — says
     nothing has changed.

117. **The key-store policies live in code, not in a chart's YAML.** The policy the tests
     prove and the policy a cluster installs have to be the same string, or the proof is
     about something nobody deployed. Three credentials and none can do what another can:
     a pod creates and reads under its granted teams only, the plane destroys metadata and
     reads nothing, the operator touches keys not at all.

118. **A pod cannot destroy a key, even one of its own team.** Making a session
     unreadable is an erasure, and an erasure is a decision the plane records and drives.
     A pod that could do it alone would be a pod that could destroy a session by being
     wrong.

119. **The plane's policy has no rule for the data path at all — not a deny.** OpenBao
     denies by default, and an explicit deny invites somebody to "fix" it later by
     narrowing it into an allow.

120. **A tool is a module or a value, and the harness takes either.** Which MCP tools
     exist is a property of a running server rather than of the code, so they cannot be
     modules — and generating modules at runtime would leave them in the code server
     forever. `Troupe.Tool` gained accessors that take both, so the allowlist, the
     permission map, the approval gate and the agent loop are one code path. That is what
     makes "their tools appear under the same allowlists, permissions, and approvals as
     built-ins" true by construction rather than by care.

121. **An MCP server sees the service credential and nothing else.** Not the session
     token, not the user's refresh token, not the subject as an authorisation. The
     session's identity travels as MCP `_meta` — an identifier the server can log — never
     as something it could present elsewhere, because a server holding a user token could
     act as that user against anything else trusting the same issuer.

122. **A secret reference is not a secret.** What a profile configures is the *name* of a
     secret the pod was given; the value is read from the pod's environment and never
     leaves it. `Troupe.MCP.Server` overrides `inspect/1` for the same reason: a crash
     report with a bearer token in it is a leaked credential.

123. **MCP tools ask by default.** A built-in tool's blast radius is known and written
     down in this repository; a tool on somebody else's server is whatever that server
     decided this morning. A profile can lower it to `auto` for servers an operator
     trusts.

124. **Discovery happens per pod, not per session.** A pod runs one profile and its MCP
     servers are a property of that profile; asking four servers for their tool list at
     the start of every session would put somebody else's latency on the path of every
     create. A server that cannot be reached costs its tools and nothing else.

125. **A bundle version is immutable and a session is pinned at creation.** A session
     whose agent definitions changed underneath it would be a different session halfway
     through. The only way a session's configuration ever moves is a deliberate upgrade at
     activation, when the version it was pinned to has been retired — and that lands in
     the log as `config_upgraded`, because the model is entitled to know its tools may
     have changed.

126. **Publishing announces rather than asks.** A publish that blocked on the slowest pod
     in the fleet would make publishing a risk. Pods are told, and the mismatch between
     the published hash and what a pod's heartbeat reports is what surfaces as a
     condition — so a pod that was restarting is visible rather than silently behind.

127. **Retiring a version is about what may be *started*, not what is running.**
     Interrupting a running session to change its configuration is the thing versions
     exist to prevent.

128. **Losing a grant makes the team's sessions read-only, not erased.** History is
     history, and a team losing a grant is not a reason to hide what it already did.
     Reads keep working; nothing activates again.

129. **The plane's HTTP surface is `Plug.Router`, not Phoenix.** Five routes and a SCIM
     path; Phoenix arrives with stage 3's admin panel, which is what actually needs it.

130. **Everything a client does goes through `/rpc`, and everything `/rpc` does goes
     through `Troupe.Plane.Harness`.** That is the "any client, including our own, uses
     nothing but public APIs" rule made structural rather than remembered: there is no
     second path into the plane for the TUI to take.

131. **The device grant runs against the identity provider, not through the plane.** The
     plane is asked only where its provider is and which client id to use; the user's
     credentials never pass through it, and what it receives afterwards is the token the
     provider issued.

132. **Two credentials, two homes.** The provider's refresh token goes to a `0600` file
     because it is what lets `troupe` work tomorrow; the plane's session token is short,
     audience-bound and never written down, because there is nothing to be gained by
     storing one. The credentials file is written to a fresh file and renamed into place,
     so a reader sees the old credentials or the new ones and never a half-written file.

133. **`troupe login` says what the login actually gives you.** A person who logs in and
     sees nothing has either no enabled team or no grant on it, and being told which is
     the difference between a five-minute question and an afternoon one.

134. **Tightening the credentials directory is best effort.** The directory Troupe made
     is Troupe's to tighten; one it was pointed at may be somebody else's, and refusing to
     store credentials because a parent has a different owner would be a failure for no
     gain — the file itself is `0600` either way.

135. **A drain waits for running turns rather than cancelling them.** A turn halfway
     through a tool call has an OS process attached and a model call already paid for,
     and killing it loses both. The wait is bounded by the drain timeout — the same
     number the pod's `terminationGracePeriodSeconds` comes from, because a drain that
     outlived its grace period would be killed in the middle of the thing it was trying
     to avoid — and a turn still running at the deadline is cancelled. That costs the
     turn in flight and nothing before it, because everything before it is sealed.

136. **The plane checks its own index before agreeing a pod is empty.** A pod reporting
     success while the index still shows sessions on it is exactly the case where
     believing the pod would lose them, so a drain that cannot confirm refuses to say the
     pod is safe to remove.

137. **A pod that cannot be reached has its sessions marked dormant, not left claiming to
     be on it.** They are in the state a lost pod leaves them in — durable as of their
     last sealed segment, activatable elsewhere — and saying so is what lets them be
     activated rather than waiting for a pod that is not coming back.

138. **Draining takes the highest ordinals first.** A StatefulSet removes them in that
     order, and draining a pod Kubernetes is not about to remove would be a session moved
     for no reason.

139. **The upcaster chain exists before there is anything to upcast.** Version 1 is the
     first released shape, so every clause is currently the identity — but retrofitting an
     upcaster to a log format already in the field is the part that goes wrong, and the
     fixtures are what keep the empty chain honest. Each step goes `n -> n + 1` and never
     `1 -> 3`, so adding a version means writing one function rather than revisiting every
     older one.

140. **An upcaster may add and rename, never drop.** A replay has to produce what the
     session actually did, and an upcaster that discarded a field would be rewriting
     history to suit today's code. The hash chain is not recomputed either: `prev_hash`
     covers the event as it was written, and upcasting changes the in-memory shape rather
     than the bytes — so a log from an old release still verifies against what sealed it,
     and `troupe verify` reads the raw file rather than coming through the chain.

141. **An event from a *newer* version is read, not rejected.** A client one release
     behind should degrade to ignoring fields it does not understand, which is what the
     fold does anyway. `from_the_future/1` names the versions seen, because a pod running
     an old image against a session a newer one wrote is a deployment mistake worth
     saying out loud.

142. **The fixture hash is taken over a *witness*, not over the agent's own state.**
     Rebuilding an agent needs things a log does not contain — the blob store its tool
     results spilled to, the definitions its profile names refer to — so replaying one
     outside a session would be testing the scaffolding. The witness projects every
     durable event type the agent's replay acts on into a shape that moves whenever their
     meaning moves, and a test reads the agent's replay clauses out of the source to
     assert the witness still covers them. A blind spot that nobody knows about is worse
     than a missing test.

143. **A recorded fixture hash is evidence, not a number to update.** If a hash moves,
     an old session would now come back as something different; if that is deliberate it
     needs a new schema version and an upcaster, with new fixtures beside the old ones
     rather than instead of them. `mix troupe.fixtures.record` refuses to overwrite a
     version already recorded for exactly that reason.

144. **A snapshot carries its format version *and* the build that computed it, and any
     mismatch discards it.** That is the design rather than a failure path to minimise: a
     snapshot that was wrong and was trusted would be a session silently looking like
     something it is not, and a full replay costs time and produces the right answer.
     Each rejection is named — `wrong_format`, `wrong_code_version`, `malformed` —
     because "the code changed" and "the bytes are damaged" mean different things to
     somebody reading a log.

145. **`Ledger.record/1` treats a repeat as a success, not an error.** Its doc always said
     "idempotent" and its return said otherwise, which is the kind of mismatch that bites
     the next caller: a worker replaying a queued report after a reconnect has done
     nothing wrong and must not be told it has. `{:duplicate, existing}` hands back the
     record that stands — the *first* one, because what the gateway billed is what the
     first report said — and says which case it was, because a caller keeping a running
     total needs to know whether to add this one.

146. **Reconciliation reports and never repairs.** A job that silently rewrote the ledger
     to match the gateway would destroy the evidence that they disagreed, and which of
     them is right is a question about the incident rather than about the numbers. Drift
     is reported in three directions — missing, extra, mismatched — because "the gateway
     billed something we never recorded" and "we recorded something the gateway never
     billed" are different incidents with different causes.

147. **Reconciling is by gateway request id and nothing else.** It is the only identifier
     both systems share; reconciling by timestamp and amount would make two identical
     calls a second apart indistinguishable.

148. **The dev PostgreSQL's WAL archive volume is chowned before PostgreSQL starts.** A
     named volume is created root-owned and PostgreSQL archives as `postgres`, so every
     `archive_command` was failing silently — 748 of them — and point-in-time recovery
     had nothing to recover *through*. Found by writing the drill and running it, which
     is what a drill is for.

149. **The failover test runs a real second replica behind a real Service.** A test that
     faked either would not exercise the thing under test: `:global` is how two replicas
     agree there is one placement actor, and a Service is why losing one is a reconnect
     rather than an outage. The Service picks a backend *per connection* and does not move
     connections already established — because a real one does not either, and the worker
     noticing its socket broke and dialling again is the behaviour being checked.

150. **The enrolment verifier can come from configuration, not only from options.** A
     replica started as a whole application has a listener the supervision tree started,
     with no place to pass a function — and a test module does not exist on a second OTP
     node, so the stub is a compiled module both nodes share.

151. **An anchor for a session that no longer exists is dropped, not fatal.** A session
     erased between the plane's check and its insert is an ordinary race, and taking a
     control connection down over it would turn a tidy-up into an outage.

152. **`Troupe.Plane.Admin` is the only administrative surface, and a test enumerates it.**
     The panel, the admin JSON-RPC and `troupe admin` are three renderings of one context.
     Left to care alone that lasts about a release: somebody adds a button, the CLI does
     not get it, and an operator who works over SSH finds out months later that the thing
     they need is only in a browser. So the parity test asserts every context function has
     both a method and a command, that no method names a function that does not exist, and
     that the arities line up.

153. **The admin context has no function that could return session content.** Not a check
     applied at the edge — the function does not exist, and a test asserts no function is
     even *named* as though it might. No admin role grants access to what a session said;
     reading it requires being on the ACL, and break-glass is out of scope, so there is
     nothing to bypass.

154. **`platform_admin` comes from an identity-provider group; `team_admin` is the one
     role Troupe assigns.** An admin role Troupe could grant would be a way to escalate
     inside Troupe. A team admin is deliberately narrower — one team, and no ability to
     create or remove other team admins, because a team admin who could remove the others
     could make themselves the only one.

155. **A team a `team_admin` may not see is `not_found`, not `forbidden`** — the same rule
     sessions already follow, for the same reason.

156. **`Troupe.Policy` and `Troupe.WorkerProfile` moved into `troupe_protocol`.** The panel
     validates against `TroupePolicy` for fast feedback and admission remains
     authoritative, but the fast check has to be *the same check* or it is confident
     nonsense — so both the plane and the operator parse the same document with the same
     code, exactly as they already share the KMS behaviour and the object store.

157. **Provisioning is best effort; the grant is not.** A grant is the plane's own record
     and is already made when the custom resource is rewritten. A cluster that cannot be
     reached leaves the projection stale until the operator's next resync, which is the
     right cost — failing the grant would make the plane's own state depend on the cluster
     being up. What happened is reported rather than swallowed, because "saved but not
     applied" is a state a person needs to see and is the normal one in GitOps mode.

158. **Asking who is connected answers "nobody" when the listener is not running.** A
     plane publishing a config bundle must not crash because nothing was attached, and a
     registry lookup is not a reasonable place for a caller to have to know whether the
     control listener is up.

159. **`mix troupe.boundaries` grew module-level rules, and the first one is the panel.**
     The app rules say what an app may know about; this says what a *part* of an app may.
     The panel is inside the plane and could reach anything in it, and the whole
     arrangement of `Plane.Admin` rests on it not doing so. Read from the compiled beams
     like everything else, because what a module declares and what it calls are different
     questions and only the second matters. It found three real violations the moment it
     was written.

160. **The panel's session cookie carries a subject and nothing else.** Not the role, not
     the teams: those are derived on every LiveView mount, so an administrator whose role
     was taken away loses the panel at their next page rather than at the expiry of a
     cookie they are still holding. A cookie carrying the role would be a capability that
     outlived the decision to grant it.

161. **The profile editor renders the diff before applying, and it is the same diff the
     audit records.** Computed by the same function, so what the form promised and what
     the trail says cannot differ. A panel that applied on submit would turn a typo in a
     field nobody was looking at into a fleet-wide change.

162. **Erasing from the panel takes two clicks.** It is irreversible, and a misclick
     should not be enough.

163. **One port, two surfaces, split by path rather than chained.** Chaining the API
     router behind the panel's meant every request the panel answered still ran through
     the API's router, which then tried to 404 a response that had already been sent —
     found by the first test that loaded a page without a session.

164. **The plane's RBAC is confirmed with `kubectl auth can-i`, not by reading the file.**
     A claim about RBAC is a claim about what the API server will allow, and only it can
     answer that. Writing the test found that the plane could not read `TroupePolicy` at
     all — which the panel's fast-feedback check needs — so the chart gained a ClusterRole
     for it. Read only: a plane that could write the policy could raise its own limits,
     which would make the policy a suggestion.

165. **`kubectl auth can-i get pods/log` does not ask about `pods/log`.** The slash form is
     answered as though it said `pods`, which the plane *can* get, so the test would have
     passed while proving nothing. Subresources need `--subresource`, and the answer is
     the *last* line of the output because `kubectl` writes its warnings to the same
     stream.

166. **An image is a string in the plane's record and a `{repository, tag}` in the custom
     resource.** The policy matches on the repository, so the resource splits it; the
     plane records what a person typed. Converted at the boundary rather than stored
     twice, because two fields that have to agree eventually will not. The last colon
     separates the tag, so a registry with a port is not read as a repository with a very
     odd tag.

167. **A missing secret is reported, not refused.** The reference may be right and the
     secret on its way, and a profile that would not reconcile until every secret existed
     could not be created before them. What it must not be is invisible — a pod that will
     not start because a `Secret` is missing is a mystery unless the condition says so.

168. **A test that restores something Helm owns must restore its field manager too.**
     Recreating the admission binding with a default manager left `helm upgrade` unable to
     apply it — the object was there and `.spec.matchResources` belonged to somebody else
     — which is a cluster the test quietly broke for everything after it.

169. **An admin method's role comes from the caller's identity and never from the
     request.** A parameter named `role` or `actor` is ignored: it would otherwise be an
     escalation anybody could write.

170. **Only known keys become filter options.** `String.to_existing_atom` on
     caller-supplied keys would be a way to grow the atom table from outside; anything not
     on the list is simply not an option.

171. **`troupe admin` reaches the plane over the same public `/rpc` every other client
     uses, with the token `troupe login` stored.** There is no privileged path: a person
     with `curl` and a token can do exactly what the binary can. The commands are
     generated from one table, and the parity test asserts the table covers the context.

172. **`SecretMissing` does not make `Ready` false.** The spec gives them separate
     conditions because they are separate facts: `Ready` is the operator saying it
     reconciled what it was asked to, and it did — the namespace, the StatefulSet and the
     rest all exist. Whether the pods can *start* is the secret's business, and merging
     the two would make a missing secret indistinguishable from an apply that failed. An
     earlier version of this did merge them, and the effect was that every fixture profile
     in the cluster tests went unready at once.

173. **The cluster suite creates the secret its fixtures refer to.** A profile referring to
     a missing secret has to be a *test that says so* rather than the state every other
     test happens to be in — which would make `SecretMissing` true everywhere and prove
     nothing anywhere.

174. **The cluster suite sweeps its own litter on the way in.** A test that is interrupted
     never runs its `on_exit`, and every profile it leaves behind is reconciled for as
     long as the cluster lives — a refused one refused again every thirty seconds,
     forever. Only names the suite itself generates: a profile somebody created by hand is
     theirs.

## Stage 4: collaboration and client-hosted tools

175. **`input_queued` is announced once, remembered in agent state.** `gen_statem`
     re-delivers a postponed event on *every* state change, and `thinking -> acting` is a
     state change: announcing from the postpone clause without remembering what has been
     announced tells everybody watching that one input was queued three times. `State.queued`
     is that memory, cleared when the input is taken.

176. **Input is one message shape: `{:input, source, content, actor, meta}`.** The three-
     and four-tuple forms are gone and the watcher goes through the public
     `Agent.Server.input/5` like every other caller. Two shapes meant two clauses per state
     and a `command_id` that some inputs had and others did not.

177. **A `command_id` is generated for inputs that arrive without one.** The watcher and a
     seeded task have none; the schema requires one. Generating it at the edge keeps every
     input in the log the same shape, and a client that supplied its own still gets that one
     back.

178. **`author` falls back to the source, not to "system".** A watch trigger's author reads
     `watch`, which says more about who asked than `system` does, and a subject is used
     whenever there is one — which is the case several clients on one session exist for.

179. **Presence is published through a module with no path to the log.**
     `Gateway.Presence` calls `Events.publish_ephemeral/4` and nothing else, so the
     Forbidden-list item holds structurally rather than by a filter somebody could remove.
     Joining and leaving are announced by the connection where subscriptions are taken out
     and dropped, so a client that crashes still leaves.

180. **`presence.set` needs only `observe`, and does not activate a session.** Presence
     changes nothing, so a seat is enough; and a session must not be woken from dormancy
     because somebody's cursor moved — there is nobody attached to tell.

181. **Consent is a challenge bound to one connection, one subject and one set of tool
     names, spent once.** A registration that replays a spent challenge is refused rather
     than treated as idempotent: a replayed challenge is exactly what a stolen one would
     look like. The challenge lists the names the *person* offered, not the prefixed names
     the model will call — the prompt is about their notes tool, and `client.` is our
     bookkeeping.

182. **A client-hosted tool asks by default.** The consent was to offering the tool, not
     to every call the model decides to make with it. A profile that says otherwise still
     wins, exactly as for a built-in.

183. **The registering connection owns the tool because the closure reaches that
     connection and no other.** There is no name for a second client to call and no
     registry to look one up in, so "only the registering connection can serve its tools" is
     a property of the value rather than a check somewhere.

184. **A dropped registrant is answered from `Connection.terminate/2`.** `ClientTools`
     hears about the registration through its own monitor, but it cannot unblock a tool task
     already waiting on an answer. Doing it where the answer was going to arrive turns a
     dropped laptop into an error result in milliseconds instead of at the tool timeout.

185. **`ClientTools` sits above the agent in the session tree.** A restarted agent must
     come back to the same registrations: the client that offered them has not gone
     anywhere and would have no way of knowing it needed to offer them again.

186. **The taint is added to the summary projection by the fold, not declared in its empty
     map.** A session nothing has tainted folds to exactly the map it folded to before the
     clause existed, so every recorded fixture hash still holds and no upcaster is needed. A
     client reads a missing key as "not tainted", which is the right default and the only one
     an old log can support.

187. **`Gateway.Transport` and `Protocol.Client.Transport` are the seam the WebSocket sits
     behind.** A connection is the protocol — handshake, scopes, subscriptions,
     backpressure — and none of it is about sockets. A second copy for a second transport is
     how two implementations drift apart.

188. **A WebSocket frame gains a newline going in and loses one coming out, in exactly two
     places.** Both transports hand their callers newline-terminated chunks, so buffering is
     one code path. Getting this wrong is silent: the connection simply waits for a newline a
     frame never carries.

189. **The WebSock handler and the connection are two processes.** WebSock callbacks own
     the frames and must return them; a connection has to keep answering calls —
     `tool.invoke` among them — while frames are arriving. One process could not do both.

190. **The token may arrive in a header or in `initialize`, and `initialize` wins.** A
     client that sent both meant the one it put in the message; preferring the header would
     make a refreshed token impossible to use on a connection that is already open.

191. **A worker with no plane configured does not start the link.** Retrying a Service name
     that does not resolve, forever, is not resilience: it makes "the plane is down", which a
     pod must survive, indistinguishable from "there is no plane", which is a deployment that
     was never finished.

192. **A pod may load its JWKS from disk at boot.** `Worker.Auth` claims a worker can say
     yes or no without asking the plane, and that claim was false for the window between a
     pod restarting and the plane's next push. A cached copy closes it; a path that is
     configured and unreadable warns rather than refusing to start, because the push still
     works and a stale mount should not be an outage.

193. **Readiness reads a drain flag.** Step one of a drain — stop taking new work — was in
     the drain's own docstring and implemented nowhere. `Drain.draining?` in
     `:persistent_term` rather than a process, because the thing asking is a health check
     that must answer while everything else is shutting down.

194. **`mix deps.compile` cannot run in the Dockerfile's dependency layer.** In an umbrella
     the sibling apps are path dependencies, so it tries to compile `troupe_core` before any
     of its source has been copied. What that layer is worth is the *fetch* — the part that
     needs the network — and that is still cached on `mix.lock` alone.

195. **`Troupe.MCP.Client` and `Troupe.MCP.Server` moved to `troupe_protocol`.** Two very
     different callers hold the same contract: a worker pod offering a *profile's* servers to
     every session on it, and a harness offering a *person's* to one session. A second copy in
     the TUI would be a second thing to keep in step. The adaptation to `Troupe.Tool` stays in
     core, where tools live.

196. **The latency done item gives each of its five clients a session of its own.** Five
     clients hammering one session measures how long a queue behind a busy agent takes to
     drain, which is a property of the model's speed rather than of the transport. The done
     item asks about `input.send` to `input.accepted`, and that is the load under which that
     number means something.

197. **The latency probe reaches the pod through `kubectl port-forward`, not an Ingress.**
     kind installs no ingress controller, and adding one would put nginx's latency in the
     number without making it more honest about Troupe's.

198. **The 200-input ordering test raises `max_turns` to 1000.** The default forty is a
     guard against a runaway agent, not against a busy conversation; left alone it silently
     capped the first run at forty accepted inputs and looked like a throughput problem.

## Running the remote locally

199. **The plane's database is configured outside the autostart gate.** A migration is a
     release that reaches its repo and serves nothing —
     `bin/troupe_plane eval Troupe.Plane.Release.migrate()` — and gating the database on
     "is this plane serving" made that impossible. The *raise* stays inside the gate,
     because a plane that is actually serving must have a database and starting one
     against a silent default would look like data loss.

200. **Migrations are a Helm pre-upgrade hook, not the application's `start/2`.** Two
     replicas starting at once would both migrate, and a migration that failed would look
     like a plane that would not boot rather than like a migration that failed.

201. **A worker publishes a whole URL when it enrols, not a bare host.** The scheme and
     the port are how the pod's Ingress is actually reached, and the pod is told them by
     the operator. A client that had to guess `wss://…:443` could not reach a cluster
     behind a port mapping, and every client would have to guess the same way.

202. **A `WorkerProfile` says which provider and which model.** It named an endpoint and
     a secret and nothing else, which is a profile that cannot make a request: the pod
     fell back to whatever the client default was. `llm.provider`, `llm.model` and
     `llm.smallModel` are additions to the CRD, so an older profile still applies.

203. **The dev dependencies are in `dev/kind/`, not in the chart.** PostgreSQL, MinIO,
     OpenBao and Dex on `emptyDir` with static credentials are a laptop, not a
     deployment. Keeping them out of the chart is what stops somebody installing them by
     accident, and the chart continues to reference every secret rather than creating
     one.

204. **The local cluster uses Dex and the real device flow.** A bypass — a static token,
     a "dev login" — would mean the thing being run locally was not the thing that ships.
     The password is in a ConfigMap because the cluster is unreachable from anywhere
     else, which is a property of kind rather than a choice about secrets.

205. **Every container is told its scheduler count and its port-table size.** The BEAM
     takes the first from the host's CPU count and the second from `RLIMIT_NOFILE`, and a
     container runtime sets that to 1073741816 — so the port table alone was 1.5GB,
     allocated before a module had loaded. `:erlang.memory(:system)` read 2073MB with the
     default and 19MB with `+Q 65536`. Every Troupe pod was OOMKilled in one second with
     nothing in its log.

206. **`enableServiceLinks: false` on every Troupe pod.** Kubernetes injects
     `<SERVICE>_PORT=tcp://ip:port` for every Service in the namespace, so
     `troupe-plane-control` becomes `TROUPE_PLANE_CONTROL_PORT` — the name a release reads
     a port *number* from. A pod that inherited it died in its config provider.

207. **A worker's NetworkPolicy allows its key manager and its object store.** The rule
     covered them only while they were outside the cluster, and the chart's own defaults
     put them inside it. A pod that could reach neither could not activate a session at
     all.

208. **A pod gets two projected tokens, not one automounted one.** The enrolment token is
     for the plane; a second, `troupe-kms`, is for the key manager. Audience-bound both
     ways: the token the plane accepts cannot open a session key, and the one the key
     manager accepts cannot enrol. Before this the worker had no credential for OpenBao at
     all.

209. **Object-store credentials reach worker pods.** The operator set the endpoint and the
     bucket and nothing else, so a pod signed with `nil` and crashed inside the signer, a
     long way from where the mistake was made.

210. **The plane pushes its JWKS when a worker enrols.** The worker has always known how
     to receive `jwks.updated`; nothing ever sent one, so every pod's key set was empty and
     no session token could be verified. Pushed rather than fetched, because a pod that had
     to reach the plane to check a token would make every attach depend on the plane being
     up — which is what the control channel exists to avoid.

211. **The plane refetches a provider's keys when a signature fails.** The cache had no
     way to notice a rotation, so a provider that rolled its keys locked everybody out
     until the plane restarted. Bounded to one refetch a minute, which is what stops the
     retry becoming the load generator the cache exists to prevent.

212. **A provider's id_token is not held to Troupe's fifteen-minute ceiling.** That rule is
     about what Troupe mints for a pod. Applying it to an identity provider would refuse
     every provider whose id_tokens last an hour, which is most of them; the signature, the
     issuer, the audience and `exp` are all still checked, and the token is exchanged
     immediately for a plane token that does have the ceiling.

213. **Platform admin is decided by identity-provider *groups*, not by enabled teams.** A
     team is something the plane decided to do about a group — it has a budget, grants and
     a volume — and requiring the admin group to be one made a fresh plane
     unadministerable: enabling the first team is itself a platform-admin action.

214. **One implementation of "turn the stored refresh token into a plane token".** There
     were two, and both had the same bug: a provider that rotates refresh tokens — which is
     most of them — invalidates the stored one on first use, so everything worked once and
     then asked you to log in again.

215. **`troupe --remote` asks the plane which profiles are granted.** Reading the list
     login happened to store meant a grant made this morning needed a fresh login to use
     this afternoon.

216. **`--auto-approve` is answered by the client, over the protocol.** Not by telling the
     session to stop asking: a session on somebody else's pod is not one a client gets to
     disarm, and the approval stays in the log with the name of whoever gave it.

## Deploying

217. **The plane's `topologies` are built in `runtime.exs` when `RELEASE_DISTRIBUTION` is
     `name`.** `libcluster` was a dependency, the RBAC for it was in the chart, and nothing
     ever configured it — so the chart's default of two replicas produced two *planes*, each
     placing sessions and reserving budget as if it were alone. Distribution is the switch
     because it is the honest one: a node that is not distributed cannot cluster, and a
     single replica should not open a distribution port for nothing.

218. **`kubernetes_ip_lookup_mode: :pods`.** libcluster defaults to `:endpoints`, which
     applies the selector to *Services* — and a Service carries `component=plane` as its
     selector rather than as a label of its own, so the default matched nothing, found no
     peers, and logged nothing about it. Verified by `:global.whereis_name/1` resolving to
     the same node from both replicas, which is the property that was actually wanted.

219. **Team volumes go on Scaleway File Storage, worker disks on Block Storage.** The team
     volume is the only `ReadWriteMany` claim Troupe makes, and File Storage supports it
     natively with a CSI driver preinstalled on Kapsule — so the alternative, running a
     distributed filesystem, buys nothing. It costs a regional pin to PAR until AMS lands
     in 2026, and it is the only component with that restriction.

220. **OpenBao is the one thing not moved to a managed service.** Troupe uses KV v2 for
     session keys and the transit engine to sign plane tokens, and Scaleway's Key Manager is
     neither of those APIs; moving would mean a second KMS adapter and a second signer, for
     a managed service holding the keys that protect every session. Their Key Manager is
     used for what it is good at instead: auto-unsealing it.

## Stage 5 — skills and MCP servers

221. **The plane reads `TroupePolicy` from the cluster, through one module.** Nothing had
     ever set `:troupe_plane, :policy`, so outside the tests the plane's profile check ran
     against no policy at all. `Troupe.Plane.ClusterPolicy` reads the configured document
     when there is one and otherwise the named `TroupePolicy` over the same client
     provisioning uses, per call and uncached, and both `Provision` and `Bundles` go
     through it — the bundle's egress refusal and the profile editor's verdict cannot be
     reading two different documents. The name comes from `TROUPE_POLICY_NAME`, the
     variable the operator reads, for the same reason.

222. **No policy means every MCP host is allowed, said once.** A development plane and the
     test suite have no cluster. Refusing every host there would make publishing
     impossible where bundles are written; the warning is logged the first time so a
     production plane that lost its RBAC does not fail silently open. `:egress_allowed` in
     the application environment replaces the policy with a function, which is the seam a
     test uses to say "nothing is allowed" without composing a policy document.

223. **Publish validates with the shared contract and answers in sentences.** `Bundles`
     calls `Troupe.Protocol.Bundle.validate/2` and turns its list of messages into
     `{:error, {:invalid_bundle, messages}}`; `Admin` renders that as `invalid_params` with
     `data.reason = "invalid bundle"` and `data.errors`. `admin.bundle.validate` returns the
     same error rather than `{ok: false}`, so `troupe admin bundle validate` fails in a
     pipeline and the panel renders a check and a failed publish through one path. The
     built-ins a bundle may not shadow are listed in the plane (`build plan general
     explore`) because the plane does not depend on core, where they live.

224. **The `summary` column is written once and empty means "older plane".** A version is
     immutable, so its summary is too; rows from before the column keep `%{}`, which the
     panel shows as "summarised by an older plane" rather than as a confident zero.
     Nothing backfills, because a migration that parsed documents would be running the
     bundle validator inside a schema change.

225. **`config.updated` carries `mcp_servers` for one more release.** The push is now
     `{channel, version, bundle_hash}` and the worker fetches the document by hash, but a
     worker from before `bundle.fetch` applied only what the push carried. Dropping the
     field in the same release would have left such a pod with no servers until it was
     rebuilt; it goes when no such worker can be running, and the comment in `announce/1`
     says so.

226. **`bundle.fetch` answers by hash first, preferring the asking pod's channel.** The
     same document on two channels has one hash and two rows, and either row's content is
     right; the channel and version in the answer are the pod's own when they can be, so
     a log line on the worker names the version the pod was told about. `{channel,
     version}` is accepted too, for a session pinned to a version the pod has never been
     announced. A bundle is configuration an admin published and may cross the control
     channel; session content still never does.

227. **A pod on a retired newer version is "ahead", and adopted.** Adoption compares the
     heartbeat's hash with the channel's *current* version. After the newest version is
     retired, a pod that materialised it reports its hash and keeps every version it was
     told about, so it can serve the current one from its own directory; listing it as
     stale would make every rollback look like a fleet that had not caught up. It is
     reported separately so an operator can still see it.

228. **The plane writes `mcpServers` on publish and on retire, from the current version.**
     `Bundles.project_mcp_servers/2` rewrites every profile on the channel and
     re-provisions through `Provision.apply/2`, the path `profile.put` uses, so GitOps
     mode commits the same change. It runs from `Bundles` rather than from `Admin` so a
     publish from any caller projects; a cluster that cannot be reached is logged and the
     publish succeeds, as `team.grant` already does for `teams`. Entries carry `name`,
     `url`, `header`, `timeoutMs`, and — only with a `credential_ref` — `credentialRef`
     and a `secretRef` of `troupe-mcp-<server>` / `token`, the fixed convention the plan
     names; a server with no credential stays in the list because egress is decided from
     it. The projection is not re-validated against egress: a policy that tightened since
     should stop the next publish, not make a retire fail.

229. **`profiles.list` offers the bundle's primaries *and* the built-ins it does not
     replace.** Built-ins sit below the bundle in the definition search order, so a bundle
     that adds `reviewer` has not taken `build` away; offering only the bundle's would
     refuse a name the pod would happily start. The order is the bundle's first, then
     `build`, `plan`. The offering is decoded from the document on each call rather than
     cached: the document is one row the plane already holds, and a cache keyed by hash
     was more code than the parse it saved.

230. **`session.create agent:` is checked before anything is reserved.** Against the same
     current version `create_row` pins, with the names that would have been accepted in
     the error, so a client can correct itself; placing, budgeting and then failing on the
     pod would have spent a slot and a reservation on a typo. The name reaches the pod as
     `agent` in `session.activate` and is not stored on the row — the pod's
     `session_created` is its record.

231. **`admin.bundle.get` and `admin.mcp.check` are either role; `validate` is platform.**
     A bundle holds prompts, skill files and the *names* of credentials, never a value, so
     there is nothing in it a team admin may not read about the profiles their team uses,
     and the same is true of "may a pod reach this host". Validating is a step of
     publishing and takes publishing's role. `bundle.get` also carries adoption per
     profile, so the bundles page needs no private path to what the workers page shows.

232. **`troupe admin bundle publish` takes a directory, assembled client-side and validated
     by the plane.** `agents/*.md`, `skills/<name>/**` and `mcp.yaml` or `mcp.json` become
     a `schema: 1` document, with each skill's description read from its `SKILL.md`
     frontmatter rather than asked for twice; nothing is checked in the CLI, because the
     plane checks every client's document with the same code, and two validators would
     drift. A directory with none of the three parts is refused as almost certainly the
     wrong path. The panel keeps a JSON textarea for input and shows the current version
     as structure, because a bundle's home is git and the CLI, and structured editors for
     three kinds of thing were more page than the studio needs today.

## Stage 5 — the operator and MCP servers

233. **An MCP credential is injected under the name the bundle's `credential_ref` gives it,
     and `TROUPE_MCP_<NAME>_TOKEN` when it gives none.** The name is computed in one place,
     `WorkerProfile.MCPServer.credential_env/1` in `troupe_protocol`, because three parties
     have to agree on it — the plane writing the spec, the operator writing the pod, the
     worker reading the variable — and a convention each of them spelled for itself would
     drift. It is emitted only for an entry with a `secretRef`: a variable nothing sets
     would be a reference the worker then had to see through. Every such variable is
     `optional: true`. Without that a missing Secret is a pod stuck in
     `CreateContainerConfigError`; with it the pod starts, that server is offered without
     a credential, and the profile's `SecretMissing` condition names what is absent.

234. **The pod learns its servers from `TROUPE_MCP_SERVERS`, one JSON variable.** The
     worker already reads exactly this shape — `Troupe.MCP.Server.from_config/1`, the
     same reader the bundle push goes through — so a per-field flattening would have been
     a second contract for the same thing. Fields the spec is silent on are left out rather
     than written as `null`, so the worker's defaults apply. The CRD gains `credentialRef`,
     `header` and `timeoutMs` so the spec can carry what the bundle carries and a pod is
     right before its first `config.updated`, not only after. A change to the list changes
     the env, which rolls the StatefulSet under the existing rules; the encoding is stable
     across reconciles because the maps are small enough for Erlang to keep sorted, and an
     env value that moved with map order would roll pods for nothing.

235. **A wildcard in `allowedEgress` becomes a Cilium `matchPattern`; an exact name stays a
     `matchName`.** `matchName` takes a star literally, so a wildcard the policy admitted
     produced a rule that allowed nothing, silently. Cilium's `*` in a pattern is a run of
     hostname characters without a dot — one label — which is what `Policy.matches?/2` and
     the admission CEL already take `*.example.com` to mean, so the admission check, the
     operator's check and the network now agree on the set of names. A profile's own
     wildcard entry is compared as the string it is, so it passes only a policy carrying
     the same pattern. The admission policy already counted `mcpServers[].url` hosts as
     egress; it was verified and left alone.

## Stage 5 — workers, skills and unattended sessions

236. **Core builds its `Definition` from the shared parser's map.** `Troupe.Agent.Definition.parse/3`
     is `Troupe.Protocol.AgentDefinition.parse/2` plus a struct, and the duplicated
     frontmatter code is gone. One parser means the plane refusing a definition at publish
     and the worker loading it at session start cannot disagree about what a file means;
     `from_parsed/2` is public so a caller holding a bundle's already-parsed agents does
     not parse them twice.

237. **A definition lists no skills unless it says so.** `skills:` defaults to `[]`, `all`
     opens every skill the bundle carries, and `allows_skill?/2` mirrors `allows_tool?/2`.
     The default is empty rather than `all` because a skill is a paragraph of prompt an
     admin can change under a running profile, and a profile that never asked for any
     should not grow one because somebody published it.

238. **Bundle definitions load between the built-ins and the config directory.** Built-in <
     bundle < global < project, with `source: :bundle`. On a worker the last two are empty
     by design, so the bundle is the effective source; on a laptop the option is absent and
     the order is what it was.

239. **The skills mount is kind `bundle`, named `skills`, and read-only whatever it is
     asked to be.** `Mounts.new/1` forces `:ro` on that kind rather than trusting the caller,
     because the same table is the sandbox's bind list, and a skill that could carry a
     script `shell` runs from its own directory is the thing the plan refuses. `skills:/`
     is the prefix a model writes; `bundle` is what the entry is a piece of, and the mount
     is only added when the bundle actually has a `skills/` directory, so a profile with
     nothing but MCP servers records the same `mounts_resolved` it always did.

240. **The `skill` tool is scoped to the agent's context, not registered pod-wide.** It reads
     the bundle *this session* is pinned to, and two sessions on one pod may be pinned to
     different versions, so it cannot live in `:remote_tools` beside the MCP tools.
     `Tools.available/2` is `for_definition/2` plus the tools the context adds, `specs/2`
     offers from it, and `authorize/3` falls back to it after the pod-wide list — one gate,
     as before. `Ctx` gained `bundle` for this and `Agent.State` carries it down to
     subagents.

241. **A skill the profile does not list is not found, not denied.** From inside the session
     it does not exist, the same way another team's volume does not resolve. The tool is
     offered only when the bundle has skills and the profile lists at least one, so a model
     that can see the tool always has something it may ask for.

242. **The prompt carries names and descriptions, the tool carries the body, the log
     carries nothing extra.** One line per listed skill under a fixed heading; the
     instructions cost nothing until asked for; and the `tool_call_started` /
     `tool_call_completed` pair is the whole record of which skill was read and when. A
     separate `skill_read` event would say the same thing twice.

243. **`session_created.kind` is always written; `origin` and `bundle_version` only when
     present.** `kind` is `team` from a worker and `local` otherwise, so a listing can tell
     them apart without inferring it from paths. The optional fields are omitted rather than
     written as `null`, so a laptop session's first event gains one key and nothing else.

244. **`Troupe.resume/2` passes a task through, and the root seeds one only on an empty
     agent log.** The old `task: nil` was the guard against re-running a prompt; the real
     guard is in `Agent.Server.replay/2`, which seeds only when the agent has no events of
     its own at all — stricter than "no `user_input` yet", and already true. A second
     activation with the same prompt replays the input it took and takes no new one.

245. **The MCP allowlist and permission are applied where the tools are built.**
     `Troupe.MCP.Server` carries `permission` and `tools` from the bundle's wire shape;
     `Troupe.MCP.tools/1` drops what the allowlist does not name before `Tool.new/2` runs,
     and `Tool.new/2` takes the server's permission as the tool's default. `Worker.MCP`
     did not change: it hands configs through `from_config/1` and gets the right tools back.
     Anything but an explicit `auto` reads as `ask`, so a typo in a bundle makes a tool ask
     more, never less.

246. **`approvals: :deny` writes both events and answers with its own reason.** The request
     goes to the log so the transcript shows what the agent wanted; the decision goes to
     the log, actor system, so a later activation finds the call answered rather than
     pending. The gate answers `{:deny, :unattended}` and the tool result says nobody was
     there to approve, because "denied by the user" would name a person who does not
     exist. A decision replayed from the log answers plain `deny`; by then the call is
     almost always complete anyway.

247. **A bundle's directory is its hash with the colon made a dash.** `sha256:` is how a hash
     reads on the wire and in a log, and a colon is not a character every filesystem a
     worker runs on allows in a name. The spelling changes on disk and nowhere else;
     nothing durable records the directory.

248. **The worker verifies against the announced hash, and validates again.** The document
     is hashed over canonical JSON before a byte of it is trusted, and a mismatch is refused
     and logged with both hashes. When no hash was announced — an activation whose version
     the plane could not resolve — the response's own claim is checked instead, so the
     document is at least what the plane says it is. Validation is repeated on the pod
     because the plane's check is the plane's.

249. **A failed fetch with servers inline applies the servers and makes nothing current.**
     `config.updated` may carry `mcp_servers` for one more release, and a pod that cannot
     reach the plane for the document still gets its tools from them. But the pod's
     `bundle_hash` claim stays what it was, because it does not have that bundle, and the
     plane is entitled to see it as behind.

250. **The bundle index is a file beside the directories, and a missing directory is
     refetched.** `bundles/index.json` maps hashes to versions and channels and names the
     current one, so a restarted pod knows what it has, hands the current bundle's MCP
     servers back to the registry before the plane says anything, and fetches again — with
     a short first wait and a slow retry — when the index names a bundle whose directory a
     lost volume took.

251. **The `bundle_hash` claim is a persistent term, published only for a bundle that is on
     disk.** The link reads it on every heartbeat, and the registry may at that moment be
     waiting on the link for a fetch; a call between them would have each waiting on the
     other until a timeout let go. A hash whose directory is missing is not claimed, so a
     pod that is behind reports itself behind.

252. **Activation materialises the pinned version first, and fails rather than run without
     it.** The definitions and skills a session runs under come from that directory, and a
     session that started on built-ins because its bundle was late would be a different
     session that happened to share an id. The pod answers `unavailable` with the hash and
     the reason, and the plane may try another pod or try again. `bundle.fetch` carries
     `channel` and `version` beside the hash so a plane that can answer by version does.

253. **Terms become config overrides at the pod.** `max_turns` is the budget's `max_turns`;
     `wall_clock_seconds` becomes `wall_clock_ms`, which `Budget` already exhausts on;
     `approvals` is `:deny` when it says so and the default otherwise. There is no `auto`
     a trigger can ask for, which is the design's refusal written into the parser.

254. **Status is folded in the manager from the events it already receives.** The root
     agent's transitions, `agent_restarted`, `user_input` and the approval events are all
     it needs; `waiting` outranks everything because a session with a question outstanding
     is waiting on a person whatever its agent is doing meanwhile, and `interrupted` is an
     idle root that came back mid-turn and has not been asked to carry on. The first report
     goes at activation, seeded from the snapshot rather than from events the manager was
     not yet subscribed for; later ones go on change, the first at once and the rest no
     closer than half a second; the dormancy report carries the same four fields so the
     plane's last word on a sleeping session is as complete as its first. `cost_micros`
     comes from the summary's `cost`, which nothing populates yet, so it reads zero
     honestly rather than being invented here.

255. **The committed schema documents were edited by hand.** `mix troupe.schema.gen` could
     not be run where this was written, so `session_created.json` and `agent_started.json`
     under `protocol/schema/v1/events/` were updated to what the generator would write —
     the same three optional fields, in key order. Running the generator should change
     nothing; if it does, the generator is right.

## Stage 5 — service principals and triggers

256. **The prompt crosses the control channel once and is stored nowhere on the plane.**
     `session.create`'s `prompt` travels in the `session.activate` push and only on the
     first activation; a later one replays the log, in which it is already the first
     input. It is the one piece of session content the control channel carries, so it is
     bounded at 64 KiB and the row never sees it — the tests assert the string is absent
     from the session struct. The canary test for the channel is about what workers
     *report*; a plane-to-pod push of a first input is the plan's design, and the
     alternative — a client attaching only to type the first line — is what makes a
     trigger impossible.

257. **Terms are validated key by key, and `budget_micros` is trimmed rather than
     refused.** An unknown key is `invalid_params`, because the worker applies terms as
     configuration and a misspelt cap is a cap that silently did not apply. A slice larger
     than what the team has left becomes what is left: a nightly trigger near the end of
     a budget period should run on the remainder and be stopped by the ledger, not be
     refused for asking. Nothing left is `budget_exhausted` before a row exists. There is
     no `approvals: "auto"`; a trigger that needs none gets a profile whose definition
     says so, which is an admin's versioned act rather than a flag on a schedule.

258. **Budget is reserved again on activation, since it is released on dormancy.** The
     module doc always said `TeamBudget.release` ran at dormancy; making that true
     without the complement would have let a woken session run on no reservation at
     all. `start_elsewhere` reserves the session's own slice — its terms', or the
     default — after placing and before pushing, and a team with nothing left cannot
     wake a session any more than it can create one. Reserving twice for one session was
     already a retry in `TeamBudget`, so an older session whose slice was never released
     is unaffected.

259. **Status is fenced on the epoch, and `done_reason` is the one nullable report.** A
     `session.status` from an epoch below the row's is `conflict`, like a stale seal: the
     session has moved on and its status is the new pod's to say. The counters follow the
     index's rule that an absent field is an unchanged field, but `done_reason` is set
     whenever the report carries the key, `nil` included — a session that starts another
     turn has no done reason any more, and a rule that could only ever add one would leave
     `budget_exhausted` on a session that went on to finish.

260. **No `session_status` lifecycle event from the plane.** The plan has `fleet` on the
     plane side carrying one. The plane's `/rpc` is request and answer over HTTP; the
     `fleet` topic is served by the worker's gateway from the session index it holds, and
     the plane has no subscription mechanism for harness clients to push through. The
     columns and the `sessions.list` filters are what HQ reads; an event would need a
     plane-side stream that does not exist and is not this stage's to invent.

261. **A service principal is a `%User{}` with two virtual fields, not a second struct.**
     Every question about what a caller may do — `teams_for`, `profiles_for`,
     `visible_to`, `role_for`, `actor_for` — takes a `%User{}`, and a `%Principal{}`
     would need a second copy of each. So `Identity.get_user/1` resolves a `svc:` subject
     to a `%User{kind: "service", principal: …}` with no row and a nil `id`, and the few
     functions that join through `memberships` branch on the kind: a principal's only
     team is the one that owns it, its profiles are its own list within that team's
     grants, and `Admin.actor_for/1` gives it `:none` — not even admin of its own team,
     because a credential that could make more of itself is the escalation refused.
     Disabling one makes `get_user/1` return `nil`, which is what refuses its next `/rpc`
     within a token lifetime with nothing revoked.

262. **The secret is a salted SHA-256, not argon2id.** The plan names argon2id; the
     repository has no key-derivation dependency and the brief forbade adding one. The
     secret is 32 random bytes — 256 bits of entropy — so a fast hash is not the
     weakness it would be for a password somebody chose; the salt is per principal so
     two hashes never compare, and the comparison is `:crypto.hash_equals/2`. A wrong
     secret, a missing subject and a disabled principal are one refusal.

263. **`session.grant` is mirrored first and pushed second, as `acl.changed`.** The
     worker already accepts `acl.changed` for its auth mirror; the plane never sent it.
     The plane's ACL table is what `role_for/2` and the next token read, so the grant is
     durable there and the push is for a connection already open on the pod holding the
     session — best effort, and reported in the answer as `pushed`. A dormant session has
     no pod to tell. The plan's "appends `acl_granted` through the pod" is not a contract
     the worker offers on the control channel; when it does, the push changes and the
     mirror does not. A team admin may grant on a private session of their team they
     could not otherwise see, because the sessions this exists for are a principal's.

264. **`session.review` is for anybody who can see the session.** Reviewing changes
     nothing the agent will do; it is an acknowledgement that a person read the result,
     and reading is exactly what a viewer is for. Team visibility gives observe by
     default, and requiring control would have kept the review queue from the people
     it is for. It marks the row and the run, and is audited under `session`.

265. **A run row is written before the session, and a failed create is retried by the
     same key.** Two executors racing on one idempotency key are decided by the unique
     index rather than by luck: the loser reads the winner's run and is handed the same
     session with a token minted now. A run over the concurrency cap is `skipped` with no
     session, so the record shows the cron fired and why nothing happened. A run whose
     create failed is marked `failed` and the next call with its key tries again, which
     is what lets Hatchet retry blindly; a run whose session exists is never retried.
     Live, for the cap, is a run with no session yet, one whose session is active and not
     finished, or one whose session is dormant with an approval waiting — that last
     counts, because a second session would be a second question for the same person.

266. **Run state is computed on read from the session's status.** `created`, `failed`
     and `skipped` are the plane's own decisions at firing and are stored; `running`,
     `waiting`, `done` and `failed`-after-start come from the session columns the worker
     keeps current. A run that had to be told its session finished would be a second copy
     of a fact the index already holds. `budget_exhausted` is `done`: a trigger with
     `max_turns: 3` is meant to end that way. `interrupted`, or any other reason, is
     `failed`.

267. **The template is `{{a.b.c}}` and nothing else, and escapes nothing.** Sections,
     partials and lambdas are left as text, so an event cannot smuggle behaviour through
     a template and a template cannot loop or call. A missing path renders as nothing,
     so a template written for one provider's events survives another's leaving a field
     out; a list is addressed by position. The output is a prompt, not HTML.

268. **Cron is five fields, UTC only, written in a hundred lines.** `* */n a,b a-b a-b/n`,
     day-of-week `0`–`7`, and both day fields restricted meaning either. No time zone
     database is in `mix.lock` and none was added, so `source.tz` other than UTC is
     refused at `put` with a message saying so, rather than accepted and ignored —
     pretending to support it would fire a nightly job at the wrong hour and say nothing.
     `previous/2` skips days that cannot match, which keeps `0 0 29 2 *` bounded.

269. **The scheduler fires once for the latest missed minute, and never backfills a
     new trigger.** A plane down for an hour fires a five-minute trigger once, not
     twelve times; a nightly job that was missed still runs. A trigger that has never
     fired fires only for a minute inside the last two ticks, so enabling `0 3 * * *` at
     ten in the morning does not run it at once. `last_fired_at` is advanced with a
     conditional write before firing, and the key `cron:<id>:<minute>` is the second
     line, so two schedulers produce one session.

270. **The scheduler is a `:global` singleton with a per-replica keeper.** `Singleton`
     starts an actor when it is first asked for; `Placement` is asked for by every
     create and the scheduler by nobody, so `Scheduler.Keeper` runs in every replica's
     tree and asks every thirty seconds. After the replica holding the scheduler dies,
     the next ask from any survivor starts it there. A tick that raises is logged and
     the next tick is thirty seconds away.

271. **Trigger `put` is partial, and the panel's switch is the same call as the CLI's
     file.** An existing trigger keeps every field the attributes leave out, so
     `{team, name, enabled: false}` is a switch-off and a whole definition from git is a
     replacement; the audit row carries the diff either way. The principal is named by
     subject and must belong to the team; a schedule's cron and a definition's terms are
     checked at `put` with the same rules the scheduler and `session.create` apply, so a
     mistake is refused when it is written rather than at three in the morning.

272. **`trigger.fire` is the principal's or a team admin's, and `for_caller/2` decides.**
     A principal may fire the triggers that run as it and nothing else; a person may fire
     the triggers of the teams they administer, by name, by `team/name` or by id. An
     ordinary member is `not_found`, because whether a trigger exists is the team's
     business. The session is created by `Harness.call("session.create", …)` as the
     principal, so a trigger whose principal lost a profile fails the way the principal
     would.

273. **`troupe admin` grows optional arguments, spelt `name?`.** `runs TEAM [TRIGGER]`
     needed one, and a fifth tuple element would have changed the shape every test and
     the usage printer read. A trailing `?` is stripped before the argument is sent,
     required arguments are counted without it, and the usage shows it in brackets.
     `principal create` takes `PROFILES` comma-separated for the same reason a list is not
     a command line.

## Stage 5 — the A2A facade

274. **The task id is the session id, and the facade stores nothing.** `session.create`
     is sent a `session_id` the facade generates — a version 4 UUID, which is what the
     request that made it calls a task id — with the same value in `origin.task`, and the
     id the plane answers with is the task id whether or not it honoured the one it was
     given. Everything a later call needs is the row: `origin.kind` says it is a task,
     the plane's visibility check says whose. A restarted facade, or a second replica,
     answers `tasks/get` identically.

275. **A service principal's credential travels as `Bearer svc:<team>/<name>:<secret>`,
     or as `Basic`.** The card advertises the bearer scheme and some A2A clients can set
     nothing but a bearer token, so the bearer form is the primary one; it is told apart
     from an id token by the `svc:` prefix, which no JWT carries, and the secret is
     everything after the colon that follows the name so a secret may contain colons.
     `Basic base64(client_id:secret)` is accepted too because it is what HTTP has always
     meant by a static credential. Both go to `/auth/exchange` as `{client_id,
     client_secret}`; an id token goes as `{id_token}`. The exchange is cached per
     credential digest until sixty seconds before `expires_at`.

276. **The public card is rendered from the URL; the bundle's card is the authenticated
     extended card.** The card must be fetchable without a token and the facade holds no
     credential, so without the caller's it cannot ask the plane what the bundle offers.
     The unauthenticated card names the profile, where to call, the bearer scheme and
     one skill named for the profile, with `version: "unknown"` and
     `supportsAuthenticatedExtendedCard: true`; the same `GET` with a credential, and
     `agent/getAuthenticatedExtendedCard`, render skills and `bundle:<channel>/<version>`
     from `profiles.list`. A2A's extended card is exactly this distinction, and it keeps
     "the card is public" and "no facade-wide credential" both true.

277. **The security block is spelled both ways.** `securitySchemes: {bearer: {type: http,
     scheme: bearer}}` with `security: [{bearer: []}]`, as the current specification has
     it, and `authentication: {schemes: ["Bearer"]}`, as the earlier one did and the plan
     wrote it. `protocolVersion` is `"0.3.0"` and `preferredTransport` is `"JSONRPC"`. A
     skill carries `tags` because the specification marks it required; a profile whose
     bundle has no skills advertises one skill named for itself so a client that routes
     by skill has something to route to. Field names chosen with less than full
     confidence: `securitySchemes`/`security`, `preferredTransport`,
     `supportsAuthenticatedExtendedCard`, `protocolVersion`, skill `tags`.

278. **A root turn that ends without a tool call is `completed`.** `agent_done` arrives
     only when the agent called `finish` or ran out of budget; an ordinary answer ends
     with a root `llm_response` whose `stop_reason` is anything but `tool_use`, and
     that is the moment a caller wants the answer. The session stays open, which A2A's
     "terminal states are final" does not expect — and a message on a completed task
     continues its session rather than being refused, because the log has
     `input_after_done` for exactly this and a follow-up in a fresh session would have
     lost everything the first one knew. `contextId` is the task id; a message naming
     only a `contextId` addresses that task. Sub-agents' responses are not the answer:
     only `agent: ["root"]` (or none) counts.

279. **`tasks/get` reads the row while the task is being worked on, and the log when it
     is at rest.** The plan says the row alone answers `tasks/get` without history, and
     also that a finished task returns the review text; the two meet here. A task that
     is `thinking` or `acting` with no `historyLength` is the row — the cheap poll. A
     task that is `completed`, `failed`, `canceled` or `input-required`, or any task with
     `historyLength > 0`, is rendered from a reader's replay, because the answer, the
     artifacts and the tool an approval is waiting on all live in the log. The cost is
     the one the plan states: polling a finished task in a loop pays a reader each time.
     When the log is at rest its state wins; when it is mid-turn the row's does.

280. **An `idle` row with a log behind it is `completed`; with nothing behind it,
     `submitted`.** The row's status has no word for "answered and waiting for more",
     and `idle` covers both a session that just got its prompt and one whose turn ended.
     `last_seq < 4` — creation, start and the prompt's `user_input` — is the former.
     The reader path corrects the guess whenever it runs, which for a `completed` row it
     always does.

281. **Catching up and being live are told apart by `head_seq`.** A stream that resumes
     from the caller's `metadata.lastSeq` delivers every update after it, but an
     `input-required` that was answered an hour ago must not end the new stream, so
     updates from before the head are sent with `final: false`, and a task at rest when
     the head is reached gets one final update saying where it stands. Ephemeral events
     carry no `seq` and say nothing about where the replay is. The `input.send` a
     `message/stream` carries is sent after the subscription is acknowledged, or its
     effects could slip between the two.

282. **Artifact ids are the bare hex of the hash, and the bytes are verified before
     they are served.** `published.hash` and blob digests are both `sha256:<hex>`; the
     artifact id and the route use the hex alone, so a published file and a blob share
     one URL shape. The route replays the log to find what the hex names — a published
     destination read back with `fs.read`, or a blob read with `blob.get` — through a
     reader, and a SHA-256 that does not match is a `502` with the reason. `fs.read`
     carries text, so a published binary whose bytes JSON could not preserve is refused
     by the same check rather than served corrupted.

283. **The A2A error table is applied, never the plane's codes.** Troupe's `not_found`
     is `-32005`, which in A2A means "content type not supported". `not_found` and
     `forbidden` on a task both become `TaskNotFoundError` (`-32001`), since the plane
     already refuses to say whether a session another principal cannot see exists;
     `invalid_params` keeps `-32602`; the rest keep the plane's token as the message in
     the `-32000` range. Method-level failures are a `200` with an `error`, as JSON-RPC
     has it; `401` is a caller who is not who they say, `429` a replica at its stream
     limit, `502` a plane that did not answer.

284. **The facade refuses to start without `TROUPE_A2A_PUBLIC_URL`.** It goes into every
     card's `url` and every artifact `uri`, a pod cannot know the host its Ingress
     answers on, and a card that names the wrong URL is a card nobody can call. The
     chart derives it from `a2a.host`. `TROUPE_A2A_PLANE_URL` defaults to the plane's
     in-cluster Service as asked; the plane's NetworkPolicy admits HTTP from the ingress
     namespace only, so a cluster that enforces it must admit the facade's pods on that
     port or point the facade at the plane's public URL — stated in `values.yaml` and
     `docs/a2a.md` rather than fixed in a template this stage does not own.

285. **The tests run a real socket to a fake worker.** `troupe_gateway` may not be a
     dependency, even in test, without the boundaries rule reading as an exception; a
     WebSock handler behind Bandit speaking the same framing is a page of code and lets
     the stream loop, the approval round trip, the token refresh and the artifact route
     be exercised over `Troupe.Protocol.Client` exactly as production does. The stub
     plane owns rows by subject and refuses another principal's, so "a second caller's
     task is not found" is the plane's decision, as it is in production.

286. **`req` is a declared dependency of the facade although `troupe_protocol` already
     carries it.** The facade calls `Req` directly for `/rpc` and `/auth/exchange`; a
     module an app calls belongs in that app's `mix.exs`, which is the same reasoning
     the plane applies, and the boundaries task concerns umbrella apps, not Hex packages.


## Stage 6 — token accounting

287. **Cost is a fold over the log, not a second write path.** Every model call already
     left a durable `llm_response`; making it carry the model, the gateway's request id
     and the cost means the ledger is derivable from what the pod already wrote down.
     The alternative — a second record kept beside the log — has to be made durable
     itself, and then has its own recovery story. This one's recovery story is
     `Log.replay_from/2`.

288. **No price table.** The gateway prices the call before it answers, and
     `Troupe.Plane.Reconcile` already exists to catch the ledger disagreeing with it.
     A price of our own would reconcile against itself, and keeping a table of model
     prices current is a job somebody has to do forever. Where the gateway reports no
     cost, the tokens are recorded with a cost of zero rather than an estimate.

289. **Costs are parsed with integer arithmetic on the digits, never a float.**
     `8.87 * 1_000_000` is `8869999.999999999` in binary floating point. One unit per
     call is a ledger that does not add up, and a ledger that does not add up is worse
     than one that is missing rows, because nobody can tell which number is wrong.
     Truncation beyond six places, because that is what a micro-unit column holds.

290. **A call no gateway named gets `seq:<session>:<n>`, and reconciliation calls it
     `unmetered`.** A log written before this release has real tokens and no cost. It is
     still recorded, because the tokens are real; it gets a synthesised id, because the
     ledger's uniqueness is what makes re-folding safe; and the id has a shape no gateway
     would mint, so the nightly job can count it as a cost that was never captured rather
     than as a call billed twice. Unmetered rows are not drift and do not make a
     comparison dirty.

291. **The sink is a behaviour resolved from application environment, configured for a
     pod and for nothing else.** `troupe_core` cannot depend on `troupe_worker`, and a
     laptop has no plane to report to. `Troupe.Session.Usage.observe/2` is a no-op with
     no sink, which is the same shape `Troupe.KMS.adapter/0` already uses.

292. **The hook is in `Troupe.Session.Log`, after the write and after the publish.**
     It is the single place every durable event passes through with its sequence already
     assigned, and putting accounting last means it can never decide whether the log says
     something happened.

293. **An ETS table, not a mailbox.** The writer is the log process finishing a turn; a
     message to a collector would put that process's mailbox between a turn and the next
     thing the agent does, on a pod running many sessions. `put/2` is `:ets.insert/2`
     from the caller's own process and rescues `ArgumentError`, so a collector that is
     restarting costs a turn nothing.

294. **Keyed by `{session_id, seq}` in an ordered set, so the watermark is free.** There
     is already exactly one monotonic number per session and it is the one the index
     reports. A counter of the collector's own would be a second ordering to reconcile.

295. **The cap drops the newest.** Twenty thousand rows and the table has stopped being a
     buffer. Dropping the newest keeps what remains contiguous from the plane's
     watermark, so the kept rows still flush usefully, and the fold at the next
     activation is what recovers the rest. Every dropped row is logged as a count.

296. **`usage.batch` is a request, not a notification, and its answer is the watermark.**
     A notification would leave the pod guessing what landed. `usage_seq` on the session
     row moves as `greatest(current, offered)` so a retried older batch cannot walk it
     backwards, and is **not** fenced on the epoch: a pod that has since been fenced
     still made the calls it is reporting, and refusing them loses money rather than
     protecting anything.

297. **A duplicate counts towards the watermark; a failed insert stops it.** A watermark
     that refused to move past a record already in the ledger would ask the pod to send
     it forever. A watermark that moved past a record that failed to insert would lose
     it. Records are therefore applied in sequence order and the batch halts at the first
     real error.

298. **`Link.usage/2` is gone; the plane keeps handling `usage.record` for one release.**
     The new worker only sends batches. The single-record method stays on the plane so a
     pod from the previous image keeps working against a plane from this one — the same
     rule `config.updated` got in stage 5.

299. **A charge dated in the future is dated now.** A pod with a fast clock would
     otherwise write charges into a window no report asks about, and a charge nobody can
     see is worse than one dated a few seconds early. The event's own timestamp is used
     otherwise, so a record folded out of a log an hour later still lands in the window
     the call happened in.

300. **`Ledger.Cache` is ETS owned by a process, invalidated by the only writer.** Sums
     over an append-only table get slower every day. `TeamBudget` is already one actor
     per team and is the only thing that inserts, so the invalidation is serialised
     without a lock; a cache that is not running answers by computing, which is what a
     test and a `mix` task get. Only a batch that inserted something invalidates —
     a replaying pod must not cost every panel a fresh aggregate.

301. **No rollup pipeline in this stage.** Raw records with `(team_id, occurred_at)` and
     the cache answer everything the panel asks at this volume. What is owed is the
     retention decision and a row count at which to revisit, not a fold-into-buckets job
     for a table with fifty thousand rows in it.

302. **The 0.2.0 fixtures were re-recorded, and a `metered_turn` added.** The summary
     projection gained `cost_micros`, which moves the witness hash for every fixture —
     the check doing its job. `mix troupe.fixtures.record` refuses to overwrite a
     recorded version because a recorded hash is evidence of what a *released* Troupe
     produced, and there are no release tags: 0.2.0 is the in-development set. The new
     fixture carries a gateway and `simple_turn` deliberately does not, so both readings
     stay covered.

303. **`session.status`'s cost is read from the projection's integer, not from its float.**
     The snapshot keeps `cost` in whole units for the wire and `cost_micros` as the number
     of record, derived on every fold rather than accumulated, so a float never carries
     an error forward. The worker reads the integer and falls back to the float for a
     snapshot folded by an older build.

304. **The admin surface has a fourth rendering, and it is MCP.** Troupe already speaks
     MCP as a client; the person administering a platform of agents increasingly is one.
     `POST /mcp` offers the same method table as tools, on the same bearer token as
     `/rpc`, through the same context — so there is no privileged path and no second
     opinion about who may do what. The tool list is *not* filtered by role: a team admin
     sees `admin_profile_put` and is refused if they call it, because hiding it would mean
     this module holding an opinion about authorisation that the context also holds, and
     the two would diverge.

305. **A destructive tool takes the identifier twice.** The design makes typed
     confirmation the model for everything irreversible, on the grounds that the friction
     should be understanding rather than ceremony. A model has no dialog to read, so it
     gets the same rule as the only guard it has: `confirm` must repeat the argument the
     method names, and the check is in the MCP layer rather than in the context, because
     the context is also what the console's already-confirmed dialog calls.

306. **The method table carries prose and types.** It was a name, a function and a list of
     argument names, which is everything a dispatcher needs and nothing a caller does. A
     model choosing between `admin.team.revoke` and `admin.profile.delete` has the tool
     description and nothing else, so the description *is* the interface and belongs where
     the method is declared. The parity test fails a method with no summary and an argument
     with no description; object arguments name their properties, because a caller told
     only "an object" sends `budget` to a field called `budget_micros` and is told nothing
     is wrong — because nothing was.

307. **A stored setting overrides the deployment; it never replaces it.** A plane whose
     `platform_admin_group` named a group nobody was in had no administrator and no console,
     and the only repair was a Helm change and a rollout. So the settings an operator owns
     live in a table, and the table is an override: absent means "whatever this plane was
     deployed with", and reset *deletes the row* rather than writing today's default into
     it — writing it back would freeze this release's default into the database and make
     the next deployment's change invisible. The deployment stays the floor.

308. **The settings that could shut the console are read-only in it.** The issuer, the
     client id and the audience are listed with their values and cannot be changed from
     inside, for the same reason a lock's keyhole is not adjustable from inside the house.
     They are listed rather than omitted, because "where is this platform's configuration"
     should have one answer, and a missing field reads as a feature nobody built.

309. **The group that decides who administers cannot be saved unchecked.** The design says
     identity configuration cannot be saved until a test has passed. The test that is worth
     passing is not "is that a valid group" but "how many people would administer this
     platform afterwards, and are you one of them" — so the check runs against the value in
     the field rather than the value in the database, and the save is disabled until it has.
     It is gated on that one check and not on all four: a plane whose provider is briefly
     unreachable should still be able to fix the group that is locking everybody out.

310. **Settings are cached for five seconds, not invalidated across the cluster.**
     `platform_admin_group` is read on every administrative request and changes twice a
     year. A change is immediate on the replica that made it — the writer clears its own
     node — and within five seconds everywhere else. Cross-replica invalidation would be a
     new distributed concern for a value whose staleness window is shorter than the time it
     takes to notice.

311. **A profile's diff is keyed by path.** `Audit.diff/2` walks nested maps and reports
     `spec.llm.model`, not `spec`. A profile's whole configuration lives under one field,
     and a top-level diff would report changing a model name as one twenty-line object
     becoming another — technically true, and useless both to the person about to press
     apply and to the person reading the trail six weeks later. Structs are values, not
     maps: a timestamp is one thing that changed, not six.

312. **The profile editor has one apply button, not the design's two.** The design asks for
     Apply now and Commit for review with the consequence between them. Which of the two
     happens is not the operator's choice here — it is `provisioning_mode` — so the button
     is named for what will actually happen and the consequence is written above it. Two
     buttons where one of them is a lie would be worse than one.

313. **A blank field is absent from the resource, not empty in it.** The CRD has defaults,
     and `storage: {size: ""}` overrides them with something the API server refuses. Every
     branch of the spec disappears when nothing under it is set. The exception is a boolean:
     `orgMount` is always written, because an unchecked box sends nothing and treating that
     as "leave it alone" would make a mounted volume impossible to unmount from the form.

314. **`troupe mcp`, not `troupe admin mcp`.** `admin mcp check` is already an admin method,
     and the bridge is not a method at all — it is the transport that carries every one of
     them. It exists because a plane token lasts fifteen minutes and is minted from a
     refresh token the CLI already holds: wiring a model to a plane without it means pasting
     a credential into a configuration file, where it is stale by lunchtime and committed by
     Friday. The bridge interprets nothing, because a bridge that understood the protocol
     would be a second implementation of it.
