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
