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

315. **The daemon serves a WebSocket on loopback, and it is the same server a pod runs.**
     A browser cannot open a Unix socket, cannot open a raw TCP socket, and cannot be told
     to speak NDJSON over one — so every transport the daemon had was unreachable from a
     page, in a tab or inside a desktop shell's webview. A graphical client therefore had
     no way to reach the machine in front of the person using it. The fix is one line of
     configuration rather than a second implementation: `Gateway.Web` bound to `127.0.0.1`
     on a kernel-chosen port, with `Gateway.Connection` behind the upgrade exactly as on a
     pod. A second copy of the handshake, the scopes and the subscription semantics for the
     local case is how the local case and the remote case start disagreeing about what
     `subscribe` replays, and that disagreement is invisible until somebody's transcript
     has a hole in it.

     It is off unless asked for, like the daemon itself: the release is both the daemon and
     the clients that talk to it, and a `troupe ctl` run must not open a listening socket or
     write a discovery file just by booting.

316. **One discovery file, describing the daemon rather than one transport.**
     `daemon.json` used to be written only by the loopback-TCP transport, because a Unix
     socket is found at a known path and needs nothing to say so. With a second door there
     are now two things to publish and one of them has no fixed address, so every local
     transport records itself in one file and the WebSocket is a `ws` key beside the
     primary entry. The two are merged rather than written, so they can be published in
     either order and a listener that restarts does not take the other one out with it.

     The alternative — a second file — means a client reads one path, finds nothing, and
     has to know to look somewhere else. One file that describes the daemon is the shape a
     client actually wants.

317. **`Origin` is the daemon's second fence, and the wildcard is on the port only.**
     The token in a user-only file is what admits a connection: a page on another origin
     cannot read it. So the origin check stops a stray attempt at the handshake rather than
     being the thing that keeps anybody out. What it has to be careful about is the
     wildcard: a development server's port is whatever was free, so the default list says
     `http://localhost:*` — and that must not admit `http://localhost.evil.example`, which
     a substring match would. The pattern splits on `:*` and requires the remainder to be
     digits.

318. **A linked identity is a label, not a sign-in.**
     A daemon knows the operating system's user and calls them `local:<username>`, which
     means nothing off the machine — so nothing it records could be billed, listed by a
     plane, or opened from another device. `identity.link` records the subject the provider
     issued, and from then on every actor in every log is that person.

     It deliberately verifies nothing. The daemon's trust boundary is the file mode on its
     socket, and anything that can reach it can already do everything on it; asking it to
     check a token would be security theatre with a JWKS fetch in it. A daemon reachable by
     somebody who should not be linking has a much larger problem than the label.

     Read from disk on every handshake rather than cached, so a link made on one connection
     is true for the next one. The connection that made the call is relabelled where it
     stands, because having to reconnect to see your own name is the kind of thing that
     reads as a bug.

## The remote alone

319. **This repository is deployed, not installed.** It builds four container images and
     a Helm chart, and nothing else. The `troupe` release — `troupe_tui` and `troupe_ctl`
     wrapped by Burrito into an executable for five targets — is gone, with `install.sh`,
     `install.ps1`, `scripts/build-local`, `scripts/test-install.*` and the four CI jobs
     that built, smoke-tested and installed it.

     The reason is that they were work for a deliverable this repository does not have.
     A client is a separate release from a separate repository; it speaks `PROTOCOL.md`
     and is published wherever an organisation publishes it. Keeping a second kind of
     artifact here meant a build matrix on four native runners, a clean-container check,
     two installer harnesses, an unresolvable default download URL and a cross-compilation
     constraint (`rustler_precompiled` resolving the ExRatatui NIF against the build host)
     that shaped the whole pipeline — for a binary nobody was going to install from a
     private repository's release assets.

     What is left is one build path: `docker/Dockerfile`, four times, for `linux/amd64`.

320. **The two client apps were deleted rather than kept as a test harness.** The TUI had
     been reduced to "the protocol's test harness rather than the product's face", and it
     was a real one: `mix troupe.boundaries` held both apps to `troupe_protocol`, which
     was the mechanical proof that the built-in clients had no private access.

     Deleting them gives that proof up, and the replacement is weaker in one way and
     stronger in another. Weaker: 6,700 lines of client exercising the protocol on every
     run are gone. Stronger: there is no longer any client inside the boundary to be
     special, so "no private access" is a property of where the code lives rather than of
     a rule someone enforces. What carries it now is
     `apps/troupe_gateway/test/conformance/conformance.py` — a client written against
     `PROTOCOL.md` in another language with no access to this source — which is why it
     moved under the suite that runs it rather than being deleted as another client.

     `git show 20fe871 -- apps/troupe_tui apps/troupe_ctl` is where they are.

321. **Two clients, two URLs, no discovery.** The front page at `/` links to the graphical
     client through `TROUPE_APP_URL` and to the terminal client through `TROUPE_CLI_URL`,
     both empty-able, neither with a default that guesses. A plane cannot tell whether a
     GUI is mounted on its host or where an organisation publishes a binary, and the
     failure modes of guessing are a door to a 404 and a download link that is not there.
     Unset, the page says what is true: ask your administrator.

322. **A release tag publishes the chart.** The `release` job used to attach binaries and
     a `SHA256SUMS` to a GitHub release. It now runs `helm package` with `--version` and
     `--app-version` set to the tag without its `v`, and attaches the tarball — so an
     install of that file pulls the images the same run published, rather than whatever
     `values.yaml` was last edited to say. `chart` gates it, because publishing a chart
     `kubeconform` has not seen would be worse than publishing nothing.

323. **A server release carries Linux reapers only.** `Troupe.Release.build_reapers/1` set
     `TROUPE_REAPER_TARGETS=all`, which cross-compiled five Zig binaries into every worker
     image — three of which no pod can execute. It now sets the two Linux triples. The
     macOS and Windows triples stay in `mix compile.reaper`'s own table because a
     developer's `mix test` runs `shell` on their own machine, which is the only place
     they are built now.

324. **The launcher watchdog went with the launcher.** `Troupe.Wrapper` halted the VM when
     Burrito's launcher process disappeared, so that `kill -9` on the visible `troupe`
     process could not leave an orphaned BEAM holding the reaper pipes open. In a pod
     there is no launcher: the VM is the container's main process and the kubelet kills
     the whole thing. The watchdog was a fix for a problem that no longer exists.

## R0 — three corrections

325. **`docs/plans/README.md` did not carry the sentence R0 asked to be corrected, so the
     correction was made where the claim still lives.** The brief says that page
     "describes the client apps as the protocol's test harness". It does not, in those
     words; what it does is name `apps/troupe_tui` and `apps/troupe_ctl` throughout the
     five plans it indexes, all of which were written while those apps existed. Deleting
     the references one by one would edit the record of what was intended, which is the
     one thing that page exists to keep. So the correction is a preamble: the plans below
     are history where they name a client, the proof they leaned on is now
     `apps/troupe_gateway/test/conformance/conformance.py`, and nothing that reads "the
     TUI does X" describes code in this tree.

## R1 — a toolchain for a machine that has none

326. **The toolchain is available as a container, because a contributor's machine may
     have none of it.** `dev/toolbox/` builds the three things `.tool-versions` names —
     Erlang 28.5.0.5, Elixir 1.20.4, Zig 0.16.0 — plus `inotify-tools` and `bubblewrap`,
     which are the difference between the watch and sandbox done items being proven and
     being skipped. `scripts/toolbox` runs a command in it, joined to the network
     `scripts/dev-up` already creates.

     Two things it does not do. It does not fork the configuration: `config/config.exs`
     names `localhost:55432`, `localhost:59000` and `localhost:58200`, and the entrypoint
     carries those three loopback ports to the compose network with `socat` rather than
     making a second set of values somebody has to keep in step. And it does not share
     `_build` or `deps` with the host — they are named volumes — because a Linux build
     and a host build cannot use the same artifacts, and a bind-mounted `_build` on a
     non-Linux host is the slowest part of a compile by an order of magnitude.

     It is not a deployment artifact and CI does not use it; CI installs the toolchain
     directly, which is faster there and is the path a release is built on.

327. **The toolbox container needs `SYS_ADMIN` and an unconfined seccomp profile,
     because bubblewrap does.** Without them `Troupe.SandboxTest` fails six times with
     "Creating new namespace failed: Operation not permitted" — which reads like a sandbox
     that refused and is a container that refused. It is the same relaxation CI reaches by
     turning AppArmor's `restrict_unprivileged_userns` off on the runner, and it applies
     to the test container only; nothing deployed is run this way.

328. **Five tests do not pass in the toolbox container, and are not made to.**
     `Troupe.Agent.ResilienceTest`'s OS-pid cancellation test and the four gateway tests
     that spawn or `kill -9` a daemon (`AutospawnTest`, `RestartTest`) fail in a container
     and pass on a Linux runner. They were failing before any of this work — checked by
     stashing it and running them again — and the honest thing is to say so here rather
     than to weaken them until they pass somewhere they were not written for. CI is where
     that claim is settled.

## R1 — a dormant session named the pod it had left

329. **`Sessions.dormant/1` never cleared `worker_id`, and now does.** `put_fields/2`
     drops nils on purpose — a pod reporting three of four lifecycle fields must not
     blank the fourth — and `dormant/1` passed `worker_id: nil` through it, so it was
     silently discarded. A dormant session went on naming the pod it was no longer on
     until something else happened to call `Placement.release`, which is why
     `ControlTest`'s "a pod that restarted gives up the sessions the plane still thought
     it was holding" failed about two runs in three: it asserted the row directly, and
     every other reader filters on `state == "active"` and could not see it.

     The fix is a `clear:` option, which is how a caller says it means the nil. `read_only/1`
     had the same hole and is fixed with it; `read_only_for/2` already cleared the column
     with an `update_all`, which is what showed the intent.

## R1 — trigger revisions

330. **A trigger revision is a property of the document, not of the cron row.**
     `stage-6.md` §4 designs revisions for the scheduler, and the brief's second
     correction generalises them. What that means concretely: the hash covers `profile`,
     `agent`, `principal_id`, `prompt_template`, `terms`, `visibility`, `review`,
     `notify`, `concurrency` and `source` — the fields that decide what a run *is* — and
     nothing in it says how the firing arrived. The `source` document is inside the hash
     rather than beside it, so a schedule and a webhook of otherwise identical wording
     are two revisions, and the seven sources `RELEASE.md` W2 adds need no second shape.

     Resolution happens once, at the top of `Triggers.fire/4`, which every path reaches:
     the scheduler, `trigger.fire` on `/rpc`, `admin.trigger.run`, and whatever W2 adds.
     The scheduler learned nothing new.

331. **`visibility` is in the hash; `enabled` is not.** Neither is in `stage-6.md` §4's
     field list, and they go opposite ways for the same reason. Visibility decides who
     may open the session a run made, so an edit to it changes what a run is and must be
     a new revision — leaving it out would let that change happen silently. Enabling and
     disabling changes *whether* a run happens, not what it would be, and the panel's
     switch is a `trigger.put`: a revision per toggle would be a history made of noise.

332. **A run re-reads the revision it recorded, rather than resolving the current one.**
     `fire/4` with a known idempotency key replays, and a failed run is retried by the
     next call with that key. Resolving the trigger's current document at that point
     would let one run name two revisions across its retries, which is exactly the
     provenance the table exists to fix. `revision_of/1` raises rather than falling back
     to the trigger row if the revision is missing, because a silent fall back to the
     mutable row is the failure this is all for.

333. **The backfilled revision is labelled rather than inferred.** Every existing trigger
     becomes revision 1 from its current row, with `reconstructed: true` on it, and every
     existing run points at it. That is not what those runs ran — it is what can be
     proven about them — and the column says so, rather than a comment in a migration
     nobody reads. The hash is computed over the same text representation
     `Revision.document/1` uses at runtime, so the first `trigger.put` after the
     migration creates a revision only if something actually moved.

334. **A session made by a trigger carries the revision hash in its `origin`.** The run
     row already joins the two, but a session found six weeks later in a listing, or in
     an export, or by a person who cannot see the trigger's team, says which wording made
     it without a join. It is a hash, not content, and `origin` was already a free map
     naming the trigger and the run.

## R1 — entitlements below the profile

335. **One child table on the grant, and absence means everything.** `grant_entitlements`
     is `(grant_id, kind, name, mode)` and nothing else. No rows for a grant is no
     restriction, which is exactly what every existing grant meant before the table
     existed — so the migration needed no backfill, changes nothing for a deployment that
     never opens the editor, and the old behaviour is the default rather than a setting.

336. **One row per name, and a list that says both collapses to the deny.**
     `stage-6.md` §2 asks for a unique index on `(grant_id, kind, name)` *and* for deny
     to win "where both are present". Both cannot be persisted under that index, and the
     index is the right half to keep: an editor of three checklists has one state per
     name, and two rows would be a state it could not draw.

     So the rule lives in two places that agree. `Identity.put_entitlements/2` collapses
     a submitted list before it writes, keeping the deny — a caller saying two things at
     once is read the way that grants less. `Entitlement.resolve/2` applies deny-wins to
     rows that arrive *together* without having been written together, which is the real
     case: the union across a person's teams in `profiles.list`.

337. **A listing is the union over a person's teams; a session gets one team's set.**
     They differ on purpose. `profiles.list` answers "what may I use", and a person in two
     teams may use what either gives them — an intersection there would hide something
     they can have. `session.create` answers "what may *this session* use", and a session
     belongs to one team, which is the rule that already decides whose budget and whose
     volume it gets (`harness.ex` `team_for/3`). A person in two teams with different
     entitlements creates two sessions, which is simpler to explain and simpler to audit
     than one session with a union nobody granted.

338. **The set rides on the bundle pin, not beside it.** Every place on the pod that has
     to apply the set is a place that already reads the bundle: the definition search
     order, the skill tool, the session's composed tool list. A set carried separately is
     a set one of those would forget. `nil` is no restriction, which is what a laptop, a
     local session and a plane that has not been told about entitlements all send.

339. **Agents are filtered after the whole search order is merged, and only primaries.**
     Filtering where the bundle is merged would leave a built-in of the same name
     standing in for a bundle agent the team was refused — a different agent answering to
     a name somebody was denied. So `Definitions.load/2` narrows the finished map, and an
     agent outside the set is not in it at all: not for `fetch/2`, not for `primaries/1`,
     not for the delegation tool.

     Only primaries. The plane's set names what `Bundles.primaries/1` offers and what
     `session.create` refuses by name; a subagent is reached only through an agent the
     team *is* entitled to, and narrowing subagents would break a bundle's own internal
     delegation for a team that had simply never listed a name it never names.

340. **MCP discovery stays pod-wide and the filter is where a session's tool list is
     composed.** Asking four servers for their tool list at every create would put
     somebody else's latency on the create path. So the pod discovers once, and
     `Tools.available/2` drops `mcp.<server>.*` for servers outside the session's set. A
     session that may not use `jira` does not see `mcp.jira.*`; the pod still knows the
     tools exist. `MCP.server_of/1` is the inverse of `tool_name/2` and is what lets the
     filter work on names — so a built-in and a client-hosted tool, which no set names,
     are never narrowed by one.

341. **A skill outside the set is `not_found`, not `denied`.** It is the same answer a
     skill the profile did not list already gets, and the two should not be
     distinguishable from outside: what a model can tell apart, it can probe. The filter
     composes *after* the definition's own `skills:` list, because a skill has to be both
     something this agent consults and something this team was granted.

342. **A row naming something the current bundle does not have is kept, not pruned.** A
     bundle can be rolled back, and an entitlement that vanished with a publish and did
     not come back with the revert would be a silent widening. It simply does not appear
     in any offering until the name does.

343. **`entitlements` on `session_created` and on `config_upgraded`.** The first answers
     "what was this session allowed to see" for as long as the log exists, without the
     reader having to know what the bundle said that day. The second is there because a
     publish can add an entry the team is not entitled to: the set is re-resolved by the
     plane at every activation, and the event that already says the configuration moved
     is the right place to say what the session may now see. Both are optional fields on
     an event that already carried optional fields, so `mix troupe.schema.diff` sees an
     additive change.

## R1 — one sealer, and a second tenant in the key store

344. **`Sealer` and `Context` moved to `troupe_protocol`, a move and not a fork.**
     `Storage`, `Cipher` and `Snapshot` were already there; the sealer and the context it
     needs were the two that were not. A daemon sealing a person's private session writes
     the same segments, in the same layout, under the same cipher, to the same bucket —
     and a session sealed by one host has to restore on the other. Two implementations of
     that are two chances to disagree about a byte.

345. **The sealer no longer knows how events reach it.** `troupe_protocol` is what
     `troupe_core` is built on, so a sealer living there cannot call `Troupe.subscribe/1`.
     `:subscribe` is a function of a session id that the host passes in — the worker
     passes `&Troupe.subscribe/1`, and so will the daemon.

     That is not a workaround for the dependency direction; it is what the process is
     actually for. A sealer gets events into object storage. Where the events come from
     is the host's business, and a module that had to know would be a module that could
     only ever have one host.

346. **`KMS.path/2` takes an owner, which is a team or `{:person, subject}`.** Two shapes
     and one function, because a path built in two places is a path that will one day be
     built two ways. A team session's key is under `teams/<team>/`, read by a pod with a
     credential scoped to that team; a private session's is under `people/<subject>/`,
     read by that person's daemon with a credential the identity provider vouched for.
     Neither credential can reach the other's subtree, which is what makes "no worker
     profile is involved in a private session" a property rather than an intention.

347. **A subject with a slash in it raises rather than being sanitised.** A subject is
     opaque and comes from the identity provider; every shape we have seen —
     `idp|ada`, an email address, a UUID — is a fine path segment, and one with a `/`
     is not. Sanitising it would silently make it a *different* person, and two
     subjects that sanitised the same way would share a key. So `KMS.person_segment/1`
     refuses it, loudly, at the one place the path is built.

348. **A key path is a logical path, and the OpenBao adapter encodes it for the URL.**
     Found by the first test that used a realistic subject: `idp|ada` is what Auth0 puts
     in `sub` and is not a valid request target, so `Req` refused it with
     `:invalid_request_target` and the request never reached OpenBao. The policy matches
     the *unencoded* path and the store files the secret under it, so the encoding
     belongs in the adapter and nowhere else — segment by segment, so the separators
     survive. Team paths were unaffected because a team name is `[a-z0-9-]`, which is why
     this survived until a person's key was written.

349. **The plane's erasure policy covers `people/` as well as `teams/`.** Erasure is
     erasure: a person asking for their private session to be destroyed gets the same
     finality a team's session gets, and a plane that could erase one and not the other
     would have two answers to one promise. Still metadata-delete only, still no rule for
     the data path at all — an absence rather than a deny, because OpenBao denies by
     default and a deny rule invites somebody to "fix" it later by narrowing it.

