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