350. **The person policy is templated, and a test renders it with a literal subject.**
     `Policy.person/2` templates on `identity.entity.aliases.<accessor>.name`, which is
     the subject OpenBao itself put on the entity when it verified the provider's token —
     so a daemon cannot name somebody else's subtree by asking, and adding a person is the
     identity provider's business rather than an operator's.

     `Policy.person_for/2` renders the same policy with the subject already in it, which
     is exactly what OpenBao evaluates the template to. The isolation tests issue a token
     with that, rather than standing up a JWT auth mount and an identity provider to
     arrive at the same string. What the template decides is *which* subject lands in the
     rule; what the test proves is what the rule then permits, which is the half that
     could be wrong.

## R1 — a session is created once and opened many times

351. **`resume/2` appends `session_resumed`, not a second `session_created`.**
     `resume/2` is `start_session/1` with a session id, so every reopen appended another
     `session_created`. A log with three of them was a log that had been opened three
     times, and nothing in it distinguished that from a session that had somehow been
     created three times. `session_resumed` has been in the schema since stage 2 and was
     never emitted; it is now, with `dormant_ms` and `moved`.

352. **"Is this a reopen" is asked of what was on disk before the tree started.** The
     first attempt asked `Log.head_seq/1` after `Sessions.start_session/1`, which is
     always non-zero: the agent tree appends `agent_started` on its way up. So the
     question is asked of `Log.read_session/2` *before* the tree starts, and the answer is
     whether a `session_created` is already there.

     That also corrected a comment that had been approximate since stage 1.
     `session_created` is not the first event in the file and never was; it is the event
     that says what the session is, which is the claim that actually matters and the one
     a rebuild depends on.

353. **`moved` is compared against what `session_created` recorded, and an unknown answer
     is `false`.** That is the only thing in the log that claims where the session was. A
     session whose first event is gone — a log truncated by a rebuild — reports not moved
     rather than moved, because "we do not know" and "it moved" are different things and
     only one of them is a warning worth showing somebody.

354. **A resume whose directory is gone falls back to the restored tree, and creates
     nothing.** `Workspace.new/1` refusing a directory that is not there is right, and it
     is the wrong answer for exactly one case: a session being resumed whose recorded
     directory has been moved or deleted, whose history is intact and whose tree is under
     the state directory where a restore put it. Answering `not_a_directory` there loses a
     session over a checkout somebody tidied up.

     The fallback is in `Session.build_opts/1`, not in `Workspace.new/1`, and it is
     narrow: only a session that names itself, only to `<state>/workspaces/<id>`, and only
     when that directory already exists. A session with neither its recorded workspace nor
     a restored tree still fails — putting an agent in a directory nobody asked for is the
     thing `Workspace.new/1` is refusing to do, and a fallback that invented one would be
     doing it quietly.

355. **`private_sessions` at `initialize` is computed, never compiled in.** It is what
     un-gates the client's control, and the two things it needs can both be missing at run
     time: a person the daemon can name — `local:<username>` means nothing to a plane or
     to another device — and somewhere to seal to. A client that offered the checkbox on a
     daemon with neither would be offering a session that silently stayed local. A worker
     always answers `false`, as a fact about the design rather than a setting: a private
     session is sealed under its person's own key in a subtree no pod credential can
     reach.
## R1 — a credential that belongs to a person

356. **`credential_mode` on a bundle's MCP server entry, `profile` by default.** A
     published bundle needs no migration and every profile behaves exactly as it did,
     which is the same shape the entitlement table took and for the same reason: the
     old behaviour is the default rather than a setting.

357. **In person mode `credential_ref` is a slot, and it defaults to the server's name.**
     The two modes read the same field differently because they are the same question —
     *where is this server's credential* — asked of two different places. A slot is
     narrower than an environment variable name by design: lowercase, no separators,
     because it becomes a path segment under `troupe/people/<subject>/mcp/`. Defaulting
     it to the server's own name is what keeps "connect Jira as yourself" from needing a
     second name invented for it.

358. **A `secret_ref` beside `credential_mode: person` is refused at publish.** Not
     resolved at run time in favour of one of them — refused, with the reason. A server
     with two credentials is a server whose identity depends on which code path ran, and
     that is not a thing to find out from a log six weeks later.

359. **A person-mode server projects a slot and no `secretRef` at all.** The plane writes
     `credentialMode` and `credentialSlot` onto the `WorkerProfile` and nothing else:
     there is no Secret, no environment variable, and nothing for the operator to mount.
     Writing a `secretRef` for a server nobody configured a Secret for is how a pod would
     fail to start over a credential it was never meant to hold. The entry is still
     projected, because egress has to see the host either way.
360. **The assertion is a second token, not a session token with another claim.** A
     session token's audience is a pod and its claims are about a session; a key-manager
     assertion's audience is the key manager and its claim is about a person. One token
     doing both would be a token that works in the second place when the first is
     compromised, and the JWT role's `bound_audiences` is what makes that concrete —
     proven by offering it a session token and being refused.

     Sixty seconds, because the pod exchanges it once at activation and then holds the
     *Bao* token for the life of the session, exactly as it already does for the data key.

361. **The mount's keys and the role's claims are configured separately, because OpenBao
     keeps them apart.** `jwt_validation_pubkeys` belongs to the auth mount's config and
     not to the role; a role carrying it is accepted and then answers every login with
     "could not load configuration", which reads like a broken assertion and is a mount
     that was never told what a valid signature is. `Policy.person_auth_config/1` and
     `Policy.person_role/2` are the two halves, rendered here so that what the tests prove
     and what a cluster installs is one string.

362. **The person policy templates on the mount *accessor*, not the mount path.** A path
     can be re-used after a mount is deleted and an accessor cannot, so a policy keyed to
     the path could one day read a subtree written under a different mount. This is
     OpenBao's own rule; it is recorded because the failure of getting it wrong is a
     silent `forbidden` that looks exactly like a policy that is working.

363. **The person policy covers the whole subtree under a person, not one prefix.** It was
     written for `sessions/*` when private sessions were the only tenant; `mcp/*` is the
     second, and a policy written per prefix is a policy somebody has to remember to
     widen — which is how this was found: a correct assertion, a correct role, and a
     `forbidden` on a slot the person owned. Everything under a person belongs to that
     person. That is the whole statement and it is the one worth writing down.
364. **A person-mode call resolves its credential per call, and the pod caches nothing.**
     A profile-mode server's credential is resolved once at discovery because it is the
     same for every session. A person's is not the pod's to hold: it belongs to whoever
     owns the session, and the pod has it for exactly as long as a call takes.
     `Troupe.MCP.person_credential/2` is a function the host installs, the way
     `:remote_tools` already is, because reading it needs a key-manager token scoped to
     that person and `troupe_core` is not where that lives. A host that installs nothing
     answers `not_connected`, which is what a laptop and a local session both mean.

365. **`not_connected` is `{:ok, …}`, not an error.** Nobody having connected a server is
     a fact about the session's owner, not a failure of the call, so the model gets a
     structured refusal it can read and relay rather than a 401 it will retry four times —
     and the session carries on. The hint names Connections and says the server acts as
     *you*, because "not connected" without that reads like an outage.

366. **`identity` is on `tool_call_started` and only where there is a question.** An MCP
     server may act as the profile's service account or as the session's owner, and a
     reader of the log should be able to tell which without knowing what the bundle said
     that day. A built-in runs as the pod and a client-hosted tool runs on somebody's
     laptop; an `identity` on those events would be a field that always said the same
     thing, so it is absent rather than constant.

367. **A session has one identity, and it is the owner's.** Two people attached to one
     person-mode session both reach the server as the owner, fixed at activation and
     recorded in `session_created`. `MCP.owner_of/1` reads it from the attribution the pod
     was told rather than from whoever is typing. A collaborator acting through somebody
     else's credential is a thing people should be told once, in the panel and in the log,
     rather than discover.

368. **`stop_session/1` no longer exits when the log has already gone.** It asked the
     registry whether the *session* was alive and then wrote through the *log*, and a live
     session does not imply a live log: the tree is `rest_for_one` with `Log` first, so a
     session already coming down has lost its log while its supervisor is still
     terminating. Two callers stopping the same session — ordinary at shutdown — raced
     exactly there, and the loser exited inside whoever called it.

     Found by a test that flaked about one run in twenty, and pinned by sweeping seeds
     rather than by re-running until it happened again. Nothing is lost by skipping the
     append: the events are on disk and `session_dormant` is a marker, not a fact anything
     is rebuilt from.

369. **A test that reads source normalises line endings first.** `FoldTest` greps
     `server.ex` for the event types `fold_event/2` handles, so the two cannot drift
     apart — and every anchor in it misses on a checkout that stores CRLF, which reads
     like `fold_event/2` having no clauses at all. It reads source rather than data, so
     the normalisation belongs there.
370. **An assertion is asked for, not handed over at activation.** The token it buys
     lives twenty minutes and a session can live all day, so a pod given one at activation
     would lose its person's credentials mid-afternoon with no way to ask for another.
     `kms.assertion` is a worker→plane control call, which is a round trip the plane is on
     the path of either way, and the refresh is the same call again.

371. **The pod does not choose whose assertion it gets.** It names a *session*; the plane
     reads the owner off the row. A pod naming a session another pod holds is told
     `not_found`, which is the difference between one pod being able to read another
     person's credentials and not — and the plane is the only thing in a position to
     refuse it, because it is the only thing that knows which pod holds what.

     A session with no owner is not a case that had to be handled: the index requires one,
     so there is no row to ask about.

372. **The pod holds the token, never the value.** A slot is read at the moment a call
     needs it and the value is gone as soon as the call is made. What stays in memory is a
     token that can read that person's slots — exactly the shape the session's data key
     already has, in memory for the life of the session and never on disk — and it goes
     when the session's manager terminates.

373. **One ETS table for the pod, not one process per session.** This is on the path of
     every call to a person-mode server, and a lookup that queued behind a session's own
     manager would put a session's latency on its own tool calls. Losing the table costs a
     round trip per live session: there is nothing in it that is not derivable from an
     assertion the plane will sign again.

374. **A refused read is retried exactly once, after throwing the token away.** An expired
     token and a wrong one are indistinguishable from here and the first answer to both is
     the same. Once, not in a loop: a second refusal is a policy problem, and a retry would
     only repeat it.
375. **`me.connections.grant` answers an assertion, not a token.** `stage-6.md` §3c
     sketched it returning "a short-lived Bao token scoped to the caller's own slot". A
     token the plane minted is a token the plane *held*, and a plane that held one could
     have read the slot. So it answers the assertion instead — a signed statement of who
     the caller is, which the plane is entitled to make because it is the thing that
     authenticated them — and the client exchanges that with the key manager itself.

     The same mechanism a pod uses, which is the argument for it: there is one way to
     become a person at the key manager, and the plane is on neither side of it.

376. **There is no `me.connections.revoke`, because there is no credential here that
     could delete one.** The plan lists three methods; removal uses the same grant as
     writing, and the plane's policy has no `delete` under a person's connections on
     purpose. An admin can retire a server from the bundle and can neither read nor remove
     somebody's credential — which is the property the plan states, reached by having no
     method rather than by having one that refuses.

377. **The plane may see that a slot has a version, and nothing more.** Its policy gains
     `list` and `read` on `metadata/troupe/people/+/mcp/*` — KV v2 metadata, which is
     versions and timestamps and never a value. That is exactly what a panel needs in
     order to say "Ada has connected Jira" and the most it should ever be able to say.
     No `delete`, for the reason above.

378. **`me.connections.grant` refuses a slot no bundle asks for, and that is not a
     security boundary.** The key manager's policy is: it would refuse a path under
     anybody else whatever this said. The refusal is so that a typo does not leave a
     credential sitting in a slot nothing will ever read, and it names the slots that do
     exist so the next attempt is right.

379. **A test whose subject is shared is a test that decides what another sees.** The
     database is sandboxed per test and the key manager is not, so the connection tests
     take a fresh subject each. Found by a listing test that saw `connected: true` before
     it had written anything, because the grant test had run first.
## R1 — a deprovision that takes effect

380. **`User.active` was written by SCIM and read by nothing.** The flag existed, the SCIM
     endpoint set it, and no code path anywhere in the plane consulted it — so a
     deprovisioned person could sign in, call every harness method, and go on doing so.
     A flag nothing reads is a deprovision that did not happen.

381. **Signing in no longer reactivates somebody the provider deactivated.** `Login`
     wrote `active: true` on every login, which meant a SCIM deprovision lasted exactly
     until its subject next authenticated — and the token issued after that is one every
     other check in the plane then trusts. Only a person we have never seen is created
     active, which is what a deployment with no SCIM means by the word and the case the
     default is for.

382. **The harness checks on every call, not only at sign-in.** A plane token outlives the
     moment it was issued, so a person deactivated at ten o'clock holds a valid one until
     it expires. Checking at the door would leave every method answering them until then.
     It reads the *row*: the provider's decision reaches us through SCIM, and nothing
     re-reads a claim.

383. **`kms.assertion` refuses a deactivated owner, and that is the door that mattered.**
     A running session needs nobody to sign in. Refusing a deprovisioned person only at
     the harness would have left their credentials reachable by any pod for as long as
     anything they had started kept running — indefinitely, since the pod refreshes on its
     own. Refused here, the window is the pod's existing key-manager token and its lease,
     and no longer.

384. **A deactivated person's sessions are not stopped.** What a session may still do is
     the session's question — its history is the team's, and a person leaving is not a
     reason to lose it — and what it may do *as them* is this one. Stopping them is a
     policy decision with an owner, and `RELEASE.md` W2 already has the shape of it for
     service principals: the thing stops doing what it did as that identity and says why,
     rather than disappearing.

## R1 — a session that belongs to a person

385. **`kind` is a new column, not a reuse of `visibility`.** They answer different
     questions and the defaults make the overload dangerous: `visibility` is who else on
     the team may see a session, and it has defaulted to `private` since the first
     migration, so every unshared team session is already visibility-private. Selecting
     "the private sessions" on that column would have quietly returned most of the
     estate.

386. **The shape is a check constraint, not only a changeset.** A private session has no
     team, no profile and no worker; a team session has a profile. The row is what a
     placement reads, and application code is not the only thing that writes it — a
     rebuild, a migration and a console all bypass the changeset. The changeset is still
     there, so a caller gets a field and a sentence rather than a constraint error, and
     the test asserts both halves: `Sessions.create/1` refuses it, and a raw `INSERT`
     that skips every line of Elixir raises.

387. **`profile` became nullable.** It was `null: false` from the first migration, and a
     private session has no profile to run on. The constraint keeps the old guarantee
     where it still applies: a team session without one is refused exactly as before.

388. **The device that loses the fence is told on its next seal, not at the moment it
     loses.** `claim` bumps the epoch conditionally on the epoch the caller last saw, so
     two devices sending `epoch: 1` produce one winner. Telling the loser would mean
     reaching a laptop that may be asleep; a laptop that is awake is about to seal
     anyway, and that is where it learns. `stale_version` was already the protocol's word
     for it.

389. **A seal's `last_seq` never goes backwards.** A daemon that queues seals across a
     restart sends them in whatever order it kept them, and a retry of an older one is
     not a rewind. `max/2` against the row rather than a refusal, because refusing would
     make a harmless duplicate an error the client has to reason about.

390. **`session.presign` checks the prefix rather than trusting it.** The plane holds an
     object-storage credential for the first time — `DECISIONS.md` 90 said it would not —
     and the narrowness is the whole argument: it signs one method on one key under
     `sessions/<id>/` of a session the caller owns, for five minutes, and has no key for
     the ciphertext. A signer that signs whatever it is handed would be an
     object-storage credential with extra steps, which is the thing 90 was about.

391. **Sixty-four keys a call.** One seal is a segment, a snapshot, a workspace tar and a
     manifest, plus blobs; a request that signs a thousand URLs is a request that hands
     out a thousand, and a bound is cheaper than working out afterwards which ones were
     used.

392. **The presign test uses the URLs.** A signature this suite builds and then compares
     against its own expectation proves that the code agrees with the test. So the test
     PUTs ciphertext through the signed URL, GETs it back, and asserts that a URL signed
     an hour ago with a five-minute lifetime is refused by MinIO with a 403 — which is
     the claim, and only the store can make it.

393. **`origin` keeps meaning what started a session.** The GUI plan writes
     `origin: {"kind": "private", "device": …}`, but `origin.kind` is validated against
     `user`/`trigger`/`a2a` and answers "what started this", which for a private session
     is a person. The device goes in `origin` and in its own column, and the kind goes in
     the new column where the filter and the constraint can both reach it.

## R1 — storage for a caller with no credential

394. **`Troupe.ObjectStore.Signed` is a second store, not a second `Storage`.**
     `Troupe.Sessions.Storage` takes whichever it was handed and never asks which, so one
     `Sealer` serves a pod with a service account and a laptop with none. The alternative
     — a daemon-specific storage layer — would have been a second implementation of the
     layout, and the layout is the thing every rebuild depends on being one.

395. **A presigned PUT cannot carry object metadata, and this is written down rather than
     discovered.** S3 refuses any request with an `x-amz-*` header the signature does not
     cover, and a query-string signature covers `host` alone. `Signed.put/4` therefore
     accepts `:metadata` and drops it. The three facts it would have carried — epoch, last
     sequence, head hash — reach the plane twice over anyway: in the plaintext manifest
     and in every `session.register`, with the epoch and sequences in the segment key
     besides.

396. **Listing is the plane's job, because a listing cannot be signed per-key.** The
     caller does not yet know the keys, and signing the bucket would be handing over the
     bucket. `session.objects` lists under `sessions/<id>/` for a session the caller owns,
     and gives away nothing: a key is a name and an epoch, and the bytes behind it stay
     unreadable to everybody involved.

397. **A caller may narrow that listing and may not widen it.** A prefix that does not
     start with the session's own is ignored rather than refused — the only thing it could
     be asking for is somebody else's, and there is no useful distinction between an
     attempt and a typo.

398. **Deleting is not on the signed store at all.** Erasure has to remove every *version*
     of every object, which is a bucket-level operation, and it is a decision with an
     owner. It stays on `session.erase`, where the plane does it with the credential and
     the audit row that belong to it.

399. **A rebuild no longer invents a profile.** `Index.attrs/4` fell back to
     `default_profile` — "unknown" — for anything storage did not name, which for a
     private session is a value the check constraint refuses, so a rebuild would have
     failed on exactly the sessions it was most needed for. It now reads `kind` from the
     manifest and gives a private session neither profile nor team. Found by the test that
     rebuilds one, which is the only way it would have been found before a customer did.

## R1 — the daemon seals a person's own session

400. **The plane token lives in memory and the label lives on disk.** `identity.json`
     records who this machine's person is, because that is a label the daemon goes on
     applying whether or not it can reach anything. A token is not a label, and a token on
     disk is a token a backup copies. So a restarted daemon has no token until a client
     links again — which costs nothing, because sealing is queued work over a log that is
     already durable locally. The failure mode of the alternative is a stolen file that
     reads a person's whole estate.

401. **`identity.link` carries the token, because the client is the thing that
     authenticated.** The daemon authenticates nobody — its trust boundary is the file
     mode on its socket — so it cannot obtain a plane token and must be handed one. The
     same call that says who the person is says how to speak for them, and a client
     refreshing its token links again.

402. **The key manager exchange is a seam, not a bypass.** `Private.start/2` takes
     `:key_manager`, defaulting to the real assertion exchange. The gateway may not depend
     on `troupe_plane` — a boundary rule, and the reason for it is that a daemon able to
     call the plane's modules would eventually do that instead of using the protocol — so
     a gateway test cannot mint an assertion, because minting one is signing. Making the
     seam explicit is better than a flag that quietly skips a step, and the exchange itself
     is proven in the plane's suite. Joining the two is the cluster suite's job.

403. **The fake plane's signing is real and its rows are not.** `session.presign` signs
     against the same MinIO the daemon then writes to and `session.objects` lists it;
     faking those would leave the test proving that the daemon can talk to a mock.
     `session.register` is an Agent that implements the one behaviour the daemon has to
     cope with, which is the fence.

404. **The manifest names a kind and a team, and a private session's team is `nil`.**
     `Sealer` wrote `team: context.team` straight into plaintext JSON, and a private
     session's owner is `{:person, subject}` — a tuple, which `Jason` refuses. So the first
     private session a daemon ever sealed would have crashed its sealer on the manifest.
     `Context.kind/1` and `Context.team_name/1` answer both, and the kind is what
     `Index.attrs/4` now reads to keep a rebuild from inventing a profile.

405. **The sealers are supervised by the daemon, not by whoever asked.** A session's
     unsealed tail has to outlive the client that created it; a sealer linked to a
     connection would lose exactly the events nobody had written down yet. They sit under
     a DynamicSupervisor with a registry keyed by session id, which also makes shutdown
     free: `Sealer` traps exits and seals in `terminate/2`, so a daemon going away takes
     its last segments with it.

406. **`session.create` answers `syncing`, which is what it is doing and not what was
     asked for.** A laptop that is offline, or one nobody has linked, creates the session
     and says `syncing: false`. Refusing to work without a network is the coupling a
     private session exists to avoid, and a client that asked for private and got local
     needs to be told rather than to assume.

407. **`session.archive` seals before it answers.** The sealer would seal on the way down
     regardless, but a session the daemon has called dormant should be written down by
     then, not shortly afterwards.

## R1 — proving it on a cluster

408. **The e2e suite lives in `troupe_operator` and speaks only `kubectl` and the public
     protocol.** It cannot live in its own app without a boundary rule to describe it, and
     it cannot live in the plane without the operator's cluster tooling. What settles it is
     that the suite *is* a client: it asserts what a cluster administrator would see, and
     asserting it through the `k8s` library the operator itself uses would hide a whole
     class of failure — a wrong RBAC rule, a missing CRD field, an object the operator only
     believes it wrote. A second road to the same API server is the point.

409. **`mix troupe.e2e` refuses any context but `kind-troupe-dev`.** The suite deletes
     pods, removes namespaces and injects faults, and it is one `KUBECONFIG` away from
     doing that somewhere real. Another context takes both `TROUPE_E2E_CONTEXT` and
     `TROUPE_E2E_I_MEAN_IT=1`, because naming a context is not the same as meaning it. The
     check reads the *current* context from `kubectl`, not what the task was told, since
     the current one is what the suite will act on.

410. **It never creates the cluster.** `scripts/remote-up` does. A suite that could bring
     up its own would quietly rebuild the thing it was meant to be testing, and the first
     time the chart was wrong it would say so by taking four minutes longer.

411. **`scripts/e2e` exists because the two halves are in different places on a laptop.**
     `mix` is in the toolbox container and the cluster is containers on Docker's `kind`
     network, so the toolbox is run on that network with kind's *internal* kubeconfig and
     the ingress names pointed at the node. On CI none of that applies — kind, kubectl,
     helm and Elixir are all on the runner — and `mix troupe.e2e` is run directly. The
     script is the laptop's version of the one command, not a second way to run the suite.

412. **The cluster definition moved to `dev/kind/cluster.yaml`.** It was a heredoc inside
     `scripts/kind-up`, which CI could not use, and a CI cluster that differed from a
     developer's would make "it passes on my machine" a statement about the cluster.

413. **Three bugs, all of them fresh-install only, all found by installing fresh.** This
     is what the package is for, so they are worth naming: `scripts/remote-up` wrote a
     temporary file to `/tmp` and handed the path to `kubectl`, which on a Windows host is
     a Windows binary reading a different directory; it pre-created the namespace the chart
     owns, without the metadata Helm needs to adopt a resource, so a first install could
     never succeed; and the plane's migration hook ran before its ServiceAccount, because
     Helm applies every hook before any ordinary resource and the account was not a hook.
     Each of the three is invisible to anybody whose cluster already works.

414. **The migration's ServiceAccount is its own, and that is the whole point of it.**
     Making the *plane's* account a `pre-install` hook fixed the fresh install — Helm
     applies every hook before any ordinary resource, so a Job naming an ordinary account
     was refused — and broke every upgrade, invisibly. Helm deletes and recreates a hook
     resource on each run, which gives it a new UID, and a ServiceAccount's UID is in
     every token the kubelet has already handed to a running pod. The upgraded plane's
     projected token was therefore silently invalidated: its `TokenReview` came back
     `Unauthorized`, it logged nothing, and no worker could enrol. `troupe-plane-migrate`
     is held by nothing that outlives the Job, so recreating it costs nothing.

415. **A `kubectl --token=X` check against a kubeconfig that holds a client certificate
     proves nothing.** It authenticated with the certificate and answered `yes`, which is
     how the first diagnosis of the enrolment failure came out wrong — "the RBAC is right
     and the token works by hand". The token has to be presented with no other credential
     in the request, which is what `kubectl --server --certificate-authority --token`
     does. This is the same rule as everywhere else in this report: a passing response is
     not proof of what you think passed.

## R1 — the cluster suite finds its second and third

416. **`required: true` was declared on forty admin arguments and enforced on none.** A
     missing one arrived at the context as `nil` and became whatever that function did with
     a nil; for `admin.bundles.list` it was an Ecto comparison against nil, which is an
     ArgumentError, which is a 500 on a public endpoint. `AdminAPI.invoke/3` now checks
     before applying, and the test covers *every* method with a required argument rather
     than the one that happened to crash — the defect was never about bundles.

417. **The placement actor recounts before it refuses.** Its in-memory count is the
     authority between reloads, and a reload happens only when it meets a pod it has never
     seen — so a count that drifts upward never comes down, and the profile is full for
     ever while the database says it is empty. The refusal path now reloads and tries
     again: the one moment where being wrong is expensive, and the one moment where a
     group-by costs nothing, because the alternative is a request that fails.

418. **And the drift was mine.** `Placement.release/2` gives a slot back only where it
     finds a `worker_id` to clear, and `strand/2` called `Sessions.dormant/1` first — which
     since the dormancy fix earlier in this branch clears exactly that field. Every pod
     that lost a session to a restart stayed charged for it. The order is now release then
     dormant, and there is a test for the order as well as one for the drift, because the
     structural fix would otherwise hide the local bug from the next person.

419. **The e2e suite owns what it enrols.** The enrolment probe registered a worker whose
     pod does not exist and whose name parses to the same ordinal as the real one. It is
     drained on the way out. A world that leaves litter is a world the next test reads.

420. **A restored session is proven by its chain, not by its head.** The first version of
     the claim asserted the head hash was unchanged across a pod deletion, which is wrong:
     resuming appends `session_resumed`, so the head moves. What continuity means is that
     some event names the old head as its `prev_hash` and that every link holds — read off
     the replacement pod over a real WebSocket, because the plane is not on the path of a
     session's content and a suite that read it from the plane would be proving the wrong
     thing.

421. **A worker's persistent volume was mounted and unused.** The operator mounts the
     claim at `/var/lib/troupe` and never set `TROUPE_STATE_HOME`, so the worker wrote to
     `$HOME/.local/state/troupe` — the container's own ephemeral layer. Nothing was lost,
     because sessions are in object storage and that is what sealing is for; what was lost
     was every restart's worth of re-fetching and re-unpacking, and the volume's size class
     decided nothing at all. The mount and the environment now name one constant, and the
     test asserts they are the *same path* rather than asserting each separately — two
     values that merely both exist is exactly the state this was in.

422. **`session.get` says which bundle a session is pinned to.** The pin is a real promise
     — a session whose agent definitions changed underneath it would be a different session
     halfway through — and until now nothing outside the plane's own database could check
     it. A promise no client can observe is not one anybody can rely on, and it is also a
     claim the cluster suite could not make.

423. **The enrolment claim reads the fleet, not the plane's log.** The log is right about
     what happened and is also thousands of lines of query debug, so "did this happen"
     becomes "is it still in the last four hundred lines" — a question about log volume.
     The fleet listing is the plane's own record of who enrolled, and the pod list is
     Kubernetes' record of what is running; the claim is that they name the same thing,
     which is two roads to one fact rather than one road twice.

424. **An upgrade is proven by the pod's identity, not by the absence of an error.** A
     test that checked only that the session was still `active` afterwards would pass on a
     pod that had been replaced and the session restored — a different promise, and a much
     slower one. Same uid says it is not a replacement wearing the same name; no restarts
     says the process inside did not die; the unchanged epoch says the plane did not bring
     it back.

425. **The development cluster enforced no network policy at all, and had never been
     asked to.** kind's default CNI implements pod networking and ignores every
     NetworkPolicy, so the operator's egress rules were accepted by the API server and
     enforced by nothing: a worker pod on any `scripts/remote-up` cluster could open a
     connection to anything on the internet while `kubectl get networkpolicy` showed a
     tidy list. `dev/kind/cluster.yaml` now disables the default CNI and `remote-up`
     installs Cilium, which is also what the chart's `CiliumNetworkPolicy` is addressed
     to — so the development cluster is the one the product is written for rather than a
     near relative of it.

426. **The egress claim checks that enforcement exists before asserting a refusal, and
     fails rather than skips when it does not.** A test that found the policy object and
     stopped would have passed on every cluster this has ever run on, including the ones
     enforcing nothing. So it dials a host no allowlist mentions and requires that to be
     refused — and it asserts the plane and the object store are still reachable, because
     a policy that refused everything would satisfy the negative and break the product.
     A suite that quietly skipped its only negative claim would be a suite that says
     egress works.

427. **Cilium under Docker Desktop reports enforcement it does not perform.** The
     CiliumNetworkPolicy validates, the endpoint reports `policy-enabled: both` with one
     allowed egress identity, `PolicyAuditMode` is off — and the pod reaches the internet,
     the plane and the object store alike. Everything the agent says is right and nothing
     it does is, which is the exact shape of failure this suite exists to catch and the
     reason the claim is written as a connection rather than as a lookup. On this machine
     the egress claim therefore **fails**, and that is the correct outcome: it is settled
     on CI, whose kernel can carry the datapath. A test that skipped here would be a test
     that reported egress working on a cluster where it does not.

428. **The CNI is a choice with a consequence, and the fallback cannot be mistaken for a
     pass.** `TROUPE_KIND_CNI` defaults to `cilium`, which is what the product is written
     for and what CI uses. `default` exists because some kernels cannot carry Cilium's
     datapath — under Docker Desktop it also fails to implement `hostPort` without
     kube-proxy replacement, which takes the ingress with it, and disrupts long-lived
     pod-to-pod TCP, which takes the control channel. A developer there is better served
     by a cluster honest about enforcing nothing than by one that claims otherwise. The
     egress claim fails on *either* kind of non-enforcing cluster, so the fallback costs a
     red test and never a false green.

429. **`kubeProxyReplacement` is not a preference.** Without it Cilium does not implement
     `hostPort`, and the ingress controller kind installs binds the node's 80 and 443 that
     way — so the cluster becomes unreachable from outside with no error anywhere except a
     connection that is refused. Found by the whole suite failing to sign in.

430. **`TROUPE_SKIP_BUILD=1` skips the build and not the load.** It skipped both, and a
     fresh cluster then has none of the images however recently they were built: the
     failure arrives as a pre-install hook that never starts, "trying and failing to pull
     image", several steps from anything that mentions building.

431. **The `optional` on an MCP credential's `secretKeyRef` is the claim, and it spans
     four hops no unit test sees together**: a bundle names the environment variable it
     wants, the plane projects a `secretRef` onto the profile, the operator writes a
     `secretKeyRef`, and Kubernetes injects it or, being told it is optional, does not.
     Without the optional, a profile naming a credential nobody has configured yet is a
     profile whose pods will not start, so one unconfigured server takes out every session
     on it. Proven from inside the pod, because a spec that *asks* for a variable and a
     process that *has* one are different facts.

432. **And the other half is proven too.** Creating the Secret and restarting fills the
     variable in. Without that, "the variable is absent" would be satisfied by a mechanism
     that never injects anything at all.

433. **A policy violation reached the caller as an unencodable tuple.** `Provision.check/1`
     put `{:sessions_per_pod_above_maximum, 8, 4}` straight into an error's data, and
     `Jason` refuses tuples — so asking for one session too many answered a 500 with an
     HTML body and said nothing about which limit was exceeded. `Policy.describe/1` has
     existed for this the whole time. The test asserts the violations are strings *and*
     that the data encodes, because the second is the property that actually broke.

434. **The e2e world reclaims what earlier runs left.** A suite that leaves two sessions
     on a pod with two slots is a suite whose next run cannot place anything, and the
     failure lands on whichever test happens to be third — a fixture problem wearing a
     product problem's clothes. `ready!` erases what is there through the *admin* method,
     because a session a trigger made belongs to a service principal and the harness
     method asks whether the caller administers that session. Only safe on a cluster the
     suite owns, which is what the context guard is for.

435. **The trigger claim groups runs by idempotency key rather than counting them.** A
     cron trigger firing every minute produces a run per minute, and a run for the *next*
     minute arriving while the assertion is made is correct behaviour that a plain count
     would read as a double fire.

436. **The A2A facade is on in the development cluster.** It is off by default in the
     chart for a good reason — a cluster with nothing calling it has no reason to run one
     — and on here for an equally good one: a facade nobody deploys is a facade nobody
     tests, and its whole design rests on being able to reach the plane and a pod with
     the caller's credential and none of its own.

437. **The facade takes the identity provider's token, not a plane token.** It exchanges
     the caller's credential at the plane on every request and holds nothing between them,
     which is why it needs no privileges. The suite therefore presents what a real caller
     presents, and the first version of the test — which sent a plane token — was refused
     exactly as it should have been.

438. **What the A2A claim does not cover, and why.** An artifact fetched and its hash
     checked needs the facade to attach to the worker pod at the endpoint the plane names,
     which is the pod's *public* hostname. On a real cluster that resolves inside as well
     as outside; on kind it cannot, because `localtest.me` is 127.0.0.1 everywhere and the
     CoreDNS rewrite covers the one name Dex needs rather than a wildcard. Producing an
     artifact to corrupt would need a model besides. The hash check is covered in
     `troupe_a2a`'s own suite, where a mismatch can be injected; what the cluster adds
     here is that `message/send` really does reach a pod and make a session.

## R2 — somebody answerable for a principal

439. **A sponsor is required, and is a person the provider knows in that team.** Not
     merely a string: a principal whose sponsor is a typo has nobody answerable for it and
     nothing would ever notice, because the field is only read when somebody leaves. Four
     refusals rather than one — missing, unknown, deactivated, not in this team — because
     each is a different thing for the person filling the form in.

440. **A principal whose sponsor left is `needs_sponsor`, not `disabled`.** They are
     different questions: one is a field for somebody to fill in, the other is a decision
     somebody made. A list that showed both the same way would send people looking for a
     fault that is not there, so the reason is a column and `state/1` has three answers.

441. **SCIM is where it happens, and the test goes through SCIM.** The requirement is that
     the provider removing somebody is *enough*; a test that called `Principals.sponsor_left/1`
     itself would pass on a plane where nothing ever calls it.

442. **The panel's form gained the field with the package.** R8 says a package's console
     screen lands with the package, and a required field that only an API caller can
     supply is a feature no administrator has. The refusal is shown in the plane's own
     words rather than as `invalid_params`, for the same reason there are four of them.

443. **Existing tests were given a sponsor through one helper rather than forty edits.**
     `DataCase.principal!/3` invents a person in the team's own group where the test does
     not care who sponsors it, and leaves `:sponsor` alone where it does. A test that
     spelled out a sponsor it had no opinion about would be a test about sponsorship.

444. **Both halves are written even when they are the same.** A field omitted where the
     subject and the actor match is a field nobody can read afterwards: absent because
     they were equal, and absent because that day's code did not write it, are not
     distinguishable once the rows are a year old. The migration backfills every existing
     audit row with `on_behalf_of = actor` for the same reason — whatever the actor was, it
     was also the authority, because there was no other kind of row.

445. **`Audit.record/5` takes a `Principal` whole, or either half.** A caller that had to
     take the pair apart and hand the halves over one at a time is a caller that can put
     them back the wrong way round, and nothing downstream could tell.

446. **A principal acts on its sponsor's authority.** A trigger's session records
     `actor: svc:…, subject: <sponsor>` in its origin, which is where a reader six weeks
     later finds the human behind a run that happened at four in the morning. A principal
     with no sponsor cannot exist, so the fallback — a principal standing for itself —
     only ever applies to rows written before sponsors did.

447. **A profile-mode MCP call names `"profile"` as the credential's owner.** It is the
     service account the operator injected, the same for every session; naming a person
     there would be a lie about whose credential went out. The actor half still names the
     session's owner, so the two questions stay separable.

448. **The test for a trigger's pair goes through the real firing path.** The first
     version added a `create_params_for_test/4` to `Triggers` — a seam with no purpose but
     the test, which is the thing this codebase keeps refusing elsewhere. The existing
     firing test already asserts the origin a pod is pushed; the pair is asserted there.

449. **The firing's source is a property of the run, not of the trigger.** A trigger's
     `source` document says what is expected to fire it — a cron expression, a provider.
     How a given firing *arrived* is a different fact: a trigger written for a schedule is
     still run by a person's hand from the console, and that run is `manual`. The
     discriminator therefore lives on `trigger_runs`, which is the row that records one
     firing, and the trigger's document is left alone.

450. **A caller may only name a source its door can vouch for.** `/rpc` accepts `api`,
     `ci` and `integration`, because whether a call is a CI job or a custom integration is
     something only the caller knows and is worth labelling. It refuses `schedule`,
     `manual`, `webhook` and `agent`: those are vouched for by which door the firing came
     through, and an executor that could label its own runs `schedule` would disappear
     into the cron rows. A source anybody can claim is a discriminator that discriminates
     nothing.

451. **`trigger_fired` is written by the pod, from the origin the plane sent.** The plane
     does not reach into a session's log — it cannot; the log is the pod's, hash-chained
     and sealed there. So the plane normalises the block once, into `origin`, and
     `Troupe.Protocol.Origin` holds both halves of that shape so the writer and the reader
     cannot drift apart. It is appended only on creation: a session is fired once however
     many times it is woken, and a second `trigger_fired` would read as a second run — the
     mistake `session_created` made before `session_resumed` existed.

452. **The payload is a digest and never a payload.** A webhook body is content. Content
     belongs in the session's workspace, where the retention policy reaches it, not in a
     durable event that outlives the session and not in a row an administrator lists. The
     digest is taken over the event *as it arrived*, before the 16 KiB cap the run row
     applies — a digest taken after the cap would answer "same firing" for two payloads
     that differed only past the cut.

453. **`revision` and `payload_digest` are optional in the event, and absent means
     absent.** A session started through the A2A facade has no trigger document to name,
     because the caller is an agent that is not ours with its own card; a session created
     before either field existed has neither. Writing a placeholder would give a reader a
     value that looks measured and is not. The facade stays what it is and still produces
     the same event, which is what makes its runs first-class rather than a seventh shape.

454. **`identity` on `tool_call_started` keeps its type; the pair arrives beside it.** The
     previous commit on this branch made `identity` a map, which is a retype — the one
     thing the protocol's compatibility rule forbids within a major version, and worse
     than a removal because a reader expecting a string gets a map and can only crash.
     `identity` is the string it always was, whose credential goes out, and `principal`
     carries both halves. Found by `mix troupe.schema.diff`, which is what it is for.

455. **A trigger's key is a credential for one trigger and nothing else.** Firing from
     outside used to mean holding a person's token or a principal's secret, either of
     which administers the whole team and starts sessions besides; giving that to a CI job
     to call one webhook is giving it the team. `POST /trigger/<id>` accepts the trigger's
     own key, and that key is not a credential anywhere else — not at `/rpc`, not at
     `/mcp`, not for the trigger next to it.

456. **A rotation has no overlap window.** The old key stops working the moment the new
     one is returned. A rotation is usually somebody reacting to a leak, and a window
     would mean the leaked key went on firing for as long as the window lasted. The cost
     is that an administrator must update the caller promptly, which is the right thing to
     be forced to do.

457. **The key is legible exactly once and never stored in the clear.** Salted and hashed
     as a principal's secret is. The listing says `has_key`, when it was minted and by
     whom, and nothing else — a listing that carried the key would put a credential into
     every console, every logged response and every audit row that quoted one.

458. **One answer to "no such trigger" and "wrong key".** Two answers are an oracle: a
     caller holding nothing could walk the id space and learn which triggers a plane has,
     which is a map of what a team automates. There is also no lookup *by* key — the id
     names the row and the key is checked against that row alone.

459. **A webhook with no idempotency key gets the revision and the minute.** An executor
     that retries a failed POST cannot know whether the first arrived, so the plane
     supplies a key that makes the retry safe. The revision is in it so a firing that
     overlaps an edit is a new run: the second POST is asking for something different from
     the first, whatever the clock says. A caller that means two firings sends its own key.

460. **An outbound notification target is absolute, off the loopback and on the egress
     allowlist.** LangGraph shipped a 2026 advisory because a *relative* target was
     resolved against the server's own base URL and reached an in-process route with no
     authentication. So a target with no scheme and no host is not a target; `127.0.0.1`
     and `::1` and `localhost` and `::ffff:127.0.0.1` are the same attack written out; and
     `169.254.169.254` is where cloud credentials live. Other private ranges are *not*
     refused — a plane in a cluster has legitimate internal receivers — and what governs
     those is the egress allowlist, which a platform admin sets and a team admin cannot.

461. **The target is checked at save and again at send, and the second check resolves the
     name.** A check only at save is a check against the value, not against what the value
     does: a host that passed on Tuesday and answers `127.0.0.1` today is a DNS rebind, and
     only a check that asks DNS at send sees it. Redirects are not followed, for the same
     reason — a target answering `302 http://127.0.0.1/` would carry the request somewhere
     neither check ever looked at, which would make both of them decoration.

462. **The notification target is read from the trigger now, not from the run's revision.**
     Every other question about a run is answered by the revision it froze — what it ran,
     as whom, under which terms — because those are facts about the run. Where somebody
     wants to be told is not: an administrator who moved their receiver because the old one
     is gone means the runs in flight too.

463. **The notification is dispatched off the control connection and is not supervised.**
     A pod reporting that a session finished must not wait on somebody else's HTTP server,
     and a notification lost because the node went down is a better outcome than a status
     report that did not land because one was in flight. Every refusal is logged and none
     raises: a run that failed because its announcement could not be sent would be a worse
     record than one that merely was not announced.

464. **`manual` joins `schedule` and `webhook` as a trigger document kind.** A trigger that
     nothing fires automatically — one that exists to be run by a person, by the API or by
     an agent — had to declare itself a webhook, which was a lie about what was expected to
     call it. This is the document's kind and is still not the run's source: a `manual`
     trigger fired by CI is a `ci` run.

465. **A cap is a ceiling at any scope, and the tightest one refuses.** Four rungs —
     deployment, platform, team, person — over the same reservation, walked narrowest
     first so the refusal a caller sees is the one closest to them. A person at their own
     cap inside a team with room to spare is told it is *theirs*, because that is the one
     they can do something about; "budget exhausted" without a scope sends them to a team
     admin who cannot help.

466. **A scope with no cap set does not participate.** Zero and `nil` both mean no
     ceiling, at every rung, exactly as an entitlement's absence does. A person who has
     never been given a budget should not be unable to work, and a rung that read an unset
     cap as zero would stop the whole deployment the day it was added.

467. **The deployment's ceiling and the platform's are one rung.** They are two caps over
     one number — everything this plane has spent and promised — and two actors for two
     caps on one total would be two answers to one question. The stored one applies only
     when it is *tighter*: an operator who could raise it from inside the console could
     raise it past what the people paying for this agreed to. The refusal names which of
     the two bound.

468. **One promise is one row, written by the ladder after every rung agrees.** Each rung
     decides and holds; none of them writes. `TeamBudget` used to write the row inside its
     own grant, which was right when it was the only rung and is wrong now — a row written
     by the first rung is read by the rungs after it as a promise somebody else made, and
     the reservation would be counted against itself.

469. **A rung that refuses unwinds the rungs that had already agreed.** Without it, a
     person who kept failing against their team's ceiling would slowly eat their own, and
     nothing would say so until they could not start anything anywhere. It is the same
     compensating shape `session.create` already uses when a pod declines a session the
     plane had found room for.

470. **`PersonBudget` re-reads the ledger on every decision rather than caching what has
     been spent.** Charges arrive through the *team's* actor, so a per-person total kept
     in this process would drift the first time one landed. One query per session create
     is not a hot path, and this is the lesson the placement actor already taught at a
     cost: a count held in a process and never reloaded is a count that is permanently
     wrong from the first thing it did not see. `TeamBudget` now reloads on reserve too,
     for the same reason.

471. **A person's cap follows them between teams.** One actor per subject, summing across
     the whole ledger. A cap per team per person would be a cap somebody clears by being
     added to a second team, which is not a cap.

472. **A principal's spend counts against its sponsor.** The person answerable for the
     run, not the credential that made it — the subject half of the pair the origin
     already records. A cap that counted only what somebody typed into would be one they
     step around by writing a trigger.

473. **A person's ceiling is Troupe's opinion, not the provider's.** It lives on the
     `users` row but is written through a changeset of its own, never the one SCIM and a
     login use. A cap that could arrive through the provider's door is a cap the next
     nightly sync silently resets.

474. **A session's slice is trimmed against the tightest ceiling, not only the team's.** A
     slice cut to what the team had left and then refused by the person's cap a line later
     would be a refusal the caller could have been spared, and one that said the wrong
     thing about why. Trimming rather than refusing is the existing rule kept: a nightly
     trigger near the end of a period should run on the remainder.

475. **Setting a person's cap is a platform admin's, and it is done from the team page.**
     The authority is platform-level because the cap crosses teams — a team admin who
     could set it could cap somebody in a team they do not administer. The *place* is the
     team page because that is where somebody is standing when they wonder who is near
     theirs, and the flash says "in every team" so nobody mistakes it for a team setting.

476. **A platform default is also a ceiling.** `default_erase_after_days` used to apply
     only to teams enabled after it changed, which made a retention policy something a
     team could lengthen afterwards and nothing would say so. It now narrows every team:
     the ladder's rule made concrete where it matters most, since retention is only
     enforceable in one direction.

477. **Narrower is declared per setting, not inferred.** For a duration or a retention it
     is fewer; for a permission it is `false`. A resolver that guessed from the type would
     be wrong half the time, so `@laddered` names the direction and `tightness/2` is one
     comparison over both — which is also why deny-wins falls out rather than being a
     second resolver.

478. **A team that holds a wider value keeps its row and stops getting it.** The tighter
     rung is what runs; the team's own column is left exactly where the administrator put
     it. Writing the tighter value back would save a lookup and destroy their intent — and
     when the platform widens again they should find their setting, not somebody else's.

479. **Widening is refused, not clamped, and the refusal quotes the ceiling and the rung.**
     A form that accepted ninety over a system running thirty is a system that knew better
     and said nothing. The refusal names which rung set the ceiling, because "you may not"
     and "the deployment says you may not" are different amounts of help.

480. **Anything that acts on a laddered value reads `Ladder.resolve/1`, not the column.**
     `team_role/2` and the team policy a client is handed both go through it, so a platform
     that turns `members_may_control` off turns it off at the next request rather than at
     the next time somebody edits a team.

481. **The console gets the resolved rows from `Admin`, not from the ladder.** A LiveView
     is an admin API client and `mix troupe.boundaries` enforces it. The first version
     called `Ladder.laddered/0` from the page to map a column to a key; the fix was to put
     the column in the row the API already returns, which is the right answer anyway —
     everything a row needs to render should be in the row.

482. **The two managed switches ride in with the terms and are always sent.** The terms
     are already the channel for "configuration this session did not choose", and a second
     one would be a second thing to keep in step. Unlike the terms they are never omitted:
     absent has to mean *off* rather than unspecified, or a plane that stopped sending them
     would leave every session running on whatever it last had.

483. **They are re-read at every activation.** A platform admin who turns one on means it
     for the sessions already running. Those wake often enough that "at the next
     activation" is a promise worth making, where "only new sessions" would leave the
     longest-running ones — the ones that matter most — without it.

484. **`managed_mcp_servers_only` refuses before the challenge is examined.** Asking
     somebody to consent to a thing that will be refused anyway is worse than refusing it.
     Nothing is registered, logged or tainted, and the refusal is a `forbidden` with a
     sentence rather than a transport error — the person asked for their notes tool and
     the answer is something they can act on.

485. **`managed_permission_rules_only` turns `allow_session` into `allow`.** The call in
     front of the person is answered and nothing standing is created, so the next call asks
     again. The *log* records `allow`, not `allow_session`: an event naming a standing
     permission beside a session that has none would be a log disagreeing with itself.

486. **A sibling is `session.spawn`, not `session.create` with an extra argument.** It
     takes its profile, its team and its visibility from another session, and its ceiling
     from that session's *offering* rather than the team's grant. A team's grant is usually
     wider than any one session's, so a sibling that could reach the whole grant would be a
     way for a session to acquire an agent its own offering excluded.

487. **The in-system MCP projection offers four tools and nothing destructive.** Everything
     there is something the caller's own credential could already do at `/rpc`, dispatched
     through the same `Harness` with the same context — the "no client, including ours,
     gets a private door" rule applied to ourselves once more. A test asserts the absence,
     because a sentence in a moduledoc is not a guard.

488. **The door vouches for the source; the caller may not claim it.** `/mcp/session` puts
     `vouched_source: "agent"` in the context, which is how an agent's firing is an `agent`
     firing. A caller at `/rpc` claiming `agent` is refused, for the same reason it may not
     claim `schedule`: a discriminator anybody can set discriminates nothing.

489. **Seven capacity fields leave the admin surface and the plane writes them.**
     `replicas`, `sessionsPerPod`, the four resource numbers and `storage.size` were seven
     guesses an administrator was asked for before they could reach anything they had come
     to configure — and the first of them was a capacity question the plane already had the
     data to answer exactly. They stay in the custom resource, where infrastructure desired
     state belongs and the operator reads nothing else.

490. **A field the plane owns is refused, not ignored.** `admin.profile.put` answers
     `invalid_params` naming the fields that are not the caller's. Silently dropping a
     number somebody typed is how a person comes to believe a limit is in force when it is
     not, which is the exact category of mistake the seven fields were already causing.

491. **Two size classes, and they are about resources.** Session-to-session file separation
     is already built and tested — the mount table, bubblewrap, stage 2's done item 15 — so
     an isolated class would buy kernel separation nobody needs at a cold start per session
     and a pod count that tracks concurrency. `sessionsPerPod: 1` stays in the custom
     resource for anyone who ever does need it. The console says what the classes are for
     in those words, so nobody reaches for Heavy hoping it makes their data safer.

492. **Both classes sit under the policy this release ships.** Sixteen sessions a pod, four
     CPUs, eight gibibytes. A deployment that has never written a `TroupePolicy` gets both
     classes; one that has written a tighter policy has its class refused at admission,
     which is where a maximum belongs since the plane cannot write that document.

493. **The class is backfilled from what each profile was already doing.** A profile packing
     several sessions onto a worker was standard whatever its resources said; one running
     them nearly alone was heavy. An administrator who set this up by hand should not find
     their careful `sessionsPerPod: 1` turned into four by a migration.

494. **The ceiling is in sessions, not workers.** It is the number an administrator can
     reason about and the number a refusal can quote. Converted to replicas in one place,
     so the two cannot drift.

495. **A full-but-growing profile makes a caller wait; only a human ceiling refuses.** The
     plane can see it needs another worker and is already asking for one, so refusing in
     that moment is the platform sending somebody to find an administrator about a number
     that is about to change by itself. `at_capacity, ask your administrator to add
     replicas` is not something anybody can act on; *this profile allows ten at once and
     ten are running* is.

496. **A waiting session gets no endpoint and no token.** There is nothing to connect to,
     and inventing an address would be worse than saying so. `token.mint` answers the same
     shape rather than an error, so a client asking again has nothing to special-case — and
     gets a token the moment there is somewhere to use one.

497. **The plane holds the prompt while a session waits.** It is the only piece of session
     content the plane ever holds, it is held for seconds, and it is cleared the moment the
     session is placed. The alternative is a session that starts and then sits there, which
     is what dropping it would produce for exactly the unattended runs that cannot ask
     again.

498. **Budget is reserved before capacity now, not after.** A pending session has to hold
     its money or it could be admitted later into a team that has none. This changed what
     some refusals say: a team with a pound creating a five-pound session used to be told
     `capacity`, because placement ran first and there were no pods — the right refusal for
     the wrong reason.

499. **Scale-to-zero waits two minutes, and the clock lives on the row.** A profile whose
     last session went dormant ninety seconds ago is very often one somebody is about to
     wake. On the row rather than in the process, so a failover does not reset the grace
     period and keep a worker up for ever.

500. **The size class owns the storage size; the cluster owns the storage class.** The
     first version replaced the whole `storage` object from the class, which silently
     dropped `storageClassName` — and on a cluster whose default is block storage that is
     precisely how granting a team access to a profile takes the profile down. Merged, not
     replaced, and a test asserts both survive.

501. **Activation is about the session, not about the pod.** Written into `PROTOCOL.md`
     outright because the looser reading forbids something harmless. "Subscribing to a
     dormant session never activates it" means no actor tree and no model call. A
     `Session.Reader` is neither, so reading a dormant session on a profile that has scaled
     to zero may start a *worker* — and must, or the history would be unreadable — while
     reserving no capacity and writing no `session_activated`.

502. **A profile with no row on the plane is `unavailable`, not `not_found`.** It exists as
     far as the team's grant is concerned; what is missing is the plane's record of it,
     which is a component problem. `capacity` would send somebody looking for pods that
     were never there.

503. **A worker whose control connection has gone stops being placeable at once.** The
     sweeper already did this after the heartbeat lease expired, which was enough when a
     pod only went away because somebody drained one. It is not enough now that the plane
     scales profiles itself: a worker removed by a scale-down stayed placeable for the rest
     of its lease, so the next create was placed on a pod that was not there and failed
     with "the pod did not accept the session". The plane learns from the socket closing,
     which is a great deal sooner than a lease.

504. **A push that fails for a session that has been *waiting* requeues it; one that fails
     for a session being *created* deletes it.** The create path's rule — a session that
     never started is not a session — is right for a create and wrong for an admit: its
     owner has already been told the session exists, and deleting it out from under them
     while they wait is worse than making them wait longer. The cluster suite found this
     and no unit test could have, because in-process there is no gap between a pod
     enrolling and a pod being able to answer.

505. **The ceiling is checked before placement, not only when placement fails.** The first
     version asked only on the refusal path, so a ceiling of one session on a class that
     fits four never bound until four were running. A ceiling that applies only when the
     pods are full is not a ceiling; it is a second opinion about what placement already
     knows. Found on the cluster, where a real worker had four slots — the unit suite had
     been using pods with a capacity of one, which hid it exactly.

506. **A profile the plane has no row for still creates sessions.** A pod enrols by
     presenting a token, not by being written down, so a profile can be serving sessions
     before any administrator has told the plane about it. What the row decides is the
     ceiling and whether the plane can ask for more workers; no row is no ceiling, and a
     create that refused on its absence would refuse a session the fleet can take. The
     refusal moves to the moment it matters: a full profile the plane cannot scale.

507. **Shrinking waits; growing does not.** With no hysteresis the fleet went
     `1 -> 2 -> 1 -> 2 -> 1` inside a minute as sessions started and went dormant — a pod
     start and a drain each way, and a pod set that moves under everything reading it.
     `idle_since` is really *smaller-since*: set the first tick a profile wants fewer
     workers than it has, cleared the moment it wants as many, and a reduction happens only
     after the grace period. Going to zero is the same rule with nothing special about it.

508. **The e2e suite's shared profile keeps a worker warm.** A test about something else
     should never find the fleet gone underneath it. The test that is *about* the fleet
     going owns a profile nobody else uses and says so — and has to put the secrets in its
     namespace itself, because Troupe creates no secrets and a profile created through the
     console arrives with an empty namespace.

509. **`System.unique_integer/1` is not unique across runs.** It counts from zero in each
     VM, so a second run of the cluster suite invented the same names as the first. Fine
     for a profile, whose teardown removes it; not fine for a service principal, whose
     teardown *disables* it and leaves the row — the second run then collided on the
     subject's unique index inside a setup block, which reads like a product refusal and is
     a fixture counting from zero.

510. **A sponsor is a subject, not a username.** The suite signs in to Dex as
     `ada@example.test` and the plane knows that person as `CgNhZGESBWxvY2Fs`. Everything
     the plane matches a person by matches the subject, so the suite asks `me` rather than
     assuming the two are the same string.

511. **A pod past its lease has its sessions marked dormant, not only its placement
     stopped.** The sweeper's own docstring said its sessions become "candidates for
     activation elsewhere" and nothing made that true: they stayed `active` pointing at a
     worker that was gone, and opening one took the already-running branch and answered
     `not_found` to every retry for ever. It looked handled because a pod that comes *back*
     reconciles what it holds on re-enrolment — and until the plane scaled profiles itself,
     a pod nearly always came back.

512. **`Fleet.sweep/0` and `Fleet.lost/0` are two questions.** Marking a pod unhealthy
     stops placement; rescuing what it was holding is about sessions. A pod with nothing on
     it needs nothing done, and a pod marked unhealthy an hour ago still holds whatever it
     held — so health is not in the second question at all.

513. **Stranding lives in one place.** The order is load-bearing — `Placement.release/2`
     gives a slot back only when it finds a `worker_id`, and `Sessions.dormant/1` clears it
     — and it had been fixed once in the control connection while `Drain` still had it the
     wrong way round. `Drain.strand/1` is the one copy.

514. **A rung with no ceiling is skipped, not consulted.** Fifty concurrent creates timed
     out: the ladder put three `:global` actors on every create, and the platform one is a
     single actor for the whole deployment summing the entire ledger to answer a question
     nobody had asked it. Absence means everything was already the rule; this makes a rung
     with no opinion cost nothing to ask. The team's rung is always consulted — it is the
     ceiling people actually set, and its actor is per team rather than per deployment.

515. **A team is keyed by its name, not by its group.** `enable_team/2` looked the team up
     by `group_id`, so enabling one group under a second name silently *renamed* the first
     team instead of making another. One group, one team, for ever was the assumption and
     it was in the lookup as well as in the schema.

516. **`teams.group_id` loses its unique index and keeps the column.** The index was the
     1:1 assumption written into the database. The column records which group a team was
     first enabled from, which is worth keeping and is no longer what membership derives
     from. Dropping a column is not the same operation as not reading one.

517. **The team's *name* stays unique.** It is what a team is addressed by everywhere — a
     grant, a session's team, an audit row — so two called `engineering` would be two
     answers to one question.

518. **Unlinking quotes the count before it happens, and says sessions do not move.**
     Somebody unlinking a group is usually right about which group and often wrong about
     how many people are in the team only through it. And a session's team is recorded at
     create and stays: unlinking changes who may open it, not what it belongs to — which
     people assume the other way round, so the dialog says it.

519. **An object store is not a database.** `private_sessions_test` wrote under a fixed
     session id, and what a test writes to MinIO survives the sandbox rolling back — so the
     second run of that file listed two segments and failed about the first run. The id is
     unique per run now, which is the same lesson `System.unique_integer/1` taught in the
     cluster suite in a different costume.

520. **A fork copies its parent's history; it does not point at it.** The brief's literal
     reading is a child whose chain starts at `seq: 0` and folds the parent's chain to the
     fork point and the child's after it, which would leave the child readable only through
     the parent's key and objects. Two rules already in the design refuse that. *A fork is
     a new session for budget, retention, key and erasure* — a child that had to be opened
     with its parent's key does not have one of its own in the sense that matters. And
     **erasing a parent leaves the child readable**: erasure destroys the parent's objects
     and its key, so a reference would break on the one operation that must never take
     something else with it. The brief already says the *workspace* is copied into the
     child's own prefix, and it would be odd for the working tree to be the child's while
     its history was not.

521. **Resealing moves the numbering, not the content.** Each copied event keeps its type,
     data, timestamp, actor and agent path and is given the child's next `seq` with a
     recomputed `prev_hash`. A child whose events kept the parent's numbers would start
     above one and follow nothing, and `troupe ctl verify` has to pass on both chains
     independently. What the original numbering was is not lost: `session_forked` carries
     the parent's id, the seq forked at and the parent's head hash there.

522. **A fork is of the durable log, so the point is the parent's last seal.** The copy
     reads segments from object storage, and a turn still in a running pod's memory is not
     in one. Asking the parent to seal first would be writing to a session that is supposed
     to be untouched and unaware. So an unspecified fork point resolves to the row's
     `last_seq`, a point beyond it is refused with the number we do have, and a parent that
     has sealed nothing cannot be forked yet.

523. **The fork point is resolved at the plane and written to the row.** "The head" stops
     being true the moment the parent says another word, so a lineage left as *the head*
     for the pod to work out on arrival would be a lineage nobody could check afterwards.

524. **Forking needs `control` of the parent, not `observe`.** Somebody who may watch a
     session can already read every word of it — but a fork makes a copy they own, under a
     key of their own, that outlives the original's erasure. That is a republication, and
     the person who can authorise it is somebody who could have written the session.

525. **The entitlement set a fork runs under is the intersection, not the inheritance.**
     The brief says a fork inherits what the parent's `session_created` recorded rather
     than what the bundle offers today, and the reason given is that a fork must not be a
     way to reach an agent the team was later denied. Taking the parent's set outright says
     that and loses the converse: a team narrowed *since* the parent ran would have the
     narrowing undone by somebody forking an old session. Deny wins, as everywhere else.

526. **The pod does the copying, and only the pod can.** It is the one place both keys are
     ever in memory. The plane names a session and a number; it never sees an event.

527. **The fork instruction rides on `session.activate` rather than a push of its own.**
     The copy has to land before the tree starts — a manager restoring an empty log writes
     a fresh `session_created` at seq 1, and the copied chain would then be a second history
     arriving after the first. One push also gives the whole thing one idempotency story:
     the plane retries activation without knowing whether the first attempt landed, and the
     pod decides by looking for segments the child already has.

528. **`fork` is stripped from client parameters at the door.** It is how `session.fork`
     tells `session.create` what the child came from. A client that could set it could
     claim a lineage it has no access to, which is a create that walks off with somebody
     else's history.

529. **An import is the client's copy to make, not the plane's.** `reason: "import"` is how
     a private session becomes a team session, and a private session's key lives under a
     path no pod role covers — so no pod can read the parent, whatever the plane asks it to
     do. The plane's half is the same either way: the row, the lineage, the budget and the
     placement. The copy belongs to the device that holds the key, and the activation
     carries no fork instruction. An import also says which profile it lands on, because a
     private session has none to inherit.

530. **A share is a capability, not an ACL entry.** The ACL answers *who is allowed here*,
     by subject, and it is the right answer whenever the person has an account and you know
     which one. A share answers what people actually ask for — *send them this* — and
     folding one into the other breaks both: an ACL entry for somebody who has never signed
     in is a row waiting for a subject that may never arrive, and a capability with no end
     is an ACL entry nobody remembers granting. The three properties an ACL entry does not
     have are the three that justify the table: it expires, it is revocable on its own, and
     it is a secret kept as a salted digest.

531. **Refused at mint, never at use.** Everything about what a link may carry is settled
     when it is made: that the person minting it holds the session, that the role is not
     `admin`, that the team allows it, that the expiry is inside the ceiling. None of it is
     asked again. A link that re-derived its authority from the sharer would stop working
     when they changed teams, and what a recipient could see would depend on something they
     cannot see. Redemption asks only what is true of the share: unexpired, unrevoked, and
     — where it named somebody — presented by them.

532. **Never `admin`, including for the owner.** A capability that could administer a
     session could mint further capabilities, and a link that mints links is a link nobody
     can reason about: not the person who sent it, and not the person auditing it later.
     The rule is in the schema, in the changeset and in a database check constraint.

533. **The other half of "not more than you hold" lives upstream.** `sharer_scope/2` refuses
     a viewer, so the only roles left are the two a share may carry. Restating it in the
     role check made a clause the compiler could prove unreachable — and a second copy of a
     rule is a second place for it to drift.

534. **The team's ACL bounds a share through the ladder, not off the column.** A team whose
     members may not steer cannot have a `control` link minted over its sessions, and a
     platform that has turned steering off has turned it off for every team. Reading the
     column directly would have made a link a way round the setting rather than an exception
     to it.

535. **A share ends by default and cannot be made to last long.** A week unless somebody
     says otherwise, thirty days at the outside. The cap is what stops "share this" quietly
     meaning "for ever", which is the failure mode every link-sharing feature has.

536. **The secret names its own share.** `tsh_<id>.<random>`: an indexed lookup rather than
     a scan of every share in the deployment, with the random half compared against a
     salted digest in constant time. The id is public — it is in `share_created` and in
     every listing — and on its own it opens nothing. The separator is a dot, because
     base64url uses `-` and `_` and a separator that can appear inside an id is a separator
     that splits the wrong id in half.

537. **Revoking is idempotent and keeps the first revocation.** *When* a link stopped
     working is a fact; the second attempt is somebody making sure.

538. **A listing shows revoked and expired links too.** Somebody deciding which link to
     revoke needs to see the ones that already stopped working, or they revoke the wrong
     one.

539. **The pod's part in a share is the durable event and nothing else.** A redeemed share
     arrives as an ordinary session token at an ordinary role, the same as every other way
     in, so there is no share mirror beside the ACL one. And the push is best effort: a
     dormant session has no tree to append to, and making revocation depend on the session
     being awake is the opposite of what somebody revoking a link wants.

540. **Revoking a link stops the next token, not the one in flight.** A session token lasts
     at most fifteen minutes and is checked offline by the pod that holds the session,
     which is true of every route in and not something shares change. Somebody who needs a
     connection closed *now* ends the session.

541. **Presence is a topic of its own, not a kind of event on the session's.** It has no
     `seq`, it is never persisted, and a subscriber who missed some of it has missed
     nothing — three properties the session's stream has none of. Riding `session:<id>` it
     is presence a client cannot decline and a server cannot shed without touching the one
     stream it must not touch. On `presence:<id>`, shedding it is a decision about one
     subscription, which is the difference between a pressure valve and data loss.

542. **`presence:<id>` answers `head_seq: 0` and says `cursored: false`.** Handing back the
     session's head would be handing back a number that means nothing on this topic, and a
     client that treated it as a cursor would be holding a lie.

543. **Following a session is per process and per connection, not per subscription.**
     Registering the connection on the fan-out once per subscription put it there twice —
     so every event arrived twice and every subscription wrote it twice — and because
     `Registry.unregister/2` removes all of a process's entries for a key, dropping one
     subscription would have taken the other's delivery with it. A latent bug for two
     subscriptions on one session at different levels; the presence topic made it routine.
     `Troupe.Events.subscribe/1` is idempotent and the connection unregisters only when
     nothing else still wants the session.

544. **"Presence stops entirely" is a claim about a wedged socket, not a slow one.** The
     first version of the test asserted no presence at all and failed: a client that has
     merely fallen behind recovers between writes, and a flush that frees bytes lets the
     next frame through — which is the design working. The test now fills the kernel
     buffers until the connection has dropped hundreds, and asserts from that point on.

545. **`mix credo --strict` on this checkout is not the check CI runs, so there is a script
     for the one that is.** Git checks these files out with CRLF while the repository stores
     LF, so locally every file trips the line-ending consistency check — ninety-odd findings
     true of nobody else's copy — and checks that look for `


` find nothing in a file
     whose blank lines are `





`. That is not noise around a real result; it
     *hides* one. Twice now a "no more than 1 consecutive blank lines" finding has been
     invisible locally and failed CI, both times on a section header a patch script inserted.
     `scripts/credo` writes the index to a tree object, unpacks that — the same bytes CI
     clones — and runs credo there.

546. **A test name that becomes an object key is unique between runs, not only within
     one.** `System.unique_integer/1` restarts in the next VM, so ten consecutive runs of
     the same file pick the same names ten times — and an object store is not a database,
     so nothing rolls back and the second run lists what the first one wrote. The plane's
     `private_sessions_test` was fixed for this once (519); the gateway's `private_test`
     had its own copy of the same helper and failed CI the same way, asserting a session
     had exactly one segment when it had one of its own and one from an earlier run. The
     witness was the store itself: thirty-eight leftover `p-<n>` prefixes, `p-13` and
     `p-10246` among them, both of which have failed a test by name.

     `Troupe.ObjectStoreCase.unique/1` is the one copy now — wall clock for between runs,
     counter for within one — and the gateway's local helper says the same thing.

547. **The working tree is LF, because every tool that reads this repository runs on
     Linux.** A Windows checkout with CRLF is not a local variant of the same tree; it is a
     different input, and it was wrong in three places at once. `mix credo --strict`
     reported a consistency finding for every file and could not see a real one — twice.
     `mix troupe.admin.assets --check` said the console's bundle did not match its
     dependencies, which was the line endings and not the dependencies. And a test that
     writes a shell script from a string literal wrote CRLF into it, which `dash` answers
     with "Bad fd number" and refuses to parse — so the script never ran and the failure
     showed up as a daemon that did not start.

     `* text=auto eol=lf` in `.gitattributes`. The index has always been LF, so nothing
     committed changed; what changed is what lands in a working tree. After it, plain
     `mix credo --strict` agrees with CI and the assets check passes.

548. **A disconnect may only mark the enrolment it is about.** `Fleet.disconnected/2`
     marked a worker unhealthy whenever its socket closed, which is right for a pod that
     has gone and wrong for a pod whose *plane replica* has gone. The pod reconnects to the
     survivor and enrols there; the dead replica's teardown then arrives and marks the row
     unhealthy again, and nothing recovers it until the next heartbeat. In between, every
     create is refused with `no_healthy_worker` — a failover that looks exactly like an
     outage, and the reason `FailoverTest` failed on the second of CI's ten runs.

     The fence is `enrolled_at`: a teardown updates the row only if it has not been
     enrolled since. Removing the fence fails exactly one test, which is the one that
     describes the race.

549. **`scripts/ci` runs what CI runs, including running the suite more than once.** "It
     passes locally" was wrong four times in a row and each was worth a push and ten
     minutes: a credo finding the local checkout could not see, a stale generated asset, a
     session id that collided with an earlier run's objects, and a race that shows up
     roughly one run in ten. Only the last of those is chance; the rest were a local
     command that was not the one CI runs.

     `dev/known-local-failures` names the tests that fail in the toolbox container and pass
     on CI. They are reported and do not fail the run, anything else does, and a name that
     starts passing is printed as a line to delete — so the list cannot quietly become a
     place to put inconvenient tests.

550. **What makes a worker exist goes behind an interface; nothing above the seam learns
     there is more than one.** `ensure`, `drain` and `describe`, with the Kubernetes
     implementation being the operator exactly as it stands. Doing the extraction first and
     changing no behaviour is the point: a second substrate is only cheap if the first one
     *is* the interface rather than a special case beside it. Placement, the control
     channel, the seal format, the key paths and the session log are untouched.

551. **A profile names its provisioner in a column; what that provisioner guarantees is
     never in one.** `provisioner` is an administrator's answer and belongs on the row.
     Enforcement is a property of the substrate, and a row that recorded its own would be a
     claim nobody checked, in the one place being wrong matters most. `guarantees/1` is
     asked of the module every time.

552. **The missing guarantees are listed one at a time, not summed into a flag.** Done item
     3 is that the console says *which* guarantee is missing, and "unenforced" is not a
     useful thing to tell somebody deciding whether their team's work may run there. Four
     names: admission policy, NetworkPolicy, FQDN egress, disruption budget.

553. **A host proves itself with a secret, and it is refused exactly as a pod is.** A
     machine has no namespace, so the equivalent is a secret issued to that host for that
     profile, kept as a salted digest — the same shape a trigger key and a session share
     have. The claim is as strong as the pod's and no stronger: possession of a secret
     proves possession of a secret, and the profile comes from the row it opens rather than
     from anything the worker says.

     Every way it can fail is `{:error, :unauthenticated}` with nothing saying which check
     refused: an unknown secret, a disabled host, a host claiming a name that is not its
     own, and a pod from the wrong namespace are one answer, because the difference between
     them is what an attacker would like to learn.

554. **A host's workers are recorded under `ssh:<profile>`, not a Kubernetes namespace.**
     The worker row is keyed by namespace and pod name. A host sharing `troupe-w-<profile>`
     with a pod of the same profile would be two machines claiming one row.

555. **A host carries its own ordinal, assigned at registration and never reused.** Drain
     takes the highest first and a machine called `build-box` has no trailing integer to
     read one out of; taking the order from a listing would make it change under somebody.

556. **`ensure/2` on a substrate that cannot make machines reports the shortfall rather
     than failing.** A profile wanting four workers where two hosts are registered is not a
     transient condition the next tick fixes — it is somebody who has to go and install the
     worker on two more machines. Failing would retry that every fifteen seconds for ever
     and put the plane's own mistake in the log instead of the operator's task.

557. **Rotating a host's secret keeps the host's id.** The secret carries the id of the row
     it opens, so minting a fresh pair would hand somebody a secret naming a row that does
     not exist — refused, and indistinguishable from a rotation that did not take. Found by
     a test, not by reading.

558. **`set_enabled/2` writes by id rather than through the caller's struct.** A changeset
     built from a stale struct whose `enabled` already reads the new value is an empty
     changeset, and `Repo.update/1` obliges: it writes nothing and answers `{:ok, host}`. A
     call that says it worked and did not. Turning a host back on is exactly when a caller
     holds a stale copy, which is where that shape bites.

559. **Two test suites against one Postgres produce failures that belong to neither.** A
     full plane run reported fourteen failures, nine of them one module, none reproducible:
     the same tree passed at seed 0 and seed 111, and the module passed in isolation and
     beside its neighbours. The run that failed was the one I started while another suite
     was still running against `troupe_plane_test` — the sandbox's ownership is per
     connection, and two runs sharing it is not a thing it defends against.

     Already an operating rule here, and broken anyway because a background job that had
     timed out of the foreground looked finished. It is worth writing down twice: the
     evidence for "this failure is mine" has to include *what else was running*, or an hour
     goes into reading a stack trace that describes nothing.

     The confirmation is better than "it passed the next time". A second run that also
     overlapped another suite failed five tests — in `WebTest`, `BundlesTest` and
     `TriggersTest`, and not one of the module that failed before. Contention fails
     whatever it lands on; a defect fails the same thing twice. Which set of tests failed
     was the witness, not how many.

560. **ACP is selected by the shape of the client's own `initialize`, not by a port or a
     flag.** ACP sends `protocolVersion` and `clientCapabilities`; Troupe sends
     `protocol_version` and `client_info`. The casing is the discriminator, and it is a
     good one because an editor that already speaks ACP announces itself without being
     told anything about Troupe — which is the whole point of adopting somebody else's
     protocol. A client that sends neither is answered as Troupe's own, which is what every
     client was before ACP existed.

561. **There is no ACP authentication, and `authMethods` is empty to say so.** The socket
     authenticated this connection before ACP was mentioned: permissions on Unix, a token
     from the discovery file on TCP and WebSocket. So an ACP client gets exactly the scopes
     that connection was going to get, and an ACP request goes through the same guard and
     the same dispatcher as any other — which is what makes "a protocol is a way in, never
     a second set of permissions" a property rather than an intention. It is asserted: an
     observer over ACP is refused for want of a scope exactly as an observer over Troupe's
     protocol is.

562. **`loadSession` is advertised false rather than implemented.** Replaying a whole
     conversation as notifications is what `subscribe` with `from_seq` already does, with a
     cursor and no loss. Claiming the ACP capability would promise an editor something
     weaker than the thing it is sitting on.

563. **An event ACP has no rendering for is sent nothing, and the cursor still advances.**
     Troupe's event set is what a session *is* and includes seal reports, epoch changes and
     budget refusals; ACP's update set is what an editor draws. Inventing an update type
     for the rest would be worse than silence, because the durable log is still the record
     and is still where they are.

564. **ACP's `allow_always` maps to `:allow_session`, which already existed.** Not an allow
     followed by a switch set beside it: the approval flow has that decision, so ACP is
     naming something rather than asking for something. `reject_always` is *not* offered,
     because a standing refusal is not something Troupe can honour — every later call would
     have to be denied without asking and nothing records that, and offering an option then
     not keeping it is worse than not offering it.

565. **An ACP client's prompt contributes its text and not its resource links.** ACP lets a
     client attach paths to a message. A path an editor nominates is not a mount, and the
     mount table is what decides where a session can read — quietly widening it because a
     content block arrived would be the one shortcut that matters.

566. **`session/close` detaches; it does not end the session.** ACP was designed for an
     agent subprocess that dies with the editor. Here the session is on the other side of a
     socket and outlives every client attached to it, which is the property ACP's own
     design does not have and the reason this is worth doing. Proven by killing the client
     mid-turn: `llm_request` and `llm_response` both land afterwards.

567. **A session created over the protocol is nobody's to clean up, and a test that makes
     one must say so.** `Troupe.stop_session/1` on exit. Without it the session stays in
     the VM and the next file's "nothing is running yet" fails about something that
     happened in another file — which it did.

568. **An ACP agent is a bundle entry, which is the whole argument for where it lives.** A
     third-party coding agent run as a subprocess is exactly the sort of thing a team should
     have to be granted — and a bundle entry is already narrowed by a grant. `acp_agent`
     became a fourth entitlement kind and nothing else had to be built: absence means
     everything, an allow row makes it an allowlist, deny wins. Done item 3 came free, which
     is the evidence that the placement was right rather than convenient.

569. **An ACP agent and a Troupe agent share one namespace.** One name is what a model says
     when it delegates, so two entries called `reviewer` would make which one ran depend on
     which list was searched first. Refused at publish.

570. **A bundle entry carries the command and the hash of what it should be.** Without the
     hash the entry says *run whatever is on the path under this name*, which is the one
     thing a content-addressed bundle exists not to say. The hash is not verified in the
     protocol module — the worker is the only thing holding the binary — but a malformed one
     is refused at publish rather than at every start, where the reason would be in a log
     nobody is reading.

571. **The subprocess is started without a shell.** `:spawn_executable` with the bundle's
     own argument list. An argument a bundle carried would otherwise be a place to put a
     pipeline, and the bundle is signed for what it says rather than for what a shell makes
     of it.

572. **An ACP agent's filesystem is `Troupe.Workspace`, not a check that agrees with it.**
     ACP's client side is where the filesystem lives, and an editor implementing it hands an
     agent the real disk because the editor *is* the machine. A worker is not: a session has
     a mount table with names and modes. Serving `fs/*` through `Workspace.resolve/3` means
     the refusal an ACP agent gets is the refusal a tool gets — the same call, so the two
     cannot drift and a mount added later applies without anybody remembering to apply it
     here. That is done item 2, and it is why this belongs in the worker rather than a client.

573. **The terminal is refused, and the handshake says so.** ACP defines one and Troupe has
     one, but a session's shell is approved, budgeted and logged; an unmediated terminal
     handed to a subprocess would be a way round all three. `terminal: false` at the
     handshake rather than an error at the first call, so an agent that can work either way
     picks the way that works — and the refusal names the reason rather than reporting a
     capability that does not exist.

574. **An ACP agent becomes an ordinary subagent definition carrying a command instead of a
     prompt.** The alternative was a second kind of delegate, with its own lookup, its own
     depth check and its own budget rule. Making it a `Definition` with an `acp` field means
     `fetch/2` finds it, the `delegate` tool accepts it, the depth limit applies to it and it
     takes a budget slice — and `spawn_child/4` has exactly one branch, on which child spec
     to start. Everything around that branch is shared, which is the test of whether the
     abstraction was the right one.

575. **The bundle's ACP agents are merged last, after every directory.** A bundle entry is
     the plane's word; a file on the pod's disk must not be able to stand in for one.

576. **An ACP agent that exits mid-task reports `:partial`, not an error.** Whatever it said
     before it died is more use to the parent than an error with nothing in it — the same
     reason a Troupe subagent's partial work comes back as a successful tool result. The
     parent is left waiting on a tool call otherwise, which is the failure that matters.

577. **The fake ACP agent in the tests is an Elixir script given explicit code paths.**
     `elixir` is the one interpreter every machine that runs this suite has; a bare one has
     no dependencies, so the paths are passed as `-pa` arguments. No shell, which is the same
     rule the product follows and for the same reason — a glob left for a shell to expand
     turns the rest of the arguments into something else.

578. **A version is not a build, and the footer needed the second one.** The page carried
     `plane 0.2.0`, which is the number in `mix.exs`: it changes when somebody edits a file,
     not when an image is built, so two deploys a week apart report the same string. The
     question people actually ask is *is the thing I just deployed the thing that is
     running*, and nothing on the page could answer it.

     `Troupe.Plane.Build` reads a commit and a build time from the environment, stamped into
     the image by `scripts/build-images` and declared as build args in the Dockerfile.
     Read at runtime rather than compiled in, because a release is built once and run in
     several places — a value baked at compile time is a value the image cannot be asked
     about afterwards.

579. **It says the version, the short commit and the day, and nothing else.** No branch, no
     dirty marker, no builder's hostname: this renders on a page anybody who can reach the
     plane can read, and the useful half is the half that identifies the artifact. The day
     rather than the clock, because a footer that changed every time somebody looked is a
     footer people stop reading — and *which day* is what answers the question.

     An unstamped build reports `dev` and says it does not know, which is honest: a tree
     somebody is editing has no build identity. An empty environment variable counts as
     unset, because a build arg nobody passed arrives as `""` and an empty commit shown as a
     commit would read as an identity where there is none.

580. **`/.well-known/troupe` and the footer read one function.** A deploy check that
     disagreed with the page would be worse than either on its own.

581. **The console's coverage is asserted against what screens *call*, not against a plan.**
     `AdminParityTest` proves the context, the JSON-RPC surface and the MCP tools agree;
     nothing proved the console did, which is how `admin.profile.put` came to be in the
     TypeScript client and on no screen. `Troupe.Plane.Admin.Console` places every method on
     a screen, and the test reads each screen's own source for `Admin.<function>(`. A map of
     where things *should* be would pass while the button did not exist — which is the exact
     failure it was written to catch.

582. **Debt is named in two lists, and both may only shrink.** The design names fifteen
     screens and eleven exist, so on the day this was written the honest answers were
     neither "placed" nor "API-only with a reason": an `:api_only` reason for a screen that
     is merely unbuilt is a backlog item wearing a reason's clothes, and the test cannot
     tell the difference. So `owed/0` lists a method with nowhere to be and `unbuilt/0`
     lists a screen with nothing of its own yet — and the test fails when an entry becomes
     satisfied, which is what makes them shrink rather than accumulate.

     The reasons that *are* reasons are held to it separately: longer than twenty
     characters, not matching "not built", and at most three of them.

583. **What the coverage test found, on its first run.** Five methods reachable from no
     screen and six screens named by the design and absent. That list is the R8 backlog,
     derived from the code rather than from the document — which is the difference between a
     plan and an inventory.

584. **A team is enabled from the console now, and the name is asked for rather than taken
     from the group.** Turning a provider group into a team was a CLI or API step, which
     made the first team of a new deployment a shell command in the middle of a console
     somebody was otherwise configuring everything from. A group is called `itm-consultants`
     because of how a directory is organised; a team is called `delivery` because of what it
     does — and since one group may be two teams, the name has to be the team's own.

585. **A run shows the revision it ran, and the revisions are fetched when asked for.** Done
     item 5. The run already carried its revision number and hash and the table did not show
     them; `trigger_revisions` carries each revision's whole document, so loading every
     revision of every trigger to render a panel nobody has opened would be the page paying
     for a question it was not asked.

586. **Settings becomes Policy rather than being joined by it.** The document names Policy
     a new screen and describes it as Settings plus the ladder, and building both would
     have put two screens in the console that edit the same platform values — which is the
     drift the coverage test exists to catch, arriving by the front door. So the module is
     `Live.Policy`, the route is `/admin/policy`, and the coverage map loses its
     `policy: Live.Settings` exception rather than gaining a second one.

     `/admin/settings` still routes to it. The address is in the deployment notes and in at
     least one bookmark, and a 404 on the page somebody was told to open is a worse answer
     than the page.

587. **The rung chip lives in the layout, not on Policy.** Rule 1 says every effective value
     names the rung that decided it, on every screen — so the chip is a component beside
     `budget/1` and `metric/1` rather than a private function of one page. Two spellings of
     "who decided this" would eventually disagree, and the one that disagreed would be the
     one somebody read.

     Text, not colour, for the reason the status vocabulary is: provenance is an assertion,
     and the design's rule about assertions readable without colour is not about health.

588. **The effective view is a table of every rung, not an expander.** Five settings are
     laddered, so the whole answer fits: for each, the value in force, the rung that decided
     it, the ceiling a team may not pass, and one column per rung holding what that rung
     said. The winning cell is marked *and* says "in force" in words — a cell that was only
     styled as the winner would put the most consequential thing on the page in a shade.

     The team picker is what makes the three-rung case readable. Two rungs are always
     present; the third is a team, and a team is where a value usually stops being the one
     somebody expected.

589. **`settings_list` answers which settings are laddered.** The console is an admin API
     client and gets no private access to the resolver, so a surface that wanted to put the
     chip on the right fields had no way to find out which those are. One sorted list of
     keys in the answer, rather than a screen that hard-codes five names that live in
     another module.

590. **A widening refusal quotes the ceiling, and the clause goes first.** `refusal/1` on the
     Teams screen already matched the ladder's error — it carries
     `reason: "a lower rung may only narrow"` — so the flash said the rule and nothing else.
     The rule is the half an administrator has already worked out from being refused; the
     number is the half they do not have. Done item 3's second sentence is the flash naming
     the field, what was asked for, the ceiling, and the rung that set it.

591. **Budgets is a screen, and it does not set anything.** The design gives it its own
     place because the question somebody arrives with is never "what is this team's cap"
     but "why was that refused" — and three rungs can refuse. So the screen lists every
     ceiling, the spend against each, and names the one that binds first in words.

     The person-cap form stays on Teams. Somebody wondering who is near their ceiling is
     looking at a team when they wonder it, and a second editor for one value is how two
     screens come to disagree about what it is.

592. **A rung with no ceiling never binds.** `remaining_micros` is `:unlimited` there, and
     the binding rung is the one with the least left among the rungs that have a number at
     all. Absence means everything, in the place it costs the most to get wrong: a person
     with no personal cap must not be reported as the reason their session was refused.

593. **`money/1` reads a zero as "no ceiling", and three screens were rendering a spend
     through it.** Found by looking at the page: `delivery` had spent nothing and the bar
     beside it read `unlimited / 500.00 this period`, and the spend and reserved columns on
     Overview, Teams and Budgets each said `unlimited`.

     A ceiling and a spend are different quantities and only one of them means something by
     being absent. So `figure/1` is the plain number, `money/1` keeps its opinion for
     ceilings, and `amount/1` — whose every caller is a spend or a reservation — renders
     through `figure/1`. The test walks three screens and fails on the word appearing in
     any amount.

594. **`allow_unenforced_workers` is a team's column, not a setting on the ladder.** A
     platform-wide switch would be one value that turned the friction off everywhere, and
     the friction is the feature: somebody has to decide per team, by name, in the audit
     trail, with the list of what is missing in front of them. `false` for every team that
     exists and every team made afterwards, because absence here has to mean the safe
     reading rather than the convenient one.

595. **A team admin is refused the flag rather than having it dropped.** They may set
     everything else about their team; a flag a team could give itself is not a decision
     anybody made about that team. Refusing is what the rest of this module does with a
     value it will not use — a form that accepted it and ignored it would leave somebody
     believing their team may run somewhere it may not.

596. **The permission cannot be taken back while the grant it allowed still stands.** The
     check at grant time exists to make "granted, and not allowed" impossible, and clearing
     the flag afterwards would have produced exactly that state by the back door. The
     refusal names the profiles, because the repair is to revoke them.

597. **`Enum.find_value/2` reads a `false` result as "not found", and the value being
     looked for here is very often `false`.** Clearing the flag was indistinguishable from
     an update that never mentioned it, which left both checks above silently unarmed — the
     test for taking the permission back is what caught it. The lookup wraps its answer in
     a tuple.

598. **What a substrate guarantees is answered by `Admin`, not read out of `Fleet` by a
     screen.** `mix troupe.boundaries` would have failed the build, and the reason it would
     is the reason not to want it: a console with a private path into the plane is a path no
     other client has. So `admin.provisioners.list` exists, and the model reading it over
     MCP gets the same four names the screen shows.

599. **Connections answers whether a slot is filled, and the answer says so.**
     `credentials_readable: false` is in the payload rather than only on the page, because
     a model reading `admin.connections.list` over MCP has to be told the same thing a
     person is: there is nothing here to read. The plane's key manager policy has metadata
     and nothing on the data path, which is the same absence that stops it reading a
     session key.

600. **The session table's column is headed "calls go out as".** Not "owner", which is a
     field, but what the field *means*: a person-mode server reaches out as the session's
     owner, fixed at activation, so two people attached are two actors behind one subject.
     Naming the column after the consequence is the whole reason the panel exists — the
     comfortable design is one name, and one name is what somebody is surprised by later.

601. **Done item 9's refusal is proven by there being no method.** The mechanism is already
     proven against a real OpenBao in `PersonCredentialsTest`: the plane's own credential
     cannot read a slot knowing exactly where it is. The console half is the other end of
     the same claim — the coverage test asserts `Troupe.Plane.Connections` exports exactly
     four functions, so a fifth that could fetch a value fails the build rather than being
     caught by a refusal somebody has to remember to write.

602. **The session list is scoped by team id even for a platform admin.** `for_admin/3`
     ignores the id list when the role is `:platform_admin`, and the teams passed here are
     already the ones this actor may see — so passing the real role would have made a team
     admin's Connections page list every session on the plane.

603. **The audit trail is hash-chained, by the same rule the session log has used since
     W1.** A table of rows is exactly as trustworthy as the database it is in: somebody who
     can write to PostgreSQL can change what a record says happened, and until there was a
     chain nothing would have said so. Each row carries a digest of its own content and the
     digest of the row before it, over canonical JSON and excluding `prev_hash`, so a
     verifier recomputes the chain from stored data alone.

604. **Rows written before the chain are counted as unchained, never rewritten.** Computing
     hashes for them now would produce a trail claiming to be verified back to its first
     row when nothing verified it — the most expensive possible lie for this particular
     table. The chain begins at the first row that has one, the answer says how far back
     that is, and both counts are in it.

605. **Two failures, reported apart.** `:altered` is a row whose content no longer hashes
     to what it claims; `:chain_broken` is a row whose predecessor is not the one that was
     there — something removed or inserted. The repairs differ, and "the trail is wrong" is
     not something anybody can act on.

606. **The chain is serialized on one advisory lock.** A chain is an order, and two writers
     picking the same predecessor would put a fork in it. Audit writes happen at the rate
     an administrator clicks, so one plane-wide lock costs nothing; a fork costs the
     property the chain exists for.

607. **"The chain verifies — 0 rows" was a verification of nothing said as though it were
     one.** Found by looking at the page against a plane whose every audit row predated the
     migration. A trail with nothing chained now says so, and says the chain starts at the
     next change somebody makes.

608. **The integrity check runs on request, and only for a platform admin.** The walk reads
     the whole trail, so a page that ran it on every keystroke in the filter is a page
     nobody opens. And the trail is the whole plane's — a check that answered "somewhere in
     the part you cannot see" would be worse than no check.

609. **The erase dialog asks for a preview before it asks for a decision.** The same shape
     as `team_unlink_preview/3`, for the same reason: the count before the deed. Somebody
     erasing a session is usually right about which session and often wrong about what goes
     with it — and `session_erase_preview` is where the third consequence comes from, which
     no surface could work out for itself.

610. **Forks are named, not counted.** A number would be asking somebody to trust a claim
     about sessions they cannot see from the row they are looking at. The dialog lists the
     ids and says to erase each separately if that is what was meant.

611. **The typed identifier is checked on the server as well as disabled in the page.** The
     dialog's rule and the MCP tool's `confirm` are one rule in two renderings, and a check
     that lived only in the markup is a check a form post walks past. Disabled *and*
     refused: a button that looks pressable and then refuses has already wasted the
     reader's attention.

612. **An erased child is not counted as a survivor.** `children_of/1` leaves them out —
     listing one would have the dialog claiming something is still readable when it is not,
     which is the one direction this count must never be wrong in.

613. **The bundle diff is `Audit.diff/2`, which is the function that writes the audit
     record.** Rule 2's identity, and the reason it is worth stating: the thing you approved
     and the thing in the trail are the same object. A console computing a preview one way
     and an audit record another way has two descriptions of one change, and the one you
     read is not the one that survives.

614. **A deny row losing its target is not a loss.** A team that denies an agent was not
     getting it, so a version that removes the agent takes nothing away — and listing it
     would bury the rows that matter under rows that do not. Only *allow* entitlements
     naming a removed entry make somebody a loser.

615. **`bundle_preview` takes the candidate document, and optionally a version to measure
     against.** One answer serves both questions the screen asks: what this draft would do,
     and what one published version did against another. The default baseline is the
     channel's current version, because that is what a publish is measured against.

616. **A published version that no longer validates is still the baseline, with nothing to
     compare.** It is what is running. The preview then reads as everything being added,
     which is the honest answer — the alternative was refusing to preview against a version
     an older schema wrote, which would make the diff unavailable exactly when a migration
     makes it most worth reading.

617. **Review groups by the trigger and orders by outcome, not by time.** A flat list
     ordered by time is a list where the one run that failed at three in the morning is
     nine screens down, and a trigger that fails every night is one problem rather than
     thirty. Worst first: failed, then waiting on somebody, then the rest.

618. **Reviewed is a state somebody puts a run into, not a filter that hides it.** The page
     leads with what nobody has read, because that is what makes the list shrink; showing
     everything brings the rest back with the name of whoever said it was fine. The mark is
     in the audit trail, because "who said this was fine" is exactly what is asked later.

619. **`runs_list` with no team answers across every team the actor administers.** Review's
     question is not about one team, and asking it one team at a time is how a run that
     failed in the team nobody was looking at goes unread. Naming a team still narrows it.

620. **Integrations is read-only, and that is the decision rather than the shortcut.** The
     allowlist is trustworthy *because* it is generated from what each component declares it
     dials. One edited in two places is one nobody trusts — so the page names where each
     host came from and leaves the editing to the thing that declared it.

621. **A notification target is re-checked on the page rather than trusted.** It passed
     `Notify.validate/1` when it was saved; whether it would pass now is a different
     question, and the answer is what somebody needs told. The rule is stated beside the
     list, where a person would otherwise wonder why their localhost target was refused.

622. **Every screen the design names now exists.** `Console.owed/0` and `Console.unbuilt/0`
     are both empty, which is the first time the two lists have said the console is not
     behind the API — and the tests that hold them to only shrinking are what will say so
     the moment it is again.

623. **The walkthrough found a gap the coverage test could not see.** Triggers could enable,
     disable, run and delete a trigger and not *create* one — and `trigger_put` was placed on
     that screen honestly, because the enable toggle calls it. A placement is a claim that
     somebody can do the thing, and "somebody can change one that already exists" was a
     narrower claim than it looked.

     This is the difference between done item 1 and done item 2. One asks whether every
     method is reachable; the other asks whether the steps join up, and only the second can
     notice that the step between granting a profile and having something fire on its own
     was a shell command.

624. **The walkthrough starts from a plane with nothing in it but one person and their
     group.** That is the one thing a console cannot do for itself: a console with a way to
     create its own administrators is the escalation the whole arrangement refuses. Every
     other step is a form on a screen, and a step that needed a shell fails the test rather
     than being discovered by somebody on their first evening.

625. **`VERSION` is a file, not an attribute.** `mix.exs` is read before any application
     compiles, so it cannot call into one — and a file is also what a release script, a CI
     job and a person can each read without starting Elixir. Seven copies with a convention
     is how a chart at `0.2.0` comes to deploy images built from `0.3.0` with nothing saying
     so, and `Troupe.VersionTest` is what makes the copies agree by failing rather than by
     care.

626. **The release version and the protocol version are different numbers, and a test says
     so.** `Troupe.Protocol.version/0` moves when the wire contract breaks; the release
     version moves when a release is cut. A test that let them be the same string would make
     the next protocol break look like a patch release.

627. **The egress allowlist is generated from declarations, and the chart is checked against
     it.** A hand-written allowlist is a list of what somebody remembered, and what it
     produces is a NetworkPolicy that looks complete and refuses one host at the moment
     somebody first needs it. Three kinds of entry, because the difference is what an
     operator needs: a host in the source, a host named by a setting, and a host only the
     reader's browser fetches.

628. **The check found that the shipped chart refused a provider the code defaults to.**
     `api.openai.com` is a default base URL in `Troupe.LLM.Providers.OpenAI` and
     `troupePolicy.allowedEgress` allowed only Anthropic and GitHub — so a profile switched
     to OpenAI by configuration alone would have been refused by the cluster. Narrowing is
     an operator's decision; shipping a default the shipped code cannot work under is not.

629. **`mix troupe.release.check` reports a step it cannot run rather than passing or
     failing it.** A release check that failed on a laptop is one people learn to pass with
     `--skip`; one that passed silently is a checklist with a progress bar. So every step
     ends as a pass, a failure, or the reason it could not be attempted here — and the exit
     code is decided only by the steps that could.

630. **The GUI's Playwright suite is listed as owed by the other repository.** No task here
     can claim it passed, and leaving it out would make the list of what a tag needs
     incomplete in the one direction that matters.

631. **`Fleet.Hosts` had no caller, so the single-machine page could not be written
     truthfully.** R6 built host registration and nothing reached it: a machine could be
     registered by a function inside the plane and by no person anywhere. R9's requirement
     that the page be *true rather than plausible* is what surfaced it — the page is now
     four methods, a panel on Provisioners, and a worker that accepts the secret from a file
     or the environment.

632. **A machine's secret is a string and a pod's is a file, on purpose.** A projected
     ServiceAccount token rotates in place, which is why it is re-read on every connect; a
     machine's does not rotate on its own. Two shapes rather than one with a special case —
     and the file is documented first because an environment variable is readable in `/proc`
     and in `ps` by anybody on that machine.

633. **A drained pod that stays is a pod nothing can reach, and the plane now knows it.**
     `troupe-w-dev-0` sat Not Ready for five days after an admin pressed *Drain*: the pod's
     readiness probe answers 503 while draining — by design, so its Service drops it — and
     `Troupe.Plane.Drain` deletes nothing, because removing the pod is the operator's business.
     But the operator has no drain logic and `undrain/1` has no caller, so on a one-replica
     profile the drain simply left the pod in place with the flag up. Meanwhile the plane kept
     handing it out: `Placement.reader/2` filtered on `healthy` alone, so every `session.open`
     returned an endpoint the Ingress answered with nginx's 503, and `profiles.list` counted
     the pod as a healthy pod with four free slots. Three changes. The reader skips draining
     pods, like placement always has. `profiles.list` lists a draining pod (a person should
     see it) and counts it for nothing — no capacity, not a healthy pod. And the flag is now
     the pod's own fact on the wire: the worker sends `draining` on `enrol` and `heartbeat`;
     a heartbeat may only raise it (the plane raises it first when it orders a drain, and a
     heartbeat from a moment before must not undo that); enrolment takes it as given, because
     the one honest way the flag comes down is a pod that restarted and is therefore not
     draining. Still owed: something that *removes or restarts* a drained pod nobody scaled
     away, and an `undrain` an admin can press.

634. **Runtime config names its atoms; it does not look them up.** `bin/troupe_plane eval
     '…'` on the live plane died in `Config.Reader` with `binary_to_existing_atom("direct")`:
     the `start` boot runs embedded, every module is loaded before the config provider runs
     and `:direct` exists; `eval` boots `start_clean` interactively, nothing of the
     application is loaded, and the same line raises. So the recipe the admin docs give for
     rebuilding the index, reconciling, rolling back — and the one this session needed, to
     lower a stale `draining` flag — could not run on this image, and the migration Job would
     have met the same wall on its next run. `TROUPE_PROVISIONING_MODE` is now matched
     against the two values `Troupe.Plane.Settings` allows and anything else is a named
     error rather than a crash in the boot script. The rule for `runtime.exs` from here:
     never `to_existing_atom` on a value read from the environment.

635. **A root agent that finished is woken by the next input.** `:done` was terminal:
     input to a finished agent wrote `input_after_done` and nothing happened, which on a
     remote session meant a conversation ended the moment the model chose to call
     `finish` — the person typed and the transcript did not move. The two reasons for
     being done are not alike. Budget exhaustion is a limit the person set, and asking
     again does not raise it, so that case keeps writing `input_after_done`. `finished` is
     the model's own opinion that it was done, and the person's next message is exactly
     the evidence that it was not. So a root agent in `:done` with `done_reason:
     :finished` takes input as a new turn on the same conversation — the `finish` call
     already has its `tool_results` there, so the model owes nothing and the turn is
     well-formed — after writing `agent_woken {from, source}`, which the replay fold and
     `Log.Fold` read to clear `done_reason`; without that, a restart would bring the agent
     back `:done` with a conversation that had moved on. Subagents are not woken: theirs
     is a report to a parent, and the parent is what a person talks to. The worker's
     lifecycle needs nothing new — `agent_state` already carries `done_reason`, and the
     woken agent's first `thinking` clears it on the plane's row.

636. **The daemon is proven to boot from this umbrella before anything is packaged.**
     `scripts/daemon-spike` starts `Troupe.Gateway.Daemon` on `troupe_core`,
     `troupe_gateway` and `troupe_protocol` alone — no plane, no worker link, no object
     store — and drives it with the GUI's `@troupe/client` over the loopback WebSocket:
     `initialize`, `session.create`, `input.send`, and the `llm_response` and
     `agent_done` events back. It is a `mix run` script and a Node script, not a release
     and not a test, and it lives under `scripts/` rather than the suite because what it
     proves — that a client written in another repository against `PROTOCOL.md` reaches a
     daemon built here — is the one thing `daemon_test.exs` cannot, since that test is
     this repository talking to itself. `docs/daemon.md` records what it found; Decision
     319 still holds, and where the daemon's *binary* lives is decided there before a
     release is added anywhere.

637. **A projection must subscribe before it replays, and de-duplicate afterwards.** Only
     the first half was here. `Session.Summary` subscribed and then folded the log, so an
     event already written *and* sitting in the process's mailbox was folded twice — once
     from each — and a session's cost came out at exactly double.

     The sequence is what makes "already seen" answerable: the replay remembers how far it
     got, and a live event at or below that is dropped. An ephemeral event has no sequence,
     is in no log, and so can never be a repeat.

     It is a defect rather than a test artefact. The window is a projection starting while a
     turn is in flight, which is an ordinary restart, and what it corrupts is the number the
     plane bills from.

638. **The doubled cost was CI's oldest flake and was never a flake.** It failed
     intermittently under `--runs 10` from R8 onward and passed every single run, which is
     exactly what a race between two orderings looks like. Made deterministic by doing to a
     fresh projection what the race does — replaying a log that holds a sealed event and
     handing it the same event again — the test fails with `630` against `315`, the same two
     numbers CI reported.

639. **The three harness apps can be built outside this umbrella, and the daemon binary
     is built there.** Decision 319 stands: this repository ships images and a chart and
     no binary, because a five-target Burrito matrix is a pipeline of its own. The
     daemon is `troupe_core + troupe_gateway + troupe_protocol` and nothing else, so
     rather than a fifth release here it is packaged in the `troupe` repository — which
     already holds the cross-repository documents and now holds the installers — from
     these apps pinned as sparse git dependencies. Three things had assumed the umbrella
     root and now do not: each app's `mix.exs` reads `../../VERSION` *or*
     `TROUPE_VERSION`, and so does `Troupe.Version` (still never a plausible default: a
     consumer says which version it pinned or the compile fails); sibling apps are
     declared through `harness/1`, `in_umbrella: true` when the sibling is there and an
     ordinary dependency the consumer overrides when it is not, which
     `mix troupe.boundaries` reads as a declaration; and the reaper's Zig source moved
     from `native/` at the root to `apps/troupe_core/native/`, so a checkout of that app
     alone can build the helper every `shell` call needs. The Dockerfile copies one
     directory fewer. (The two entries above this one were numbered 633 and 634 on a
     branch that did not know 633–636 had been taken; they are 637 and 638.)

640. **A laptop's providers live in the core's `Config`, because the daemon is what pays
     for tokens now.** `Troupe.Config` was a pod's: one provider, one key, one model. A
     person has a `providers:` block naming gateways with their own URL, key, auth scheme
     and renamed models, an opencode installation whose providers Troupe reuses when it
     has no key of its own, and a cached catalog of what each model's window and price
     are. All three came over from the TUI — `Troupe.Config.OpenCode` and `JSONC`,
     `Troupe.LLM.Catalog` and its `Store` — and `Config.target/2` is what turns a
     `<provider>/<model>` id into the URL, key, scheme and wire id one request needs;
     the agent aims every request through it, so a subagent whose definition names a
     gateway model reaches that gateway. `Request` carries `auth` and the adapter, and
     the Anthropic adapter sends a bearer token when asked. The window a model is
     compacted against is the model's — declared, or the catalog's — and
     `context_window` only when nothing says otherwise. A pod sees none of this: no
     `providers:`, no opencode files, no `models.json`, and the same one provider and
     key it always had.

641. **`Protocol.Daemon` has a third answer for what to spawn: `troupe-daemon` on the
     `PATH`.** The refusal to guess stays for the case it was written for — nothing is
     installed — but the daemon now has a name and installers that put it on the `PATH`,
     so a client that finds it there need not be told. `:command` and
     `TROUPE_DAEMON_COMMAND` still win.

642. **A TCP listener publishes the port it was given, not the port it asked for.** On a
     platform without Unix sockets the daemon asks for port 0 and `daemon.json` said
     `0`, which no client can dial. The `Listener` reads the bound port back before it
     publishes, and `tcp_transport_test.exs` is the transport's first test: bound port in
     the file, token admits, no token or the wrong one refused. `PROTOCOL.md` §1 also
     said `%LOCALAPPDATA%\troupe\run\daemon.json` where the code and the Tauri shell
     both read `%LOCALAPPDATA%\troupe\daemon.json`; the document moved to the code, since
     two implementations already agreed.

643. **`ezstd` comes from the it-minds fork, because upstream does not build on Windows.**
     The daemon is released per platform from `troupe` and its Windows job failed at
     `mix deps.compile`: `ezstd` 1.2.4 declares its rebar compile hook for
     `(linux|darwin)` only, so on Windows nothing built and rebar3 stopped at the missing
     `priv/ezstd_nif.so`. The fork (`it-minds/ezstd`, branch `win32-zig`, one commit
     meant for an upstream pull request) adds a `win32` hook that compiles zstd — at the commit upstream already
     pins — and the NIF with `zig cc`/`zig c++` into `priv/ezstd_nif.dll`; Zig is the
     one toolchain the release runners and this repository already carry, so a Windows
     build needs no Visual Studio and no MSYS2. Linux and macOS build exactly as before,
     through the unchanged `Makefile`, and the segment format is untouched: the same
     zstd, the same frames. A git dependency pinned by commit instead of the Hex
     package, until upstream takes the change — the harness's first git dependency,
     which `docker/Dockerfile`'s builder stage can fetch because it already has `git`.

644. **A JSON fake script may route answers per agent, and a workspace may name the
     script.** `Troupe.LLM.Fake.load_script!/1` read a list of steps and nothing else, so
     a scripted session with a subagent could not say which answer belonged to whom —
     the in-VM `:routes` option existed for the core's own tests and had no spelling a
     file could carry. It now returns `steps:` and `routes:` from an object, and
     `Troupe.Session` starts the per-session fake with both. The occasion is the TUI
     becoming a client of the daemon (phase 2): its suite drives sessions through the
     protocol alone, and the daemon rightly refuses to let a client choose a provider
     over the wire (`@client_settable` in `Gateway.Dispatch`), so the deterministic model
     has to be arranged the way a machine arranges anything — `provider: fake` and
     `fake_script:` in the workspace's own `.troupe/config.yaml`, which `Config.load/2`
     already reads. `fake_script_test.exs` proves that path end to end without handing
     the session a fake process.

645. **`agents.list` tells a client which agents a workspace offers.** A client creating a
     session picks a `profile`, and until now had no way to ask the daemon what it could
     pick: the plane has `profiles.list`, the daemon had nothing, and the TUI knew its
     agents because it *was* the harness. It is a client now (phase 2), so the daemon
     answers `agents.list {workspace}` with the primaries `session.create` would resolve
     for that workspace — built-ins, the machine's `agents/`, the project's
     `.troupe/agents/` — with a `source` for each. `observe` scope: reading the menu steers
     nothing.

646. **A branch is a session with a `parent`, and nothing more.** The TUI's harness let one
     session hold many root agents, each a window — `/code fix it` beside `/plan the rest`
     in one transcript. Martin chose the other shape for the daemon (brief, question 7.3,
     answer b): a branch is a session of its own, which the core already handled — the
     second session in a busy workspace gets its own worktree — and the client groups them.
     What the core lacked was any record of the grouping. So `session.create` takes
     `parent`, the daemon refuses an id it does not know, `session_created` carries it,
     the index folds it back from the log for a dormant session, and `session.list`
     filters on it. Nothing about how the session runs changes: no shared log, no window
     ledger, no locks between branches, because their worktrees keep them apart. The one
     thing an agent needs from a branch is what it finished with, so `read_branch` lists
     a session's family — its branches, or its siblings and the session they came from —
     and reads a finished one's prompt, summary and task list off its log, never its
     transcript. It reads only the family: a branch is not a way to open any log on the
     machine by guessing an id. `branches: true` at `initialize` says a server does all of
     this; a worker says false, since a pod has one session and no worktrees.

647. **A worktree ends in a merge or a discard, and a merge that cannot complete leaves no
     trace.** `worktree.remove` was the only exit, and it threw away the branch's work
     unless somebody merged it by hand first. `worktree.merge` does what the TUI's `/merge`
     did: commit whatever the agent left uncommitted (as the harness, `troupe
     <troupe@localhost>`, so a machine where nobody told git who they are still works),
     merge the branch into the checkout it came from with a merge commit — `--no-ff`, so
     the branch stays visible in history as one piece of work — and remove the worktree
     and the branch. When git cannot merge it, the merge is aborted before anything is
     answered: the checkout is exactly as it was, the worktree is exactly as it was, and
     the client gets `conflict` with git's own words, because a half-applied merge is the
     one outcome worse than a refused one. `worktree.discard` removes the tree and deletes
     the branch, uncommitted work included, which is what the word means. Both refuse
     with `conflict` while the session in that worktree is mid-turn; an idle or finished
     agent is not consulted, and its next turn, if any, fails loudly rather than editing
     files nobody will look at. Both are `admin`: they change the user's own checkout.

648. **A workflow is a prompt, and the daemon renders it.** The TUI's harness had
     `Troupe.Workflow`: a named step list from `.troupe/workflows/<name>.json` (or a
     built-in six-step pipeline), rendered around the task into the plan an orchestrating
     `workflow` agent starts from — an agent that cannot write, edit or run, and delegates
     each step to `explore`, `implementer` or `reviewer`. Nothing in that needs a harness
     of its own; it needs the step list to be read where the workspace is and the three
     agents to exist. So the module moves here unchanged in shape, the three definitions
     join the built-ins (`workflow` a primary the daemon offers in `agents.list`, the other
     two subagents `delegate` can name), and `session.create` takes `workflow`: the daemon
     loads the steps from the workspace the client named — not the worktree the session
     may get — renders the plan, and starts the `workflow` profile on it. `workflows.list`
     says which names a workspace has, so a client can complete them. Running a workflow
     is therefore starting a session, which is what makes worktrees, approvals, budgets
     and dormancy apply to it without a line written for the purpose; a client that wants
     the result reviewable asks for `worktree: "always"` and ends it with `worktree.merge`
     or `worktree.discard`. The default steps no longer mention `remember`: the project
     brief is a later row of the plan, and a plan should not name a tool the agent has
     not got.

649. **The project brief is a file the daemon reads into every prompt, and `remember` is
     the one tool that writes unasked.** The TUI's harness kept `.troupe/memory.md` — a
     YAML-fronted markdown brief with `Overview`, `Layout`, `Commands`, `Conventions` and
     dated `Notes` — behind a per-session GenServer, prepended it to every system prompt,
     had a `remember` tool append to it and a `librarian` profile write it, and refreshed
     it when a session started on a stale one. All of that moves here with two changes of
     shape. There is no process: the brief is a file, a daemon has many sessions on one
     repository, and a function over a path serialised by a VM-wide transaction on that
     path (`:global.trans`) is what both want — re-read before merging, replaced by
     rename, so two agents in one daemon cannot lose each other's note and a hand edit
     between two calls survives. And the path is the repository's *main checkout*, found
     through `git rev-parse --git-common-dir`: a branch in a worktree writes the same
     brief as the session it branched from, and its note does not vanish with the
     worktree. `remember` stays `:auto` although it writes, for the reason it always did:
     the only file it can reach is the brief, the model cannot name a path, and a brief
     nobody approves is a brief nobody writes. The brief is read at every prompt, not once
     at start, so a note made in a session reaches the next agent to start in it. What a
     client shows and does about it is on the wire: `memory.get` (status, path, built
     time, section titles, text) and `memory.forget`; the auto-refresh is the client's
     because starting a session is — `memory_auto_refresh` is the config key that asks
     for it, and the client starts a `librarian` session when the brief is `absent` or
     `stale`. Flat config keys, like every other setting: `memory`, `memory_auto_refresh`,
     `memory_max_chars`, `memory_max_age_days`.

650. **What a tool had to cut is kept, and the marker says how to read the rest.** The
     core capped `shell` and `grep` output and threw the rest away: the marker said how
     many bytes were dropped and told the model to narrow the request, which for a test
     run means running the suite again to see line 900 of it. The TUI's harness kept the
     full text under a session-local id and paged it back with `read_output`. That comes
     here on top of what already existed — `Troupe.Session.Blobs`, the content-addressed
     per-session store every oversized event payload goes into — rather than as a second
     store: a cut result's full text becomes a blob, its `sha256:` digest is the id, and
     the marker names the `read_output` call with the line to resume from (after the kept
     head for `grep`, line 1 for `shell`, whose kept part is the tail). The id is a digest
     the store validates, so a path is never built from anything the model typed, and the
     blob lives and dies with the session like the rest of its history. `read_file` is
     not kept: reading again with the next offset returns the same bytes, and a store for
     that would be a copy of the file.

651. **A SCIM endpoint that only accepted whole resources did not work with the provider
     this deployment uses.** Entra sends a change as a `PatchOp`, including the one that
     matters: a deprovision is `active` set false, not a `DELETE`. Both patch bodies
     raised — `Map.fetch!` on a key a patch does not carry — so the plane answered 500,
     the provider retried, and the person stayed able to sign in. The endpoint existed
     and the case it exists for was the case it could not serve.

652. **An unreadable filter is refused, never ignored.** `GET /Users?filter=…` is how a
     provider asks *have I already created this person*, and it acts on the answer. An
     endpoint that dropped a filter it could not parse and replied with everybody would
     have the provider read that as "yes, this one" about a stranger and then patch them.
     400 `invalidFilter` is the safe failure; a 200 is not. The same reasoning one rung
     down: a `remove` on `members` with a bracket expression nobody here can read removes
     nothing, because a path we do not understand is not a licence to empty a group.

653. **An attribute with no column is ignored; a body that is not a patch is refused.**
     The difference is whether the push is *about* something this plane keeps. A refused
     push is retried rather than superseded and would hold up the operations beside it —
     which are the ones carrying access. A body with no operations in it is not a patch
     at all, and saying so costs nothing.

654. **A patch never moves the subject.** It is what a token carries, every record here
     is keyed on it, and a provider that changes it is describing a different person —
     one a create can make. Renaming somebody in place would silently re-point their
     budget, their audit trail and their principals' sponsorship at somebody else.

655. **Which claim is the person is now a setting, because on Entra `sub` is the wrong
     one.** Entra's `sub` is pairwise: a different string for the same person in every
     app registration, and not an attribute SCIM can push, while provisioning sends the
     directory object id. Keyed on `sub`, a plane running both holds the same person
     twice — and *deactivating the row SCIM created leaves the row they actually sign in
     with untouched*, which is this deployment's standing requirement inverted.
     `subject_claim` defaults to `sub` and is `oid` for Entra with SCIM. A token missing
     the configured claim is refused rather than quietly keyed on another, since falling
     back is exactly how the second row gets created.

656. **`DELETE` on a group empties it and keeps it.** A team may draw its members from
     that group and the audit trail names it; dropping the row takes both. Emptying
     removes the access, which is the part that has to happen now, and leaves an
     administrator a team they can see is empty rather than a team that silently changed
     shape.

651. **A question is the other half of an approval, and it travels the same way.** The
     TUI's harness had `ask_user`: the agent hands a decision to a person and its tool
     call waits for the answer, with optional numbered options the client draws as a
     menu. The core had only approvals — a yes or no about a call the agent had already
     decided on — so the tool's wait needed a home. `Troupe.Session.Questions` is
     `Approvals` with text instead of a decision: the tool task blocks in a call that
     never times out on its own (the agent's tool timeout is the one that matters, as for
     an approval), `question_asked` and `question_answered` are durable so a question
     outlives dormancy and a re-run tool finds its answer rather than asking twice, and
     the unattended mode (`approvals: :deny`) answers at once that nobody is there, so the
     model decides or finishes instead of waiting for a person who is not coming. On the
     wire it is one method, `question.answer {session_id, call_id, text}` (`control`,
     activating like `approval.respond`); a client with options sends the chosen labels
     joined by `", "`, and free text is always an answer.

652. **Three read-only tools the audit asked for, in the core's shape.** `glob` (files by
     name, newest first — what `find` was being used for), `git_read` (status, diff,
     log, show, branch, with `ref` and `path` refused when they start with `-`) and
     `web_fetch` (GET, HTML reduced to text, `:ask` because it is egress and a pod's
     policy may deny it) come over from the TUI's harness. Each resolves paths through
     `Troupe.Workspace`, runs processes through the reaper, and caps output through
     `Troupe.Tools.Output` with the full text kept for `read_output` (Decision 650) — so
     they gain the mounts, the sandbox and the kept output the core has without a line
     written for the purpose. The built-in profiles list what suits them: the read-only
     ones get `glob` and `git_read`, the planner and the orchestrator `web_fetch` and
     `ask_user`, `build` and `general` everything as before.

653. **The read tools may reach outside the workspace where the config says, and only
     the read tools.** The TUI's harness had `read_roots`: directories a `read_file`,
     `list_files`, `grep` or `glob` may resolve into although they are outside the
     workspace — a dependency checkout, the main repository a worktree's `deps` symlink
     points at. The audit that asked for it found a quarter of all read-only shell calls
     were the model routing around a refusal with `cd deps/x && sed -n`. It comes here as
     `Troupe.Workspace.resolve_readable/3`: `resolve/3` first, and on `outside_workspace`
     the path's real location — symlinks followed, both sides — checked against each root.
     Writes go through `resolve/3` as before and never widen, which is the whole of the
     safety argument: a read root cannot make a file writable, only visible. It is a
     config key (`read_roots`, a list of directories, expanded), so a pod whose bundle
     never sets it has none, and the mounts a pod has are untouched by it.

654. **A workspace may name its own MCP servers, and a stdio one runs under the reaper
     like everything else.** The core's MCP was a pod's: servers from the bundle, one
     HTTP POST per call, discovered pod-wide. A laptop has no bundle, and the TUI's
     harness let `.troupe/config.yaml` say `mcp: {name: {command, args, env, cd}}` or
     `{url}`. That comes here as `Troupe.Session.MCP`, started with the session: a
     `command` server is a subprocess speaking newline-delimited JSON-RPC on its
     standard streams (`Troupe.MCP.Stdio`) for as long as the session lives, a `url`
     server is the same one-shot client the pod uses, discovered once. Both kinds' tools
     are `mcp.<server>.<tool>` — the core's spelling, not the harness's `mcp__` — and go
     through the same allowlist, permission map and approval gate as a built-in; `ask`
     unless the server's entry says `permission: auto`. The stdio subprocess needed the
     reaper to do something it could not: forward the owner's bytes. So reaper gained a
     mode (`TROUPE_REAPER_STDIO`), Unix only: stdin is pumped into the child through a
     pipe, stdout and stderr are inherited as before, and EOF on the owner's side closes
     the child's stdin — which is how an MCP server is told to exit — with the tree taken
     down after the grace if it has not. On Windows the server runs as a plain port and
     is trusted to honour that same contract, which is written down here rather than
     pretended otherwise. `mcp.status {session_id}` is what a client's `/mcp` page shows.

655. **A limit is announced before it stops the agent, once, and a client can draw the
     gauge.** The core stopped an agent with `budget_exhausted` and said nothing before.
     The TUI's harness computed a headroom — five fractions: turns, input tokens, output
     tokens, wall clock, and the model's context window, which is the provider's ceiling
     rather than ours — and warned at eighty percent of any of them, once per dimension.
     That comes here as `Troupe.Agent.Headroom`, pure, read after every model response:
     a dimension that crosses `budget_warn_at` writes a `budget_warning` with the numbers
     and a sentence (`input tokens 4.9M/6.0M (82%)`), and is not warned about again by
     that agent; `agent_state.budget.headroom` carries all five fractions always, so a
     client draws a gauge without knowing how each limit is counted. The warning is
     durable, not ephemeral, although the numbers are in `agent_state` for whoever asks
     later: the contract lets an ephemeral be dropped under load, and the first client
     built on this lost one exactly there — a warning that may not arrive is not one.
     The agent's replay ignores it, so it moves no fixture. `full_send: true` — the harness's `--full-send` — turns the
     warnings off for a session that wants no nagging, and a client may set it at
     `session.create`. What the harness did next, asking the person at the ceiling
     whether to extend the budget, is not here: a budget is a limit, `budget_exhausted`
     is honest about it, and the person who wants more starts a session with more.

656. **The harness's twelve agents are the core's eleven, and the watcher keeps driving
     the root agent.** The TUI shipped twelve definitions; the core had four. Eight came
     over across phase 3 as the features they needed did — `workflow`, `implementer`,
     `reviewer` with workflows, `librarian` with the brief — and the last three come
     here: `answer` (an `AI?` question, cheap and read-only, six turns), `quick` (an `AI!`
     change, cheap, no task list, never asks), `ask` (a question across this session's
     branches through `read_branch`). Two of the twelve are not agents any more: `code`
     is `build`, and `worktree` was `code` in a worktree, which is a way of creating a
     session (`worktree: "always"`) rather than a profile. Watch mode is where the two
     harnesses differed most and the core's shape stands: the watcher hands an `AI!` or
     `AI?` trigger to the session's own root agent — a question under the read-only plan
     permissions for that turn — instead of starting a cheap branch per trigger, because a
     branch is a session now (7.3 b) and a watcher that creates sessions would be a client.
     `quick` and `answer` exist for the client that wants that — a `session.create` on the
     workspace with the marker's text as the prompt — and for a person who runs them by
     hand; the marker grammar, the debounce, the self-write filter and `watch.set` were
     already here and are unchanged.

657. **Token usage is four disjoint figures — `input_tokens`, `cache_read`, `cache_write`,
     `output_tokens` — the budget charges what was billed, and compaction and the context
     gauge measure the prompt's whole length.** The core's `Usage` had two fields and each
     adapter filled them from a different fact: Anthropic's `input_tokens` excludes what
     its prompt cache served, OpenAI's `prompt_tokens` includes it, so the same
     conversation counted differently depending on who answered, and each was wrong in
     the direction that hurts. On an OpenAI-compatible provider a long conversation
     re-reads its whole prompt every turn and nearly all of it is a cache read billed at a
     tenth, so `max_input_tokens` exhausted roughly ten times early, on work the user was
     barely paying for; on Anthropic a warm 200k conversation reads as a few hundred input
     tokens once the cache hits, so the compaction threshold was measured against a number
     that never grows and compaction never fired. The TUI had fixed both (its Decision 59)
     and phase 2 deleted the fix with the rest of its harness. Each adapter now converts
     at the boundary — OpenAI's `prompt_tokens_details.cached_tokens` comes back out of
     `prompt_tokens`; Anthropic's `cache_read_input_tokens` and
     `cache_creation_input_tokens` are read beside `input_tokens`, and every figure a
     `message_delta` reports replaces the running total — so `input_tokens + cache_read +
     cache_write` is the prompt's length whoever answered. `Budget.charge_usage/2` spends
     `Usage.billed_input/1` (fresh input plus cache writes), and the agent's
     `last_input_tokens`, which `needs_compaction?` and `Headroom`'s `context` read, is
     `Usage.total_input/1`. The `llm_response` event carries all four keys — the TUI's
     translator already reads them, which is what puts its `⟳ from cache` line back — and
     `Usage.from_json/1` folds an event written before this as a prompt nothing was cached
     of, which is what it was. `Troupe.Session.Usage`, the ledger, is unchanged: it still
     reads `input_tokens`, which from here is the uncached figure, because the cost it
     records comes from the gateway and not from the tokens; the cache figures ride in the
     event for the day the ledger wants them.

658. **A model's reasoning is a block of its own — opaque, provider-bound, replayed
     verbatim to the provider that made it and to no other — and a reasoning model gets
     the output cap it asks for.** The core's adapters read `content` and `tool_calls` and
     nothing else, so DeepSeek's `reasoning_content` was dropped on the floor: shown to
     nobody, and — because DeepSeek's thinking mode is all-or-nothing, and once one
     assistant message in the history carried reasoning one that omits it fails the whole
     request with a 400 — the second request of every tool-using conversation was refused.
     Anthropic's thinking blocks, which it signs and demands back on a tool-use turn, were
     not read either. The TUI had learned all of this (its `a844ed0`, `9b122d4`) and phase
     2 deleted it. `Troupe.LLM.Reasoning` is now a fourth content block (`provider`,
     `text`, `signature`, `redacted`), captured off both streams — `reasoning_content` or
     `reasoning` as a sibling of `content`; `thinking`, `signature_delta` and
     `redacted_thinking` as blocks — logged in `llm_response.message` like any block, and
     handed back only by the adapter whose provider produced it: OpenAI as
     `reasoning_content` on the assistant message, Anthropic as `thinking` /
     `redacted_thinking` blocks and only when the request has thinking enabled, since a
     thinking block is illegal otherwise. `Message.text/1` and `tool_uses/1` never see it,
     so a parent's summary and a client's prose do not fill with thinking; a `reasoning`
     block from a provider this build has no adapter for replays as `:unknown` and is
     carried, never sent. Live, it is `llm_delta` `kind: "reasoning"`, which the TUI already
     folds and ACP takes as `agent_thought_chunk`. The cap: a model's `reasoning_effort`
     (from its `models:` entry, through `Config.target/2` onto the request) makes the
     OpenAI adapter send `max_completion_tokens` and `reasoning_effort` in place of
     `max_tokens`, which a reasoning model rejects; a 400 that names the other field is
     answered once by sending the request again with it, so nobody has to configure what
     the provider will say. Anthropic takes a budget rather than a level, so the level
     becomes `thinking.budget_tokens` (`minimal` 1k … `xhigh` 32k, or a number) and
     `max_tokens` is raised to hold it rather than the request failing. Not carried over:
     the TUI let an agent definition set the effort and the definition won; the core's
     `Definition` has no such field, and it stays a per-model setting until a profile
     wants to think harder than its model's default.

659. **A reply is looked at before it is acted on: a cut reply is asked again once, a
     cut tool call is answered rather than run, an empty reply is nudged once, a refusal
     ends the agent as refused, a prompt the provider refused as too long is compacted
     once and sent again, and a model error is a sentence somebody can act on.** The
     agent read `content` and `tool_calls` from a reply and nothing else. `stop_reason:
     :max_tokens` was parsed, logged and read by nothing, so a reply the output cap cut
     in half ended the turn as finished — with half a sentence, or with nothing at all
     when a reasoning model spent its whole allowance thinking; a `tool_use` whose
     arguments were cut mid-JSON reached the tool as `__malformed_arguments__` and was
     run on a fragment; a reply with neither text nor a tool call finished a subagent
     with an empty summary; a refusal was a finish. And every failed request was the same
     opaque `inspect(reason)`, so a blown context window — recoverable — read like a typo
     in a model name, and the only thing a client could do was send more input, which
     rebuilt the same oversized prompt. The TUI had all of this (its `d6b3a0f`) and phase 2
     deleted it. Now `handle_response/2` looks at the reply first. A `:max_tokens` stop
     with no tool call gets one more request with a note that says what happened and
     asks for smaller steps; the second time the agent ends `output_truncated` with what
     there was. A `:max_tokens` stop with tool calls goes on, because every `tool_use`
     owes a `tool_result` or the next request is refused, and a call cut mid-argument is
     answered with an error naming the cause and not run. A reply with no text and no
     tool call gets the same one nudge and then ends `empty_reply`. A `:refusal` stop
     ends the agent `refused`. Each is a durable `truncated` event, and the note is a
     `user_input` from source `harness`, which is what it is and what lets a replay
     rebuild the conversation the model saw; a subagent that ends any of these ways
     hands its parent what there was, labelled partial, as a budget stop already did. On
     the error side `Provider.classify/1` names what a failure was — a context overflow
     by the prose both providers use for it, rejected credentials, an unknown model, a
     rate limit the backoff outlasted — and `describe_error/1` says it in a sentence,
     which is what `llm_error.reason` carries now. Only the overflow changes control
     flow: compact once (the `compacted` event says `reason: context_overflow`) and send
     the turn again, since the failed request added nothing to the conversation; a second
     overflow, or a conversation too short to compact, fails with a line that says what to
     do. A 429 gets more attempts than anything else and waits what `retry-after` said, up
     to two minutes, because a rate limit is a wait and not a failure. The two guards are
     not replayed: a restart forgets them and grants the retry again, which errs towards
     finishing. Not carried over: `/compact` on demand, which is a client command the
     protocol has no method for yet.

660. **A spent budget is a question for the person attached, not a stop: `allow` buys the
     same slice again, `always` lifts it for the agent and its subagents, `deny` ends the
     agent; a budget the plane's terms set is a contract and stops; `full_send` never
     asks; an unattended session answers no itself.** An exhausted budget ended the
     agent `budget_exhausted`, and the only way on was a new session — which is what a
     limit is for on a pod running the plane's terms, and exactly wrong on a laptop where
     the person watching would gladly buy another forty turns to see the branch finish.
     The TUI had the question (its Decisions 62–66: `y` this agent, `a` the session, `n`
     stop) and phase 2 deleted it. The core's version rides on what the harness already
     has rather than on a mechanism of its own: the agent hands a question to
     `Troupe.Session.Questions` — the `ask_user` path — with `call_id` `budget-<n>`,
     `detail` (`turns 40/40 (100%)`) as the text and `allow` / `always` / `deny` as the
     options, so a client that can answer an `ask_user` can answer this and no method was
     added; a task waits on the answer, since the agent must not block; the agent sits in
     a new state, `waiting`, where input queues as it does mid-turn. `allow` adds the
     allowance the agent was first given (`Budget.grant/1`, so grants do not compound) and
     forgets which limits were warned about, because a fresh slice is a fresh warning;
     the question comes back at the end of that slice, a checkpoint each time rather than
     one irreversible yes. `always` sets `budget_overridden`, which a delegation inherits:
     a person who lifted the root's budget did not mean to be asked by each of its
     children. The events are `budget_ask_started` and `budget_ask_answered` (with the
     `grant`), both folded: the grant survives a restart, and a `budget_ask_started`
     without its answer leaves the question owed, asked again under the same id, where
     the questions server hands back an answer given meanwhile rather than asking twice.
     The budget is checked when a model call is about to be made and nowhere else now —
     an agent whose turn ended with the budget spent rests idle and asks when next given
     something to do — except where the budget is a contract: `budget_asks: false`, which
     the worker sets whenever the plane's terms set anything at all, keeps the old stop,
     because a limit somebody wrote into a session's terms is not a suggestion. A subagent
     never asks either: its budget is a slice its parent gave it, and what it found goes
     back to the parent labelled partial, as it already did, for the parent to delegate
     again if it wants more — a subtree waiting on a person while its parent's tool call
     hangs would be the worse shape. `full_send` passes the gate without asking; a session running
     `approvals: deny` gets the questions server's unattended answer, which is no. Not
     carried over: the TUI's `a` lifted every agent in the session; here it is the agent
     and its subtree, because a branch is a session now (7.3 b) and there is no second
     root to lift.
