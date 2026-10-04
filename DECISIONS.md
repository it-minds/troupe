# Decisions

The decisions that still shape this repository, each with the reasoning a reader would
otherwise have to reconstruct. Code and documents cite them by number (`Decision 660`).
A decision that was superseded or reversed, or whose reasoning now lives in the code it
governs, is deleted rather than kept for the record, so the numbers have gaps;
`git log -p -- DECISIONS.md` has every one that was ever written. A new decision goes
at the bottom, numbered one past the highest ever used. Numbers are never reused, so a
citation keeps meaning what it meant.

## Stage 2 — the operator

37. **The operator is built on Bonny 1.5, not on hand-written watch-and-reconcile
    GenServers.** It and `k8s` 2.8 compile and run on Elixir 1.20 / OTP 28, and it
    supplies the parts that are the same in every operator and easy to get subtly wrong:
    a watch that resumes from the right resource version, a periodic resync, leader
    election through a Kubernetes `Lease`.

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

49. **A budget of zero means no limit, not no money.** A team that has not been given a
    budget should be able to work; a team that has one of zero would be a team nobody
    could use, which is what disabling it is for.

50. **Reservations are not spending.** What a session promised and what its model calls
    cost are separate tables. The ledger is unique on the gateway's request id, so a
    worker replaying its reports after an outage is not a second charge — and that
    uniqueness is what makes the nightly reconciliation against the gateway meaningful.

## Stage 2 — keys, storage and erasure

56. **`Troupe.KMS` lives in `troupe_protocol`.** The plane may not depend on
    `troupe_core`, and both the plane and the workers hold this contract — the plane
    destroys keys and the workers create and read them. `troupe_protocol` is the only
    place both can see, and it already holds the other contract the two sides share,
    endpoint discovery.

79. **The plane signs session tokens through OpenBao transit and never holds a key.** A
    compromised plane can mint tokens while it is compromised and forge nothing
    afterwards, and the same credential that allows signing allows nothing under the
    session-key paths. ES256 over P-256, because the public half is a JWK a worker can
    cache and check offline, and because transit will marshal an ECDSA signature in JWS
    form directly — its default is ASN.1 DER, which no JWT verifier accepts.

87. **A session nobody may see is `not_found`, not `forbidden`.** Whether a session
    exists is itself something a person who cannot see it should not learn.

90. **The plane drives erasure but does not perform it.** It holds no credential that can
    read a session key and none for object storage. A pod of the profile has both, so the
    plane asks one and records which pods have complied; a pod that was offline applies
    the erasure on enrol, before serving anything. The component that decides *whether*
    to erase is not the component that can read what it is erasing. (390 revises the
    second sentence: the plane signs object-storage URLs for a person's own sessions, and
    still holds no key for what it signs for. 756 revises the first for a private session,
    which has no pod: the plane destroys its key and, once the owner's daemon has stopped,
    deletes its objects.)

92. **The object store and the session layout live in `troupe_protocol`, not in
    `troupe_worker`.** They are a contract both sides hold, for the same reason the KMS
    behaviour is: an index rebuild reconstructs the plane's index from storage, and the
    plane cannot depend on the worker. What the plane can read there is bounded not by
    where the code lives but by what it has a key for — and it has none.

## Stages 3 and 4 — the platform's surfaces

112. **A collaborator's input is billed to the owner's team budget.** The budget belongs
     to the session and a session has one owner, so `user` and `metadata.troupe_owner` on
     every gateway request name the owner rather than whoever is typing. Recorded here
     because it is a policy choice with a plausible alternative — billing the speaker —
     and the alternative would make a session's cost depend on who happened to answer.

125. **A bundle version is immutable and a session is pinned at creation.** A session
     whose agent definitions changed underneath it would be a different session halfway
     through. The only way a session's configuration ever moves is a deliberate upgrade
     at activation, when the version it was pinned to has been retired — and that lands
     in the log as `config_upgraded`, because the model is entitled to know its tools
     may have changed.

130. **Everything a client does goes through `/rpc`, and everything `/rpc` does goes
     through `Troupe.Plane.Harness`.** That is the "any client, including our own, uses
     nothing but public APIs" rule made structural rather than remembered: there is no
     second path into the plane for the TUI to take.

145. **`Ledger.record/1` treats a repeat as a success, not an error.** A worker
     replaying a queued report after a reconnect has done nothing wrong and must not be
     told it has. `{:duplicate, existing}` hands back the record that stands — the
     *first* one, because what the gateway billed is what the first report said — and
     says which case it was, because a caller keeping a running total needs to know
     whether to add this one.

146. **Reconciliation reports and never repairs.** A job that silently rewrote the ledger
     to match the gateway would destroy the evidence that they disagreed, and which of
     them is right is a question about the incident rather than about the numbers. Drift
     is reported in three directions — missing, extra, mismatched — because "the gateway
     billed something we never recorded" and "we recorded something the gateway never
     billed" are different incidents with different causes.

147. **Reconciling is by gateway request id and nothing else.** It is the only identifier
     both systems share; reconciling by timestamp and amount would make two identical
     calls a second apart indistinguishable.

196. **A latency measurement gives each of its five clients a session of its own.** Five
     clients hammering one session measures how long a queue behind a busy agent takes to
     drain, which is a property of the model's speed rather than of the transport. The
     question is `input.send` to `input.accepted`, and that is the load under which that
     number means something.

## Stage 5 — triggers and their terms

253. **Terms become config overrides at the pod.** `max_turns` is the budget's
     `max_turns`; `wall_clock_seconds` becomes `wall_clock_ms`, which `Budget` already
     exhausts on; `approvals` is `:deny` when it says so and the default otherwise.
     There is no `auto` a trigger can ask for, which is the design's refusal written
     into the parser.

256. **The prompt crosses the control channel once and is stored nowhere on the plane.**
     `session.create`'s `prompt` travels in the `session.activate` push and only on the
     first activation; a later one replays the log, in which it is already the first
     input. It is the one piece of session content the control channel carries, so it is
     bounded at 64 KiB and the row never sees it — the tests assert the string is absent
     from the session struct. The canary test for the channel is about what workers
     *report*; a plane-to-pod push of a first input is deliberate, because the
     alternative — a client attaching only to type the first line — is what makes a
     trigger impossible. 497 is the one other time the plane holds a prompt.

257. **Terms are validated key by key, and `budget_micros` is trimmed rather than
     refused.** An unknown key is `invalid_params`, because the worker applies terms as
     configuration and a misspelt cap is a cap that silently did not apply. A slice
     larger than what the team has left becomes what is left: a nightly trigger near the
     end of a budget period should run on the remainder and be stopped by the ledger,
     not be refused for asking. Nothing left is `budget_exhausted` before a row exists.
     There is no `approvals: "auto"`; a trigger that needs none gets a profile whose
     definition says so, which is an admin's versioned act rather than a flag on a
     schedule.

258. **Budget is reserved again on activation, since it is released on dormancy.**
     Otherwise a woken session would run on no reservation at all. `start_elsewhere`
     reserves the session's own slice — its terms', or the default — after placing and
     before pushing, and a team with nothing left cannot wake a session any more than it
     can create one. Reserving twice for one session is a retry in `TeamBudget`, so a
     session whose slice was never released is unaffected.

262. **A service principal's secret is a salted SHA-256, not argon2id.** The repository
     has no key-derivation dependency and takes none on for this. The secret is 32
     random bytes — 256 bits of entropy — so a fast hash is not the weakness it would be
     for a password somebody chose; the salt is per principal so two hashes never
     compare, and the comparison is `:crypto.hash_equals/2`. A wrong secret, a missing
     subject and a disabled principal are one refusal. A trigger's key, a share, a
     host's secret and the SCIM connector's token are held the same way.

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
     `unmetered`.** A log written before costs were recorded has real tokens and no
     cost. It is still recorded, because the tokens are real; it gets a synthesised id,
     because the ledger's uniqueness is what makes re-folding safe; and the id has a
     shape no gateway would mint, so the nightly job can count it as a cost that was
     never captured rather than as a call billed twice. Unmetered rows are not drift and
     do not make a comparison dirty.

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

301. **No rollup pipeline.** Raw records with `(team_id, occurred_at)` and the cache
     answer everything the panel asks at this volume. What is owed is the retention
     decision and a row count at which to revisit, not a fold-into-buckets job for a
     table with fifty thousand rows in it.

## The remote alone

322. **A release publishes the chart at its own version.** `helm package` runs with
     `--version` and `--app-version` set to the release's version, and the tarball is
     attached to the release — so an install of that file pulls the images the same run
     published, rather than whatever `values.yaml` was last edited to say.

## R1 — people, their credentials and their sessions

375. **`me.connections.grant` answers an assertion, not a token.** A short-lived key
     manager token scoped to the caller's own slot would be a token the plane minted, a
     token the plane minted is a token the plane *held*, and a plane that held one could
     have read the slot. So it answers the assertion instead — a signed statement of who
     the caller is, which the plane is entitled to make because it is the thing that
     authenticated them — and the client exchanges that with the key manager itself.

     The same mechanism a pod uses, which is the argument for it: there is one way to
     become a person at the key manager, and the plane is on neither side of it.

377. **The plane may see that a slot has a version, and nothing more.** Its policy gains
     `list` and `read` on `metadata/troupe/people/+/mcp/*` — KV v2 metadata, which is
     versions and timestamps and never a value. That is exactly what a panel needs in
     order to say "Ada has connected Jira" and the most it should ever be able to say.
     No `delete`: removing a credential uses the same grant as writing one, so an
     administrator can retire a server from the bundle and can neither read nor remove
     somebody's credential.

381. **Signing in never reactivates somebody the provider deactivated.** Otherwise a
     SCIM deprovision would last exactly until its subject next authenticated — and the
     token issued after that is one every other check in the plane then trusts. Only a
     person we have never seen is created active, which is what a deployment with no
     SCIM means by the word and the case the default is for.

382. **The harness checks on every call, not only at sign-in.** A plane token outlives
     the moment it was issued, so a person deactivated at ten o'clock holds a valid one
     until it expires. Checking at the door would leave every method answering them
     until then. It reads the *row*: the provider's decision reaches us through SCIM,
     and nothing re-reads a claim.

383. **`kms.assertion` refuses a deactivated owner, and that is the door that
     mattered.** A running session needs nobody to sign in. Refusing a deprovisioned
     person only at the harness would have left their credentials reachable by any pod
     for as long as anything they had started kept running — indefinitely, since the pod
     refreshes on its own. Refused here, the window is the pod's existing key-manager
     token and its lease, and no longer.

390. **`session.presign` checks the prefix rather than trusting it.** The plane holds an
     object-storage credential — 90 said it would not — and the narrowness is the whole
     argument: it signs one method on one key under `sessions/<id>/` of a session the
     caller owns, for five minutes, and has no key for the ciphertext. A signer that
     signs whatever it is handed would be an object-storage credential with extra steps,
     which is the thing 90 was about.

## R2 — notifications, budgets and capacity

460. **An outbound notification target is absolute, off the loopback and on the egress
     allowlist.** LangGraph shipped a 2026 advisory because a *relative* target was
     resolved against the server's own base URL and reached an in-process route with no
     authentication. So a target with no scheme and no host is not a target; `127.0.0.1`
     and `::1` and `localhost` and `::ffff:127.0.0.1` are the same attack written out;
     and `169.254.169.254` is where cloud credentials live. Other private ranges are
     *not* refused — a plane in a cluster has legitimate internal receivers — and what
     governs those is the egress allowlist, which a platform admin sets and a team admin
     cannot.

461. **The target is checked at save and again at send, and the second check resolves
     the name.** A check only at save is a check against the value, not against what the
     value does: a host that passed on Tuesday and answers `127.0.0.1` today is a DNS
     rebind, and only a check that asks DNS at send sees it. Redirects are not followed,
     for the same reason — a target answering `302 http://127.0.0.1/` would carry the
     request somewhere neither check ever looked at, which would make both of them
     decoration.

465. **A cap is a ceiling at any scope, and the tightest one refuses.** Four rungs —
     deployment, platform, team, person — over the same reservation, walked narrowest
     first so the refusal a caller sees is the one closest to them. A person at their own
     cap inside a team with room to spare is told it is *theirs*, because that is the one
     they can do something about; "budget exhausted" without a scope sends them to a team
     admin who cannot help.

466. **A scope with no cap set does not participate.** Zero and `nil` both mean no
     ceiling, at every rung, exactly as an entitlement's absence does. A person who has
     never been given a budget should not be unable to work, and a rung that read an
     unset cap as zero would stop the whole deployment the day it was added.

467. **The deployment's ceiling and the platform's are one rung.** They are two caps over
     one number — everything this plane has spent and promised — and two actors for two
     caps on one total would be two answers to one question. The stored one applies only
     when it is *tighter*: an operator who could raise it from inside the console could
     raise it past what the people paying for this agreed to. The refusal names which of
     the two bound.

468. **One promise is one row, written by the ladder after every rung agrees.** Each
     rung decides and holds; none of them writes. A row written by the first rung would
     be read by the rungs after it as a promise somebody else made, and the reservation
     would be counted against itself.

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
     wrong from the first thing it did not see. `TeamBudget` reloads on reserve too, for
     the same reason.

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

474. **A session's slice is trimmed against the tightest ceiling, not only the team's.**
     A slice cut to what the team had left and then refused by the person's cap a line
     later would be a refusal the caller could have been spared, and one that said the
     wrong thing about why. Trimming rather than refusing is the existing rule kept: a
     nightly trigger near the end of a period should run on the remainder.

475. **Setting a person's cap is a platform admin's, and it is done from the team page.**
     The authority is platform-level because the cap crosses teams — a team admin who
     could set it could cap somebody in a team they do not administer. The *place* is the
     team page because that is where somebody is standing when they wonder who is near
     theirs, and the flash says "in every team" so nobody mistakes it for a team setting.

684. **A `monthly` budget is the calendar month in UTC, and it turns over because it is
     asked, not because a job runs.** It resets at 00:00 UTC on the 1st, the same instant
     on every replica whatever zone anybody is in; decided for #106 over a zone set on the
     plane and a rolling thirty days. Nothing is written at midnight. The period's start is
     worked out on every read (`Ledger.period_start/1`) and the ledger's cache is keyed by
     it, so the first read of a month is a new sum and not last month's remembered one.
     `never` counts everything. A person's cap and the platform's (with the deployment's)
     are that same month, always, decided for #132 over leaving them all-time: an all-time
     cap refuses somebody for good once they reach it. They do not borrow a team's period,
     because a person's cap follows them between teams (471) and somebody in a `monthly`
     team and a `never` one would get two answers (`Ledger.month_start/0`).

497. **The plane holds the prompt while a session waits.** It is the only piece of
     session content the plane ever holds, it is held for seconds, and it is cleared the
     moment the session is placed. The alternative is a session that starts and then
     sits there, which is what dropping it would produce for exactly the unattended runs
     that cannot ask again.

498. **Budget is reserved before capacity, not after.** A pending session has to hold
     its money or it could be admitted later into a team that has none, and a team
     without the money is told so rather than `capacity`.

514. **A rung with no ceiling is skipped, not consulted.** The platform rung is one
     actor for the whole deployment summing the entire ledger, and consulting it on
     every create when it has no ceiling timed fifty concurrent creates out. Absence
     means everything; this makes a rung with no opinion cost nothing to ask. The team's
     rung is always consulted — it is the ceiling people actually set, and its actor is
     per team rather than per deployment.

591. **Budgets is a screen, and it does not set anything.** It is a place of its own
     because the question somebody arrives with is never "what is this team's cap"
     but "why was that refused" — and three rungs can refuse. So the screen lists every
     ceiling, the spend against each, and names the one that binds first in words.

     The person-cap form stays on Teams. Somebody wondering who is near their ceiling is
     looking at a team when they wonder it, and a second editor for one value is how two
     screens come to disagree about what it is.

592. **A rung with no ceiling never binds.** `remaining_micros` is `:unlimited` there,
     and the binding rung is the one with the least left among the rungs that have a
     number at all. Absence means everything, in the place it costs the most to get
     wrong: a person with no personal cap must not be reported as the reason their
     session was refused.

593. **`money/1` reads a zero as "no ceiling", so a spend is never rendered through
     it.** A ceiling and a spend are different quantities and only one of them means
     something by being absent: a team that had spent nothing read `unlimited / 500.00
     this period`. So `figure/1` is the plain number, `money/1` keeps its opinion for
     ceilings, and `amount/1` — whose every caller is a spend or a reservation — renders
     through `figure/1`. A test walks three screens and fails on `unlimited` in any
     amount.

## The live plane and the daemon's harness

633. **A draining pod is handed out for nothing, and whether it is draining is the pod's
     own fact.** A draining pod's readiness probe answers 503, so its Service drops it,
     and the plane must not send anybody there either: placement and the reader both
     skip a draining pod, and `profiles.list` lists one (a person should see it) and
     counts it for nothing — no capacity, not a healthy pod. The worker sends `draining`
     on `enrol` and `heartbeat`. A heartbeat may only raise the flag, because the plane
     raises it first when it orders a drain and a heartbeat from a moment before must
     not undo that; enrolment takes it as given, because the one honest way the flag
     comes down is a pod that restarted and is therefore not draining. Still owed:
     something that *removes or restarts* a drained pod nobody scaled away, and an
     `undrain` an admin can press.

634. **Runtime config names its atoms; it does not look them up.** `eval` boots
     `start_clean` interactively with nothing of the application loaded, so
     `binary_to_existing_atom/1` on an environment value raises there although the
     embedded `start` boot gets past it — and the admin docs' recipes (rebuilding the
     index, reconciling, rolling back) and the migration Job all run through `eval`. So a
     value such as `TROUPE_PROVISIONING_MODE` is matched against the strings it may be,
     and anything else is a named error rather than a crash in the boot script. Never
     `to_existing_atom` on a value read from the environment.

635. **A root agent that finished is woken by the next input.** The two reasons for
     being done are not alike. Budget exhaustion is a limit the person set, and asking
     again does not raise it, so that case writes `input_after_done` and nothing
     happens. `finished` is the model's own opinion that it was done, and the person's
     next message is exactly the evidence that it was not. So a root agent in `:done`
     with `done_reason: :finished` takes input as a new turn on the same conversation —
     the `finish` call already has its `tool_results` there, so the model owes nothing
     and the turn is well-formed — after writing `agent_woken {from, source}`, which the
     replay fold and `Log.Fold` read to clear `done_reason`; without that, a restart
     would bring the agent back `:done` with a conversation that had moved on. Subagents
     are not woken: theirs is a report to a parent, and the parent is what a person
     talks to. The worker's lifecycle needs nothing new — `agent_state` already carries
     `done_reason`, and the woken agent's first `thinking` clears it on the plane's row.

637. **A projection must subscribe before it replays, and de-duplicate afterwards.**
     Subscribing first and then folding the log folds an event that is already written
     *and* sitting in the mailbox twice, once from each; `Session.Summary` did, and a
     session's cost came out at exactly double. The replay remembers how far it got, and
     a live event at or below that is dropped. An ephemeral event has no sequence, is in
     no log, and so can never be a repeat. The window is a projection starting while a
     turn is in flight, which is an ordinary restart, and what it corrupts is the number
     the plane bills from.

643. **`ezstd` comes from the it-minds fork, because upstream does not build on
     Windows.** `ezstd` 1.2.4 declares its rebar compile hook for `(linux|darwin)` only.
     The fork (`it-minds/ezstd`, branch `win32-zig`, one commit meant for an upstream
     pull request) adds a `win32` hook that compiles zstd — at the commit upstream
     already pins — and the NIF with `zig cc`/`zig c++` into `priv/ezstd_nif.dll`; Zig
     is the one toolchain the release runners and this repository already carry, so a
     Windows build needs no Visual Studio and no MSYS2. Linux and macOS build exactly as
     before, and the segment format is untouched. It is a git dependency pinned by
     commit until upstream takes the change, which `docker/Dockerfile`'s builder stage
     can fetch because it has `git`.

646. **A branch is a session with a `parent`, and nothing more.** Not several root
     agents in one session, each a window, as the TUI's own harness had: Martin chose a
     session of its own for the daemon, which the core already handled — the second
     session in a busy workspace gets its own worktree — and the client groups them. So
     `session.create` takes `parent`, the daemon refuses an id it does not know,
     `session_created` carries it, the index folds it back from the log for a dormant
     session, and `session.list` filters on it. Nothing about how the session runs
     changes: no shared log, no window ledger, no locks between branches, because their
     worktrees keep them apart. The one thing an agent needs from a branch is what it
     finished with, so `read_branch` lists a session's family — its branches, or its
     siblings and the session they came from — and reads a finished one's prompt,
     summary and task list off its log, never its transcript. It reads only the family:
     a branch is not a way to open any log on the machine by guessing an id. `branches:
     true` at `initialize` says a server does all of this; a worker says false, since a
     pod has one session and no worktrees.

647. **A worktree ends in a merge or a discard, and a merge that cannot complete leaves
     no trace.** `worktree.merge` commits whatever the agent left uncommitted (as the
     harness, `troupe <troupe@localhost>`, so a machine where nobody told git who they
     are still works), merges the branch into the checkout it came from with a merge
     commit — `--no-ff`, so the branch stays visible in history as one piece of work —
     and removes the worktree and the branch. When git cannot merge it, the merge is
     aborted before anything is answered: the checkout is exactly as it was, the
     worktree is exactly as it was, and the client gets `conflict` with git's own words,
     because a half-applied merge is the one outcome worse than a refused one.
     `worktree.discard` removes the tree and deletes the branch, uncommitted work
     included, which is what the word means. Both refuse with `conflict` while the
     session in that worktree is mid-turn; an idle or finished agent is not consulted,
     and its next turn, if any, fails loudly rather than editing files nobody will look
     at. Both are `admin`: they change the user's own checkout.

648. **A workflow is a prompt, and the daemon renders it.** `Troupe.Workflow` is a named
     step list from `.troupe/workflows/<name>.json` (or a built-in six-step pipeline),
     rendered around the task into the plan an orchestrating `workflow` agent starts
     from — an agent that cannot write, edit or run, and delegates each step to
     `explore`, `implementer` or `reviewer`. It needs the step list read where the
     workspace is and the three agents to exist, and nothing else: the definitions are
     built-ins (`workflow` a primary the daemon offers in `agents.list`, the other two
     subagents `delegate` can name), and `session.create` takes `workflow`: the daemon
     loads the steps from the workspace the client named — not the worktree the session
     may get — renders the plan, and starts the `workflow` profile on it.
     `workflows.list` says which names a workspace has, so a client can complete them.
     Running a workflow is therefore starting a session, which is what makes worktrees,
     approvals, budgets and dormancy apply to it without a line written for the purpose;
     a client that wants the result reviewable asks for `worktree: "always"` and ends it
     with `worktree.merge` or `worktree.discard`.

649. **The project brief is a file the daemon reads into every prompt, and `remember` is
     the one tool that writes unasked.** `.troupe/memory.md` is a YAML-fronted markdown
     brief with `Overview`, `Layout`, `Commands`, `Conventions` and dated `Notes`,
     prepended to every system prompt; `remember` appends to it and a `librarian`
     profile writes it. There is no process: the brief is a file, a daemon has many
     sessions on one repository, and a function over a path serialised by a VM-wide
     transaction on that path (`:global.trans`) is what both want — re-read before
     merging, replaced by rename, so two agents in one daemon cannot lose each other's
     note and a hand edit between two calls survives. And the path is the repository's
     *main checkout*, found through `git rev-parse --git-common-dir`: a branch in a
     worktree writes the same brief as the session it branched from, and its note does
     not vanish with the worktree. `remember` is `:auto` although it writes, because the
     only file it can reach is the brief, the model cannot name a path, and a brief
     nobody approves is a brief nobody writes. The brief is read at every prompt, not
     once at start, so a note made in a session reaches the next agent to start in it.
     What a client shows and does about it is on the wire: `memory.get` (status, path,
     built time, section titles, text) and `memory.forget`; the auto-refresh is the
     client's because starting a session is — `memory_auto_refresh` is the config key
     that asks for it, and the client starts a `librarian` session when the brief is
     `absent` or `stale`. Flat config keys, like every other setting: `memory`,
     `memory_auto_refresh`, `memory_max_chars`, `memory_max_age_days`.

650. **What a tool had to cut is kept, and the marker says how to read the rest.** A
     capped `shell` or `grep` result that threw the rest away would send the model to
     run a test suite again to see line 900 of it. The full text goes into
     `Troupe.Session.Blobs`, the content-addressed per-session store every oversized
     event payload goes into, rather than into a second store: a cut result's full text
     becomes a blob, its `sha256:` digest is the id, and the marker names the
     `read_output` call with the line to resume from (after the kept head for `grep`,
     line 1 for `shell`, whose kept part is the tail). The id is a digest the store
     validates, so a path is never built from anything the model typed, and the blob
     lives and dies with the session like the rest of its history. `read_file` is not
     kept: reading again with the next offset returns the same bytes, and a store for
     that would be a copy of the file.

651. **A question is the other half of an approval, and it travels the same way.**
     `ask_user` hands a decision to a person and its tool call waits for the answer,
     with optional numbered options the client draws as a menu; an approval is a yes or
     no about a call the agent has already decided on. `Troupe.Session.Questions` is
     `Approvals` with text instead of a decision: the tool task blocks in a call that
     never times out on its own (the agent's tool timeout is the one that matters, as
     for an approval), `question_asked` and `question_answered` are durable so a
     question outlives dormancy and a re-run tool finds its answer rather than asking
     twice, and the unattended mode (`approvals: :deny`) answers at once that nobody is
     there, so the model decides or finishes instead of waiting for a person who is not
     coming. On the wire it is one method, `question.answer {session_id, call_id, text}`
     (`control`, activating like `approval.respond`); a client with options sends the
     chosen labels joined by `", "`, and free text is always an answer.

652. **Three read-only tools, in the core's shape.** `glob` (files by name, newest first
     — what `find` was being used for), `git_read` (status, diff, log, show, branch,
     with `ref` and `path` refused when they start with `-`) and `web_fetch` (GET, HTML
     reduced to text, `:ask` because it is egress and a pod's policy may deny it). Each
     resolves paths through `Troupe.Workspace`, runs processes through the reaper, and
     caps output through `Troupe.Tools.Output` with the full text kept for `read_output`
     (Decision 650) — so they gain the mounts, the sandbox and the kept output the core
     has without a line written for the purpose. The built-in profiles list what suits
     them: the read-only ones get `glob` and `git_read`, the planner and the
     orchestrator `web_fetch` and `ask_user`, `build` and `general` everything.

653. **The read tools may reach outside the workspace where the config says, and only
     the read tools.** `read_roots` are directories a `read_file`, `list_files`, `grep`
     or `glob` may resolve into although they are outside the workspace — a dependency
     checkout, the main repository a worktree's `deps` symlink points at. Without them a
     quarter of all read-only shell calls were the model routing around a refusal with
     `cd deps/x && sed -n`. `Troupe.Workspace.resolve_readable/3` is `resolve/3` first,
     and on `outside_workspace` the path's real location — symlinks followed, both sides
     — checked against each root. Writes go through `resolve/3` and never widen, which
     is the whole of the safety argument: a read root cannot make a file writable, only
     visible. It is a config key (`read_roots`, a list of directories, expanded), so a
     pod whose bundle never sets it has none, and the mounts a pod has are untouched by
     it.

654. **A workspace may name its own MCP servers, and a stdio one runs under the reaper
     like everything else.** A pod's servers come from its bundle; a laptop has none, so
     `.troupe/config.yaml` may say `mcp: {name: {command, args, env, cd}}` or `{url}`,
     and `Troupe.Session.MCP` starts them with the session: a `command` server is a
     subprocess speaking newline-delimited JSON-RPC on its standard streams
     (`Troupe.MCP.Stdio`) for as long as the session lives, a `url` server is the same
     one-shot client the pod uses, discovered once. Both kinds' tools are
     `mcp.<server>.<tool>` and go through the same allowlist, permission map and approval
     gate as a built-in; `ask` unless the server's entry says `permission: auto`. The
     reaper forwards the owner's bytes in a mode of its own (`TROUPE_REAPER_STDIO`), Unix
     only: stdin is pumped into the child through a pipe, stdout and stderr are
     inherited, and EOF on the owner's side closes the child's stdin — which is how an
     MCP server is told to exit — with the tree taken down after the grace if it has not. On Windows the server runs as a plain port and
     is trusted to honour that same contract, which is written down here rather than
     pretended otherwise. `mcp.status {session_id}` is what a client's `/mcp` page shows.

655. **A limit is announced before it stops the agent, once, and a client can draw the
     gauge.** `Troupe.Agent.Headroom` is pure and read after every model response: five
     fractions — turns, input tokens, output tokens, wall clock, and the model's context
     window, which is the provider's ceiling rather than ours. A dimension that crosses
     `budget_warn_at` writes a `budget_warning` with the numbers and a sentence
     (`input tokens 4.9M/6.0M (82%)`), and is not warned about again by that agent;
     `agent_state.budget.headroom` carries all five fractions always, so a client draws a
     gauge without knowing how each limit is counted. The warning is durable, not
     ephemeral, although the numbers are in `agent_state` for whoever asks later: the
     contract lets an ephemeral be dropped under load, and a warning that may not arrive
     is not one. The agent's replay ignores it, so it moves no fixture. `full_send: true`
     turns the warnings off for a session that wants no nagging, and a client may set it
     at `session.create`. What happens at the ceiling is 660.

657. **Token usage is four disjoint figures — `input_tokens`, `cache_read`,
     `cache_write`, `output_tokens` — the budget charges what was billed, and compaction
     and the context gauge measure the prompt's whole length.** Anthropic's
     `input_tokens` excludes what its prompt cache served and OpenAI's `prompt_tokens`
     includes it, so read raw the same conversation counts differently depending on who
     answered, and each is wrong in the direction that hurts. On an OpenAI-compatible
     provider a long conversation re-reads its whole prompt every turn and nearly all of
     it is a cache read billed at a tenth, so `max_input_tokens` would exhaust roughly
     ten times early, on work the user was barely paying for; on Anthropic a warm 200k
     conversation reads as a few hundred input tokens once the cache hits, so compaction
     would never fire. Each adapter converts at the boundary — OpenAI's
     `prompt_tokens_details.cached_tokens` comes back out of `prompt_tokens`;
     Anthropic's `cache_read_input_tokens` and `cache_creation_input_tokens` are read
     beside `input_tokens`, and every figure a `message_delta` reports replaces the
     running total — so `input_tokens + cache_read + cache_write` is the prompt's length
     whoever answered. `Budget.charge_usage/2` spends `Usage.billed_input/1` (fresh
     input plus cache writes), and the agent's `last_input_tokens`, which
     `needs_compaction?` and `Headroom`'s `context` read, is `Usage.total_input/1`. The
     `llm_response` event carries all four keys, and `Usage.from_json/1` folds an event
     written before them as a prompt nothing was cached of, which is what it was.
     `Troupe.Session.Usage`, the ledger, reads `input_tokens`, the uncached figure,
     because the cost it records comes from the gateway and not from the tokens; the
     cache figures ride in the event for the day the ledger wants them.

658. **A model's reasoning is a block of its own — opaque, provider-bound, replayed
     verbatim to the provider that made it and to no other — and a reasoning model gets
     the output cap it asks for.** Both providers demand it back. DeepSeek's thinking
     mode is all-or-nothing: once one assistant message in the history carried
     reasoning, one that omits it fails the whole request with a 400, which refused the
     second request of every tool-using conversation. Anthropic signs its thinking
     blocks and demands them back on a tool-use turn. `Troupe.LLM.Reasoning` is a fourth
     content block (`provider`, `text`, `signature`, `redacted`), captured off both
     streams — `reasoning_content` or `reasoning` as a sibling of `content`; `thinking`,
     `signature_delta` and `redacted_thinking` as blocks — logged in
     `llm_response.message` like any block, and handed back only by the adapter whose
     provider produced it: OpenAI as `reasoning_content` on the assistant message,
     Anthropic as `thinking` / `redacted_thinking` blocks and only when the request has
     thinking enabled, since a thinking block is illegal otherwise. `Message.text/1` and
     `tool_uses/1` never see it, so a parent's summary and a client's prose do not fill
     with thinking; a `reasoning` block from a provider this build has no adapter for
     replays as `:unknown` and is carried, never sent. Live, it is `llm_delta` `kind:
     "reasoning"`, which the TUI folds and ACP takes as `agent_thought_chunk`. The cap:
     a model's `reasoning_effort` (from its `models:` entry, through `Config.target/2`
     onto the request) makes the OpenAI adapter send `max_completion_tokens` and
     `reasoning_effort` in place of `max_tokens`, which a reasoning model rejects; a 400
     that names the other field is answered once by sending the request again with it,
     so nobody has to configure what the provider will say. Anthropic takes a budget
     rather than a level, so the level becomes `thinking.budget_tokens` (`minimal` 1k …
     `xhigh` 32k, or a number) and `max_tokens` is raised to hold it rather than the
     request failing. The effort is a per-model setting; an agent's `Definition` has no
     field for it until a profile wants to think harder than its model's default.

659. **A reply is looked at before it is acted on: a cut reply is asked again once, a
     cut tool call is answered rather than run, an empty reply is nudged once, a refusal
     ends the agent as refused, a prompt the provider refused as too long is compacted
     once and sent again, and a model error is a sentence somebody can act on.** Acting
     on `content` and `tool_calls` alone ends a turn the output cap cut in half as
     finished — with half a sentence, or with nothing when a reasoning model spent its
     allowance thinking — runs a tool on arguments cut mid-JSON, finishes a subagent
     with an empty summary, and treats a refusal as a finish; and an opaque error makes
     a blown context window, which is recoverable, read like a typo in a model name. So
     `handle_response/2` looks at the reply first. A `:max_tokens` stop with no tool
     call gets one more request with a note that says what happened and asks for smaller
     steps; the second time the agent ends `output_truncated` with what there was. A
     `:max_tokens` stop with tool calls goes on, because every `tool_use` owes a
     `tool_result` or the next request is refused, and a call cut mid-argument is
     answered with an error naming the cause and not run. A reply with no text and no
     tool call gets the same one nudge and then ends `empty_reply`. A `:refusal` stop
     ends the agent `refused`. Each is a durable `truncated` event, and the note is a
     `user_input` from source `harness`, which is what it is and what lets a replay
     rebuild the conversation the model saw; a subagent that ends any of these ways
     hands its parent what there was, labelled partial, as a budget stop does. On the
     error side `Provider.classify/1` names what a failure was — a context overflow by
     the prose both providers use for it, rejected credentials, an unknown model, a rate
     limit the backoff outlasted — and `describe_error/1` says it in a sentence, which
     is what `llm_error.reason` carries. Only the overflow changes control flow: compact
     once (the `compacted` event says `reason: context_overflow`) and send the turn
     again, since the failed request added nothing to the conversation; a second
     overflow, or a conversation too short to compact, fails with a line that says what
     to do. A 429 gets more attempts than anything else and waits what `retry-after`
     said, up to two minutes, because a rate limit is a wait and not a failure. The two
     guards are not replayed: a restart forgets them and grants the retry again, which
     errs towards finishing.

660. **A spent budget is a question for the person attached, not a stop: `allow` buys
     the same slice again, `always` lifts that limit for the agent and its subagents, `deny`
     ends the agent; a budget the plane's terms set is a contract and stops; `full_send`
     never asks; an unattended session answers no itself.** Ending the agent is what a
     limit is for on a pod running the plane's terms, and exactly wrong on a laptop
     where the person watching would gladly buy another forty turns to see the branch
     finish. The question rides on what the harness already has rather than on a
     mechanism of its own: the agent hands a question to `Troupe.Session.Questions` —
     the `ask_user` path — with `call_id` `budget-<n>`, `detail` (`turns 40/40 (100%)`)
     as the text and `allow` / `always` / `deny` as the options, so a client that can
     answer an `ask_user` can answer this and needs no method of its own; a task waits
     on the answer, since the agent must not block; the agent sits in `waiting`, where
     input queues as it does mid-turn. `allow` adds the allowance the agent was first
     given (`Budget.grant/1`, so grants do not compound) and forgets which limits were
     warned about, because a fresh slice is a fresh warning; the question comes back at
     the end of that slice, a checkpoint each time rather than one irreversible yes.
     `always` lifts the limit the question was about, and no other (687), and a
     delegation inherits it: a person who lifted it for the root did not mean each of its
     children to stop at it. The events are
     `budget_ask_started` and `budget_ask_answered` (with the `grant`), both folded: the
     grant survives a restart, and a `budget_ask_started` without its answer leaves the
     question owed, asked again under the same id, where the questions server hands back
     an answer given meanwhile rather than asking twice. The budget is checked when a
     model call is about to be made and nowhere else — an agent whose turn ended with
     the budget spent rests idle and asks when next given something to do — except where
     the budget is a contract: `budget_asks: false`, which the worker sets whenever the
     plane's terms set anything at all, keeps the stop, because a limit somebody wrote
     into a session's terms is not a suggestion. A subagent never asks either: its
     budget is a slice its parent gave it, and what it found goes back to the parent
     labelled partial for the parent to delegate again if it wants more — a subtree
     waiting on a person while its parent's tool call hangs would be the worse shape.
     `full_send` passes the gate without asking; a session running `approvals: deny`
     gets the questions server's unattended answer, which is no.

661. **A session whose tree a pod cannot put back is parked read-only, once, rather than
     left `active` for every client that opens it to fail on.** Treating every refused
     activation the same way — `dormant`, and try again next time — is a loop when the
     directory is gone, with a raw error for whoever clicked each time. So the worker
     names the class: `Restore.start` failing with `{:not_a_directory, path}` answers
     the plane's `session.activate` push as `not_found` with `data.reason:
     "workspace_gone"` (`Commands.activation_error/1`), and — because the client-driven
     path, a pod activating lazily when somebody attaches, never answers a push — the
     manager also reports it as a `session.unrestorable` notification
     (`Manager.unrestorable_report/2`, only for that class; a stale epoch or storage
     that did not answer is still the plane's to retry or refuse). On the plane both
     roads end in `Sessions.unrestorable/2`: the row goes `read_only`, off its worker,
     fenced on the epoch like a status report so a pod on an older epoch cannot park a
     session a newer one serves, and saying it about a session already parked, erased or
     unknown changes nothing. The slot and the budget slice go back as they do at
     dormancy. `read_only` is the honest state — history readable, nothing activates it
     again — and it already refuses activation with `forbidden` before any pod is asked,
     so the failure happens once and then never.

664. **The identity provider is configured from the console — issuer, client id, secret,
     endpoints, scopes — behind a check, with reset as the way back and break-glass as
     the reason it is safe.** The argument for keeping these read-only is the lock-out:
     a wrong issuer refuses every administrator including the one who typed it, so the
     keyhole should not be adjustable from inside the house. Three things answer it. The
     break-glass door opens the console without any provider. `Settings.reset/2` deletes
     the row and the deployed value is read again, so the deployment is still the floor
     and a stored value only ever overrides it. And `admin.provider.put` is refused
     unless `admin.provider.check` passes for the candidate — discovery answers and
     calls itself the same thing, its keys can be read, the endpoints given agree with
     the ones it publishes — with `force` for the administrator who knows the provider
     is down. Every reader goes through one description, `OIDC.configured/0`: the
     console's authorize request and code redemption, the verifier, the discovery
     document at `/.well-known/troupe` and the RFC 9728 metadata, so a stored value wins
     everywhere or nowhere, and the console asks for the scopes the discovery document
     publishes. The client secret is stored plain in `platform_settings`, flagged secret
     so no rendering ever returns it and the audit diff says *set*; a secret the plane
     has to present cannot be hashed, and an envelope key in the environment would be
     one more thing to deploy and rotate — the trade is named here so it is a choice,
     and the key is the upgrade path (Martin, 2026-09-20, agreed both). Proof:
     `Troupe.Plane.ProviderSettingsTest`.

665. **A team's name is an identifier, and the plane refuses one that is not.** A team's
     name goes into the OpenBao path `troupe/teams/<name>/sessions/<id>` and into the
     Kubernetes claim `team-<name>`, which admits lowercase letters, digits and dashes in
     at most 63 characters and nothing else: a name with a space in it failed every
     session create at the pod, and encoding the path would only have moved the failure
     to the volume. The only place to stop it is where a team is made. `Team.changeset`
     requires `^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$` — 58 characters leaves room for
     the `team-` — and the refusal says so in words: `team.enable` answers with a
     sentence per field instead of an inspected keyword list, and the Teams screen shows
     the rule under the name field before anybody breaks it. The default a pushed group
     is given was already a slug and is now truncated to fit, so a long display name
     becomes a long name rather than a refused one. Existing teams are not touched: the
     format is only checked when the name changes, so a team named before this rule can
     still have its budget edited and can still be removed with `team.disable`, which is
     the way out for it. Proof: `Troupe.Plane.TeamNameTest`.

## One repository

666. **This repository is the monorepo: the platform, the daemon, and the default GUI
     and TUI.** Decided by the team on 2026-09-21. Before it, a client was a separate
     release from a separate repository and the daemon was built elsewhere by pinning
     this one by git ref, which produced four repositories and three pins: the TUI and
     the daemon each named a `troupe-remote` commit by hand, seventeen commits behind
     main by the time anybody looked, and a protocol change was three or four pull
     requests in three repositories with a version bump in the middle. The GUI and TUI
     are now the defaults; a client somebody else writes against `PROTOCOL.md` is
     exactly as supported as it was.

     Three repositories came in with their history, each rewritten by `git filter-repo`
     under its new prefix and merged as unrelated history: `it-minds/troupe-gui` under
     `clients/gui`, `it-minds/troupe-tui` under `clients/tui`, and the umbrella
     repository — `daemon/` and the installers. Their GitHub-generated references to
     their own pull requests, "Merge pull request #N" and a squash title's "(#N)", were
     rewritten to name that repository, because a bare `#N` here links to this
     repository's #N; the umbrella repository's are written as
     `it-minds/troupe-program#N`.

     The clients sit under `clients/`, not `apps/`. Mix treats every directory in
     `apps/` as an umbrella application and warns about any without a `mix.exs`, which
     the GUI's pnpm workspace would be; and the TUI as an umbrella application would put
     ExRatatui, Burrito and `rustler_precompiled` into the shared lock, into every image
     build and into `mix check`. As its own Mix project it costs the server nothing. The
     daemon is the opposite case: its dependencies are three umbrella applications and
     nothing else, so it becomes one (667).

667. **The daemon is an application of this umbrella, released from its own directory.**
     `apps/troupe_daemon` depends on `troupe_protocol`, `troupe_core` and
     `troupe_gateway` `in_umbrella`. Its `troupe_daemon` release — the host-triple
     reaper and the `troupe-daemon` wrapper — is built from that directory rather than
     from the root: a release defined at the root compiles every umbrella application
     first, and on a Windows or macOS runner that is the plane's Postgres and Kubernetes
     clients built for a machine that will never run them. Built from its own directory
     it compiles the harness and nothing else, and its `lib/` holds none of the
     platform's applications. Its runtime configuration is its own `config/runtime.exs`,
     because the platform's reads a pod's environment and the daemon must boot without
     it; its `rel/` turns distribution off. `mix troupe.boundaries` holds it to the
     three harness apps.

668. **One `VERSION` for everything this repository releases, and the TUI builds against
     the harness of its own commit.** Four version numbers with no relation, and a live
     plane whose version only a deploy script knew, were what issue #37 named as the
     thing to end. The root `VERSION` is the version of the images, the chart, the
     daemon and the TUI, and a release is cut by changing it (669). `clients/tui` stays
     a Mix project of its own and depends on the three harness apps by path, `override:
     true`, since they also name each other as siblings. What two Mix projects cannot
     share is a lock: the TUI's `mix.lock` and the umbrella's each lock the packages
     they have in common, and a harness built against one version on a laptop and
     another in a pod is the drift this was meant to end, so `scripts/locks-agree.exs`
     fails when any of them differ and CI runs it.

669. **A release is a merged change to `VERSION`.** Four repositories delivered four
     ways, nothing had ever been tagged, and the plane was deployed by hand from one
     laptop. Issue #37 asked whether deploying should stay manual, and the team's answer
     is no (Martin, 2026-09-21: "I want a deployment on releases too").

     *Cutting one.* `scripts/release <version>` opens a pull request whose only change is
     `VERSION` and its copies (`scripts/version.exs set`), and merging it is the release;
     674 says exactly when a push cuts one. A tag pushed by hand is not a release.
     `docs/developer/ci.md` has what a release runs and publishes.

     *Deploying it* is not this repository's: a release publishes its images and chart
     and ends, and a deployment follows the release from somewhere of its own (735).

     *Worker images* are the part a chart cannot roll, because each profile names its
     own; a profile whose image is `release` follows the chart's worker image (672).

670. **`charts/troupe` serves the GUI, on by default, and `plane.appUrl` follows it.**
     The GUI is `gui:` in this chart: a Deployment, a Service, a NetworkPolicy that
     admits the ingress namespace on 8080 and nothing else, and an Ingress on
     `plane.host` at `gui.basePath` that shares the plane's TLS secret and asks
     cert-manager for nothing. `gui.enabled` is true because the defaults are the
     product: one `helm install` is a plane and a client to use it with. Bringing your
     own is `gui.enabled: false` and `plane.appUrl` set; `plane.appUrl` empty means *the
     chart's GUI if there is one*, so turning the GUI off does not leave the index
     linking to a 404 at `/app`. The chart refuses `gui.basePath: /`, because the root
     of that host is the plane's. The GUI needs `plane.enabled`: a workers-only cluster
     has no host to mount it on.

672. **A profile's image may be `release`, and such profiles move with the platform.** A
     release rolls the plane, the operator, the A2A facade and the GUI, but a worker's
     image is its profile's. CI cannot move them through the admin API, because a
     service principal is refused administration on purpose (`Troupe.Plane.Admin`), and
     writing the custom resources behind the plane would be a change its own record
     never saw. So the plane does it. The chart names this release's worker image
     (`worker.image`, defaulting to the chart's appVersion) and hands it to the plane as
     `TROUPE_WORKER_IMAGE`; a profile whose image is the word `release` keeps the word
     in its row, and `Provision` resolves it wherever a manifest is rendered and
     checked, so the policy judges the resolved image exactly as it judges a typed one.
     `admin.profile.put` refuses `release` on a plane deployed without a worker image,
     rather than writing a WorkerProfile with none. `Fleet.ReleaseImage` runs once as
     each replica starts: every `release` profile whose resource carries another image
     is written again through `Provision.apply/2`, the path an administrator's edit ends
     in, audited as `profile.put` by `system:release` with the image's move as the diff.
     It runs on every replica rather than as a singleton, because a `:global` singleton
     can live on a replica of the release being replaced and would write the old image
     back; the replica that started last has the last word. It never blocks boot, backs
     off to ten minutes while the cluster or the database will not answer, and does not
     give up. In GitOps mode it compares against what it last committed, not the live
     resource, so a Flux that has not caught up does not cause a commit on every
     restart. What it does not do: move a running pod. Worker StatefulSets roll
     `OnDelete`, so the resource says `UpgradePending` until the pods are drained and
     replaced — the routine-tasks page says so — and `profile.get` still reports
     `release` rather than what it resolves to; the console shows the resolution.
     The policy in `values.yaml`, `values.small.yaml` and `values.example.yaml` allows
     the chart's own worker image, so it admits `release`. Proof:
     `Troupe.Plane.ReleaseImageTest`.

673. **The clients in this repository get no private door, and four checks say so.**
     With the clients inside the repository (666), "no private door" is not a property
     of where the code lives, so it is a rule, and each part of it fails CI. The GUI's
     image is built with `clients/gui` as its whole Docker context, so a reach into the
     rest of the repository fails the build. The TUI's `mix troupe.xref` keeps its rule
     that the UI calls only `Troupe.Client`, and gains one for the whole project: it may
     call into `troupe_core`, `troupe_gateway` and `troupe_protocol` only through the
     seven modules it uses today — `Troupe.Protocol.{Client,Daemon,Endpoint}`,
     `Troupe.Config`, `Troupe.Paths`, `Troupe.Reaper` and `Troupe.LLM.Catalog.Store` —
     measured from its beams, so that a path dependency does not become a way around the
     protocol. It cannot see a module named as an atom, and there is one: the child spec
     that embeds `Troupe.Gateway.Daemon` when no daemon is running, which is the TUI
     hosting the harness rather than calling it. The direction the umbrella's
     `troupe.boundaries` cannot see — an umbrella app depending on a client — is a step
     in `check` that fails on a dependency path into `clients/`. And `conformance.py`, a
     client written against `PROTOCOL.md` in another language with no access to this
     source, stays the proof that the protocol alone is enough, because that is what a
     client somebody else writes relies on.

674. **A release is cut when a push changes `VERSION`, not whenever `VERSION` has no
     tag.** Cutting any version without a tag would have released and deployed the 0.2.0
     that `VERSION` had said for weeks when this repository became the monorepo, below
     what production was running, with nobody having asked for a release. The job reads
     two commits and cuts only when the pushed commit changed `VERSION` from its first
     parent — the previous `main` — and the version still has no tag, so a re-run of a
     release's own run cannot cut it twice.

675. **A machine's model settings are the daemon's to read and write, and the plane never
     hands out a key.** A person picks a provider, pastes a key and chooses models in the
     desktop app; the TUI pulls the organisation's defaults with `troupe config pull`.
     Both go through the daemon — `config.get`, `config.models`, `config.set` — rather
     than writing `config.yaml` themselves, because the daemon is the process whose
     environment decides which file a session reads: a client computing `%APPDATA%` on
     its own could edit a file nobody reads, and the desktop app has no filesystem
     permission to do it with anyway. The methods edit only the user's file, report what
     overrides it (a project's `.troupe/config.yaml`, `TROUPE_*`, the opencode fallback)
     instead of hiding it, and never return the key. They are the daemon's alone; a
     worker answers `method_not_found`, because a pod's provider is its profile's. The
     plane offers defaults — provider, URL, auth style, models — as `me.client_defaults`
     from a *Client defaults* settings group with no secret in it: anybody signed in can
     read it, so a shared key there would be a key everybody has. The file is rewritten
     rather than edited, which loses comments; the previous file is kept as
     `config.yaml.previous`, and one that does not parse is never overwritten.

676. **CI runs what a change can have broken; a release runs everything; a pre-release
     runs nothing.** One pipeline for every pull request and every merge cost a merge to
     `main` an hour whatever the change was. `ci.yml` plans each run from what changed:
     umbrella apps from the dependency graph their own `mix.exs` files declare (a change
     tests the app and every app that depends on it), each app a parallel leg, the
     clients only when they or what they build against changed. The soak and the cluster
     suite are where they are owed: `nightly.yml` and `release.yml`, which call the same
     `ci.yml` with `full: true`, so a release still passes every job on exactly the
     commit it ships and builds its images from it. A build to try does not wait for a
     release: `prerelease.yml`, by hand, builds any commit without the suite and
     publishes it as a GitHub pre-release `<VERSION>-pre.<n>` — the installers' default
     never picks one — keeping the newest five. The native builds are `native.yml`, and
     `images.yml` is the one definition of the five images for all three. `release.yml`
     can be started by hand to retry a version whose run failed after its VERSION change
     merged, which 674 alone would leave with no way out but a new version.
     `docs/developer/ci.md` has the picture.

677. **A token with no groups claim says nothing about groups.** Every provider token
     the plane accepts — a login's id token, an MCP client's access token — goes through
     `Login.from_claims/1`, which replaces the person's memberships with the token's
     groups claim. Replacing is right: a group a login no longer carries is one the
     person has left. Reading an absent claim as an empty one is not: an MCP client's
     token is minted for the scopes the client asked for, and read that way the first
     tool call a platform admin made through Claude removed every membership they had,
     their admin group included. So an absent claim leaves memberships alone, a present
     and empty one still clears them, and the MCP resource metadata advertises the
     sign-in's scopes beside the MCP one, so the token carries what a login's does.
     Proof: `Troupe.Plane.LoginGroupsTest`.

678. **A session has a goal: an event to set it, an event to clear it, and a section of
     the root agent's prompt on every turn in between.** It is in the harness so every
     client gets it. `session.goal.set {text}` and `session.goal.clear` are activating
     commands with `control` scope, like `profile.switch`; the root agent writes
     `goal_set` (`text`, `command_id`) or `goal_cleared` under the actor who asked, and
     folds them like the task list, so the goal survives a crash, a dormancy and a
     resume. `session.goal.get` is read from the log and wakes nothing. The events are
     spelled like every other durable event (`goal_set`, not issue #59's `goal.set`: the
     dotted spelling is the older vocabulary clients still translate, never one the
     harness writes); the methods keep the issue's names. The goal goes into the system
     prompt as a `<goal>` section, rebuilt for each request between the skills and the
     task list, rather than as a message in the conversation: the prompt is already
     composed fresh on every request for exactly this kind of standing context (the
     project brief, the task list), and a message would be summarised away by the next
     compaction and repeated into the log on every turn. It is taken at once in any
     state, not postponed to the turn boundary as a profile switch is, because it only
     changes what the next request says. Only the root agent carries it: a subagent is
     handed a task by an agent that knows the goal. Setting the goal a session already
     has, or clearing one it has not, writes nothing. The fold's witness gains a `goal`
     key only while one is set, so every recorded fixture folds to the hash it always
     did. The TUI's `/goal` sets, shows and clears it and its status line carries it.
     Proof: `Troupe.Agent.GoalTest`, the goal tests in `Troupe.Gateway.DaemonTest`, and
     the TUI's `Troupe.GoalClientTest`.

679. **`/loop` runs its iterations as turns of the root agent, not as subagents; each ends
     with the agent's verdict as a tool call; and a loop the whole session came back from
     is stopped, not resumed.** An iteration is an input to the root agent from `loop`, on
     the root's own conversation, with the goal already in its prompt (678). A subagent
     per iteration was the other way, and it is worse at what a loop is for: it starts
     from nothing and reports only a summary, when what the earlier iterations tried and
     what failed is exactly what the next one needs; it carries no goal (678 gives it to
     the root alone); its budget is a slice of the root's; and the person watching sees a
     delegation instead of the work. The root's turns already have approvals, the budget
     question, compaction and cancelling, and an iteration may still delegate. The
     verdict is `goal_complete {summary}`, offered on the loop's turns and no others, and
     outside the profile's tool list because it changes nothing but whether the loop goes
     on; the loop reads the completed call from the log and never the model's prose. An
     iteration without one is followed by the next. The loop is `Troupe.Session.Loop`, a
     process in the session's tree below the agent, which writes `loop_started`,
     `loop_iteration_started`, `loop_iteration_finished` and `loop_stopped` under the
     root's path and folds what it wrote with the function a replay uses
     (`Troupe.Loop`), so a live loop and a replayed one cannot disagree. It stops on the
     goal, at `loop_max_iterations` (10), after `loop_max_failures` (3) failed iterations
     in a row, when the budget question is asked (the question stays with the person, and
     an `allow` does not restart the loop), on `turn.cancel`, on a cleared goal, and on
     `session.loop.stop`, which cancels the root's turn only if it is the loop's. The
     agent is told which loop it serves and drops an iteration of any other, so one queued
     behind a person's turn cannot run after the loop stopped. The loop process
     restarting inside a live session carries on, closing an iteration nobody saw end as
     `failed`; the whole tree coming back marks the loop `interrupted`, for the reason an
     interrupted session makes no model call (ARCHITECTURE.md §2.4), and
     `resume_on_restart` opts back in. Proof: `Troupe.LoopTest`, `Troupe.Session.LoopTest`,
     the loop tests in `Troupe.Gateway.DaemonTest`, and the TUI's `Troupe.LoopClientTest`.

680. **A token with no groups claim says nothing about groups.** Every provider token the
     plane accepts — a login's id token, an MCP client's access token — went through the
     same `Login.from_claims/1`, which replaced the person's memberships with the token's
     groups claim, reading an absent claim as an empty one. Replacing is right: a group a
     login no longer carries is one the person has left. Absence is not: an MCP client's
     token is minted for the scopes the client asked for, the plane advertised only its own
     MCP scope, and so the first tool call a platform admin made through Claude removed
     every membership they had, their admin group included, and every call after did the
     same. Now an absent claim leaves memberships alone, a present and empty one still
     clears them, and the MCP resource metadata advertises the sign-in's scopes beside the
     MCP one, so the token carries what a login's does. Proof: `Troupe.Plane.LoginGroupsTest`.

681. **The installers take the same flags as `scripts/install-local`, and install the desktop
     app too.** `install.sh` and `install.ps1` installed `troupe` and `troupe-daemon`, with
     `--no-tui` for the daemon alone (671), while `scripts/install-local` built the same
     things from a checkout and asked for them by name: `--tui`, `--gui`. A person handed
     both had two vocabularies, and no remote way to get the desktop app without
     choosing among six installers on the releases page. Now the release installers speak
     the local one's: the daemon always, `--tui` / `-Tui` and `--gui` / `-Gui` for the
     clients (naming neither: 681; `--no-tui` still means the daemon alone). `--gui`
     installs the release's AppImage on Linux x86_64 as
     `~/.local/bin/troupe-desktop` with a menu entry, where `install-local --gui` puts its
     build; `Troupe.app` from the `.dmg` in `~/Applications` on macOS; and the per-user NSIS
     setup, run silently, on Windows. A daemon running from the directory being replaced
     is stopped first, as `install-local` does, so an update reaches the next session
     rather than the one after a reboot. `install.ps1` uses `return` where it used `exit`,
     which closes a terminal the script was piped into. Proof: `install.sh` against
     `v0.3.3-pre.1` in a scratch home on Linux x86_64: `--tui --gui` installed all three
     with the AppImage's icon, a reinstall kept every `.previous` and stopped the running
     daemon, a tampered TUI was refused with nothing replaced, no flags without a terminal
     refused, `--no-tui` installed the daemon alone, and `--uninstall --purge` left no file.
     The macOS branch and `install.ps1` are untested here: no Mac and no PowerShell.

682. **An installer is downloaded, readable and pinned to its release, and it asks before
     it acts.** A pipe from `curl` into `sh`, or from `irm` into `iex`, runs whatever
     arrives. A cut-off download runs as far as it got, nobody reads the script first, and
     `iex` leaves the script's variables and `$ErrorActionPreference` in the person's
     session.
     - **Attached and pinned.** Each release now attaches `install.sh` and `install.ps1`,
       covered by its `SHA256SUMS`. `scripts/release-installers` writes the release's
       version into both, so the copy on a release page installs that release, a release
       candidate or a pre-release included, without `TROUPE_VERSION`.
     - **Download, read, run.** The notes and READMEs say to download the script, read it
       if you like, and run it. On Windows that is `powershell -ExecutionPolicy Bypass
       -File`, because the default policy runs no script.
     - **It asks.** In a terminal, with neither `--tui` nor `--gui`, the installer asks
       about each client: yes by default on a fresh machine, otherwise yes for what is
       already installed. It then prints a plan (downloads, processes to stop, what it
       replaces, removes and adds to PATH) and asks before doing any of it. `-y` asks
       nothing. Without a terminal nothing is asked, and naming neither client needs `-y`,
       as before.
     - **Next steps.** It ends with the model settings (682) and what to do next.
     - **Clean install.** `--clean-install` (`-CleanInstall`) removes the current install
       once the downloads check out, keeping config and state unless `--purge` is given.
     - **The TUI's payload.** A running TUI is stopped with the daemon, and Burrito's payload
       is cleared on every TUI install, as `install-local` does. Otherwise a release of the
       version a local build carried would run the build.
     - **Fixes found on the way.**
       - The PATH line goes to the file the person's shell reads. A fresh Mac has no
         `~/.zshrc`, and zsh never reads `~/.profile`.
       - Windows waits for the desktop app's NSIS uninstaller by its registry entry,
         because the uninstaller returns before it is done.
       - Windows PowerShell's progress bar is off, because it made the downloads many
         times slower.
       - Burrito reads `TROUPE_INSTALL_DIR` as where to unpack the TUI, so the bin
         directory's override is now `TROUPE_BIN_DIR`. `install.sh` still reads the old
         name and unsets it.
     - **Proof.** The installers pinned to `v0.3.3-pre.1`, on Linux x86_64 in a scratch
       home and on Windows 11 in scratch directories:
       - fresh, update and clean installs;
       - a running daemon stopped, and `.previous` kept on update, gone after a clean
         install;
       - the questions answered through a pseudo-terminal (Linux) and stdin (Windows),
         including "no" at "Go ahead?";
       - refusals without a terminal or with a stray `--purge`;
       - `--uninstall --purge` leaving no file, and the user PATH untouched with
         `-NoModifyPath`;
       - `troupe --version` passing, the old variable name included.
     - **Not tested:** the macOS branch, and `-Gui` on Windows (the desktop app's setup
       and uninstaller run per user, against the real machine).

683. **A machine with no model settings is set up, not reported on, and opencode's can
     be copied.** An install ended with a daemon and a client that could not reach a
     model, and `troupe config` then reported the defaults: `anthropic`,
     `claude-sonnet-5`, no key. Troupe already reads opencode's providers while it has
     none of its own (`Troupe.Config.OpenCode`), but only for as long as opencode's file
     says so, and nothing said that it was happening.
     - **`config.import`** (`admin`, the daemon's only), with `from: "opencode"`, copies
       opencode's providers into the `providers:` block of `config.yaml`: type, base URL,
       auth style, models, and each key as opencode has it written. An `{env:VAR}` stays a
       reference, and a literal key is copied, which the person asking for the copy
       asked for. That is the one exception to `OpenCode`'s "never written anywhere".
       Providers the file already names are kept, and opencode's default model is taken
       only when the file has none. `troupe-daemon config import-opencode` is the same
       write for the installers, which have a daemon but may have no client.
       `ModelSettings.describe/1` now counts a keyed `providers:` entry as the file's key,
       and reports the opencode fallback only for providers the file does not shadow.
     - **`troupe config`** with no file and no `TROUPE_*` provider asks, in a terminal:
       copy opencode's config if it is there. Otherwise it offers a plane's settings
       (`login`, then `config pull`), a provider set up here (`config.models`, then
       `config.set`), or not now. Without a terminal it prints those choices
       (clients/tui Decision 111).
     - **The installers** end with the same check. An existing `config.yaml` is named.
       opencode's config is offered for the copy. Otherwise, with the TUI installed, the
       installer hands over to `troupe config`, or names the ways on when it cannot;
       without it, the next step is the desktop app's Models panel where the app is
       installed, or the file, since only the TUI has `troupe config`. A
       daemon from before `import-opencode` answers "unknown arguments", and the
       installer says it could not copy and goes on.
     - **Proof:**
       - `Troupe.Config.ModelSettingsTest` "import_opencode/1": the copy loads back to
         the same providers, and a reference stays one.
       - `Troupe.Gateway.ModelSettingsTest`: `config.import` over the socket, and a
         source other than opencode refused.
       - `Troupe.ConfigSetupTest`.
       - `scripts/dev config` and `install.sh`, the latter against a daemon built from
         this branch, driven through a pseudo-terminal in a scratch home.
       - `install.ps1`'s fallback against `v0.3.3-pre.1`.
     - **Not tested:** the TUI's terminal detection and unechoed key prompt on Windows.

685. **The end of a turn is a durable event, `turn_ended`, beside the ephemeral
     `agent_state`.** An agent whose turn ends without `finish` — a reply in prose, or a
     failed model request — rests `idle`, and until now only the live `agent_state` said
     so. That event is ephemeral: a client that attached after the turn ended never saw
     it, and a connection that falls behind drops it. `troupe run --headless` is exactly
     that client, since its session starts working before anything has subscribed, and
     against a real model it never exited (issue #127). The agent now logs `turn_ended`
     (no fields) just before it publishes `idle`, from the one place a turn comes to rest;
     a cancelled turn still ends with `cancelled` and a finished agent with `agent_done`,
     so between them the three say from the log alone that an agent is waiting. It is an
     added event type, which PROTOCOL.md §11 allows and clients must ignore when they do
     not know it; the GUI does, and the TUI reads it as the `idle` it is (clients/tui
     Decision 112). The Loop and the sealer keep reading the live state, which in-process
     they cannot miss, and the index keeps asking the agent.
     - **Proof:** `Troupe.Agent.TurnEndedTest`, the whole-turn sequence in
       `Troupe.Agent.LoopTest`, `Troupe.Session.LogSchemaTest` (the schema knows the type),
       and `mix troupe.schema.diff`.

686. **A config file has one key table, is read strictly, and says where each value came
     from; a workspace's own files set the keys that decide what may run only once the
     workspace is trusted.** Issue #122, the part of it that changes how an existing
     `config.yaml` is read, so it lands before 0.5.0. `Troupe.Config.Schema` is the table:
     every key's type, default, which files may set it, whether it is a secret, and what
     it does. `Troupe.Config.Layers` reads and merges the files against it, and
     `mix troupe.config.schema` writes `protocol/schema/config/v1.json` and the key
     reference in `docs/user/configuration.md` from it, which CI checks with `--check`.
     - **Version.** `version: 1`; a file without it is version 1, and a higher one is
       refused as written for a newer Troupe.
     - **Strict.** A file that is not YAML, a value of the wrong type, or an enum value
       nobody knows (`provider`, `auth`, `approvals`, a provider's `type`, an MCP
       server's `permission`) refuses the load, naming the file, the line, the key and
       what to write; `session.create` answers with that. Nothing loads as `%{}` and no
       enum falls back. `yes`/`no`/`on`/`off`, which YAML 1.2 reads as words, are read
       as the booleans they mean for a boolean key, with a warning, and the approval gate
       takes only `true` as on. Options a client or the command line passes are checked
       against the same table.
     - **Unknown keys warn**, with the file, the line and the nearest key; `x-` keys pass
       and land in `extra`. `mouse` and `llm_timeout_ms` are keys of their own, and
       `llm_timeout_ms` is now the request's timeout.
     - **One spelling.** `models.{default,cheap,expensive,windows}`, and `api_key` with
       `auth: bearer`. `model`, `small_model`, `expensive_model`, `windows`,
       `models.small` and `auth_token` load until version 2, each with a warning; both
       spellings of one setting in one file refuse it. Every writer — the daemon's
       `config.set` and `config.import`, the terminal UI's settings page,
       `troupe config migrate --write` — goes through `Troupe.Config.Migrate.write/2`,
       which writes the new spellings, `version: 1`, a `yaml-language-server` header
       naming the schema, and keeps the file it replaced as `.previous`. Loading never
       rewrites a file, since a rewrite drops comments. `troupe config trust` and
       `untrust` (#161) change one list and nothing else, so they edit the file's own
       lines instead (`Troupe.Config.Yaml.edit_list/4`), keep `.previous` all the same,
       and change nothing when the edit does not read back as that one change.
     - **Maps merge by key** (RFC 7396): a map merges, `null` removes, a list replaces.
     - **`{env:VAR}` that is not set** refuses the provider or MCP server that reads it,
       naming the variable, and anywhere else refuses the load. A refused provider's
       target carries `{:refused, why}` as its key, which both adapters answer with that
       error and no request. `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are used only with
       the vendor's own endpoint (`Troupe.LLM.Endpoint.vendor?/2`). The fallback to
       opencode's providers reads their `baseURL`, `apiKey` and `authToken` the same
       way, with opencode's `{file:path}` too, and refuses a provider whose variable is
       not set or whose file cannot be read.
     - **Scopes and trust.** A key is `:any`, `:trusted` or `:user`. The trusted keys
       change approvals (`auto_approve`, `approvals`, the two `managed_*`), endpoints and
       credentials (`provider`, `base_url`, `api_key`, `auth`, `providers`), commands to
       run (`mcp`), or readable paths (`read_roots`, `state_dir`, `fake_script`). A
       workspace's `.troupe/config.yaml` and `config.local.yaml` set them only when the
       workspace, or a directory above it, is on `trusted_workspaces` in the user file,
       the one `:user` key; otherwise they are ignored with a warning that names the
       command to trust it, `troupe config trust`. A git worktree of a trusted checkout
       is trusted when the checkout's `.git/worktrees/<name>/gitdir` names it back, and
       `troupe config trust` in a worktree writes the checkout, which trusts them all. A session on a pod (`kind: :team`)
       resolves with `trust: :never`. The prompt that asks a person to trust a workspace
       comes with #60.
     - **Precedence** is unchanged, with `.troupe/config.local.yaml` between the project
       file and the environment.
     - **Seeing it.** `troupe config --explain [KEY] [--json]` shows every value, secrets
       masked, with the layer and file that set it, and for one key its whole ladder,
       ignored entries and why included. `troupe config validate [PATH]` exits 1 on any
       error, refusal or warning. `troupe config migrate [--write] [PATH]` prints each
       file's rewrite. `troupe-daemon config` takes the same arguments.
     - **Choices made here.** The trust list is a list of paths in the user file, a
       directory trusting what is under it, and not a per-workspace prompt, which #60
       adds. `config.local.yaml` is gated like the project file: it lives in the
       workspace, and nothing but `.gitignore` keeps it out of a repository. The schema's
       `$id`, and the header writers add, is `https://troupe.dev/schema/config/v1.json`,
       the protocol schema's pattern; until it is served, an editor points at the file.
     - **Proof:**
       - `Troupe.Config.LayersTest`: each refusal (YAML, type, the enums, version, both
         spellings), the warnings (unknown keys with line and suggestion, old spellings,
         `no` read as false), merging by key with `null` and lists, the local layer, an
         unset variable refusing a provider, the session provider, an MCP server and
         the load, the trust gate and its warning, trust from a parent directory and a
         worktree (and not from a borrowed `.git` file), and pods.
       - `Troupe.Config.TrustTest` and `Troupe.Config.YamlTest`: `trust`, `untrust` and
         `--list`, a file's comments and other keys surviving both, a worktree trusting
         through its checkout, and a gated key following the list both ways.
       - `Troupe.ConfigProvidersTest`: opencode's `{env:VAR}` and `{file:path}` read,
         and an unset or unreadable one refusing that provider alone.
       - `Troupe.Config.ExplainTest`: `--explain` with every key, a ladder, JSON and
         masking; `validate`'s exit status; `migrate` and `--write` with `.previous`; the
         writer; the committed schema and reference current; every YAML example in
         `docs/user/configuration.md` and the two READMEs valid.
       - `Troupe.LLM.ProviderKeysTest`: a vendor variable reaches only its vendor's
         endpoint, and a refused provider makes no request.
       - `Troupe.SettingsTest` (clients/tui) and `Troupe.Config.ModelSettingsTest`: both
         writers write the new spellings only, with `version` and the header.
       - `Troupe.Daemon.CLITest`: the arguments, and `validate`'s exit status.
     - **Not tested:** an editor reading the schema through the header, and the native
       smoke runs, which now take the scripted model from `TROUPE_PROVIDER` and
       `TROUPE_FAKE_SCRIPT`.

687. **A tool that keeps failing stops the turn and asks, whatever the budget says;
     `always` lifts only the limit it was asked about; and a delegate's turns are its
     own.** Issues #117 and #118, from one session: a `qwen3-235b` root agent called
     `read_branch` with ids `"1"` to `"352"`, one per model call, and failed the same way
     each time for half an hour and over $4, after the person had answered `always` to an
     input-token question — which lifted the turn, output and time limits as well.
     - **The failure guard.** `Agent.Server` counts each tool's failures in a row, by the
       tool's name. Not by its error text: the loop's errors differed by id, normalising
       text is guesswork, and a tool that fails ten times running deserves the question
       whatever it said. A success of that tool clears its count. Counts are taken when a
       turn's results are folded, in call order; the calls a cancel or a restart closes
       are not counted. At `tool_failures_note_at` (5) a note follows the results, a
       `user_input` from `harness` as 659's notes are: the model reads it, both clients
       already show it, a replay rebuilds it. At `tool_failures_stop_at` (10) the gate
       before the next model call stops the turn, ahead of the budget and under
       `full_send`, a lifted limit or a contract budget alike, because it is about the
       loop and not the money.
     - **Asking.** The root asks as the budget does (660): through
       `Troupe.Session.Questions` under `failures-<n>`, with `tool_failures_ask_started`
       and `tool_failures_ask_answered` beside it, waiting in `:waiting` in the slot the
       budget question uses. So there is one question at a time, and one still owed is
       folded and asked again under its own id after a restart. `stop` is the first
       option, because a client with nobody to ask answers with the first (the headless
       runner does); `continue` clears the count. `stop` writes a harness note saying why
       and ends the turn with `turn_ended` `reason: tool_failures`. The headless runner
       exits 1 on it, `/loop` counts it a failed iteration, and a restart does not take
       the turn up again (it reads as a cancel). A session with `approvals: deny` answers
       `stop` itself. A subagent does not ask: it ends `tool_failures` and hands its
       parent what it has, labelled partial. The counts are not replayed, as 659's guards
       are not; `0` turns a step off.
     - **`always` lifts one limit.** `Troupe.Budget` gains `lifted`, which `check/1`
       skips. The answer names the limit (`budget_ask_answered.lifted`), and the option
       says which: "lift the input-token limit for the rest of the session". The GUI's
       and TUI's own words for it changed to match. A lifted limit still reaches the
       delegates, inside their slice, since 660's reason stands; a lifted dimension's
       slice is a share of the parent's first allowance, because of a limit it has passed
       the parent has nothing left to share. An `always` in a log written before this has
       no `lifted`, and folds to the limit its `budget_ask_started` named. That is what
       the question asked about; the limits it used to lift as well ask again when
       reached, which costs a question and never any work. 660 said `always` lifted the
       whole budget, and now points here.
     - **A delegate's turns are its own.** `Budget.slice/2` gave a child `budget_share`
       of its parent's *remaining* turns: 0.4 × (40 − used), about 14 for an `explore`
       started late in a root's turn, and six of seven asked to read an app ran out
       before reporting (#115). But a child's turns cost its parent none. Only its tokens
       are charged back, and its clock runs on the parent's, so sharing turns had nothing
       behind it and shrank with every turn the parent took. A delegate now gets the turns
       its parent was first given (40 by default), lowered by its definition's
       `max_turns` as a root's are; tokens and time are still a share of what the parent
       has left. The issue's other options were worse. A turn floor for `explore` alone
       patches one profile. Leaving turns out for read-only agents needs a notion of
       read-only, and removes the one bound on a loop of cheap calls. Resetting a root's
       turns on each input changes the root's contract, and belongs with the root
       turn-cap discussion. With tokens still sliced and the failure guard on stuck
       loops, a full turn allowance is safe.
     - **Whitespace is not a reply.** A reply of whitespace alone is empty, nudged once
       and then `empty_reply` (659), and a subagent's prose summary is handed over
       trimmed, as #130 did for a budget stop's.
     - **Proof:**
       - `Troupe.Agent.ToolFailuresTest`: the note at 5 and the question at 10, `stop`,
         `continue`, a success clearing the count, `full_send`, `always` on the budget
         question, an unattended session, the config's thresholds, a subagent, a
         question re-asked after a restart, a stopped turn a restart leaves alone, and
         no approval left open in the summary after a stop.
       - `Troupe.Session.SleepTest`: a session asleep on the guard's question is listed
         as waiting and asks it again on wake (#119's sleep); once stopped, it wakes
         with nothing to take up.
       - `Troupe.Agent.BudgetQuestionTest`: `always` on input tokens leaves turns asking;
         on turns, input tokens and time; an old `always` folds to its question's limit.
       - `Troupe.BudgetTest`: each limit lifted leaves the other three.
       - `Troupe.Agent.DelegationTest`: an `explore` delegated after six turns finishes
         twenty reads, and a subagent's whitespace or padded reply.
       - `Troupe.Session.LoopTest`: guard-stopped iterations stop a loop.
       - The TUI's CLI test: a headless run exits 1 on a guard stop.
       - The installed daemon, driven with a fake-provider script.
     - **Not tested:** a real gateway. The nightly real-gateway job is to rely on the
       guard's `turn_ended` reason.

688. **A delegation always comes back: a subagent whose model request fails hands its
     parent what it has, a child's path names one child for the life of the session, and
     a `finish` ends only the turn that called it.** Issue #149, three defects found by
     fixers in the chunk before 0.5.0, in the family of its gate on runaway and hung
     agents. Two left a parent waiting on its `delegate` call for ever, since a delegation
     has no timeout; the third ended a turn before the model saw its results.
     - **A failed model request.** A root rests after one (685): the error goes into its
       conversation and the person says what next. A subagent rested too, and nobody
       talks to a subagent but its parent, which was waiting on it. It now ends
       `llm_error`, as a spent budget (660) or a failing tool (687) ends it, and hands its
       parent what it said before the failure, labelled cut short, or a line saying the
       request failed before it reported anything. Either way the error is in it, so the
       parent's model can tell a blown context from a gateway that is down before it
       delegates again. A context overflow still compacts once and retries first.
       `llm_error` joins `agent_done`'s reasons; a root never ends with it, and its
       `turn_ended` keeps no `reason`, since the `llm_error` before it says why and the
       clients already read that.
     - **A child's path.** `spawn_child` names a child `<agent>#<n>` from `child_seq`,
       which was never folded, so after any restart the next delegation was `#1` again.
       A child started under a path that has a log replays that log instead of taking its
       task; the first child had finished, so the new one came back `done`, never
       reported, and its parent waited. `delegation_started` is now folded, to the highest
       number a child path ends in. Not a count: a child that failed to start took a
       number and wrote no event. A path from before the numbers (`["root", "explore"]`)
       counts as one more. A delegation that a restart takes up again, being a call that
       had not finished (re-run at least once, as any tool is), gets a new child on the
       same task rather than the path it had: that child's log would come back `done` if
       it had reported just before its parent died, and hang as before. What the old
       child did is still in the log.
     - **`finish`.** Its summary waits for the turn's other calls, and was never cleared.
       After a finished root was woken (635), or a cancel stopped a turn with a `finish`
       in it, the next tool turn finished at once with the old summary. It is now cleared
       with the rest of a turn's call bookkeeping, in `State.clear_calls/1`.
     - **Old logs.** `Troupe.Log.Fold` witnesses `delegation_started` without projecting
       it: the children it started are in the witness already, each an agent under its
       own path, so the recorded fixture hashes stand and a change in how paths are made
       would still move them.
     - **Proof:**
       - `Troupe.Agent.DelegationTest`: a subagent whose model request fails, after
         saying something and before.
       - `Troupe.Agent.ResilienceTest`: a second delegation after an agent restart and
         after the session comes back, a delegation a restart takes up again, a woken
         agent's tool turn, and a `finish` in a cancelled turn.
       - `Troupe.Log.FoldTest`: the fixture hashes, unchanged, and the witness.
       - The installed daemon, driven with a fake-provider script.

689. **A model the catalog does not price is priced from `models.prices`, which a profile
     sets for its pods as `llm.prices`; the gateway's figure still wins, then the
     catalog's, and a model with no price anywhere is said once a session rather than
     counted as free in silence.** Issue #160. A streamed response carries no cost
     header: LiteLLM sends its headers before the first token, so `x-litellm-response-cost`
     is absent. The harness then prices the call from the catalog (`priced_locally`),
     and a pod has no catalog, nor does the catalog list every model a gateway serves
     (`qwen3-235b`). Such a call had no `cost_micros`, the plane's ledger summed it as 0,
     and no team or person budget ever counted it.
     - **The key.** `models.prices.<model>: {input, output, cache_read, cache_write}`,
       dollars per million tokens as a price list quotes them and opencode's `cost`
       writes them, by the name a model is addressed with: the bare id for the
       session-wide provider, `<provider>/<model>` for a named one, as `models.windows`
       and the catalog are keyed. The cache rates default to the input rate, as the
       catalog's do. A price missing either half prices nothing and warns; `0` is free,
       a price. `TROUPE_MODEL_PRICES` takes the same map as JSON, checked entry by entry
       as a file's value is. Scope `:any`: a price moves no request and runs nothing, and
       on a pod the environment, where the profile's prices arrive, outranks a project's
       file for every model it names.
     - **Precedence.** The gateway's `cost_micros`, then the catalog's price, then the
       configured one. Unlike a window (clients/tui Decision 60), a configured price does
       not overrule the catalog: a window is a choice a person makes about a model, a
       price is a fact about the bill, and the provider's own list is nearer the bill
       than a copy of it in a file, which also goes stale without saying so.
     - **Names.** A call is priced under the id the agent addressed, then the wire id,
       then the id the provider answered as. The lookup was by the last two alone, so a
       catalog keyed `portal/glm-5.2` never priced a call to `portal/glm-5.2`.
       Micros are rounded rather than truncated.
     - **Said once.** A call nobody prices is logged as a warning, naming the model and
       the key that would price it, and emitted as `[:troupe, :llm, :unpriced]`, once a
       session: the first agent to call the model claims it in the session's registry,
       and the claim goes with that agent. Nothing new in the protocol: the call's
       `llm_response` already has no `cost_micros`, which a reader treats as not known.
       `troupe models` and `troupe-daemon models` show every model's price with its
       source, `(catalog)` or `(models.prices)`, or `no price`, and list every id
       `models.prices` names; `troupe config --explain models.prices` shows which file or
       variable set each price.
     - **The plane.** `WorkerProfile.spec.llm.prices`, in the resource's camelCase
       (`cacheRead`, `cacheWrite`), declared in the CRD and set through
       `admin.profile.put`; the operator hands it to the pods as `TROUPE_MODEL_PRICES`,
       sorted so a reconcile rolls nothing. The console's profile editor carries it
       through a save without showing it. A pod's usage batch carries the cost and not
       where it came from, and the plane charges it like any other.
     - **The live check** takes the gateway's rates from `TROUPE_NIGHTLY_MODEL_PRICES` and
       marks a cost it worked out itself *priced here*; unset, the column still says
       *not reported*. A fake-provider script may say `"cost_micros": null`, a gateway
       that names no price, which is how both are tried offline.
     - **Proof:**
       - `Troupe.Session.LocalPricingTest`: a priced unknown model gets `cost_micros` and
         `priced_locally`; the gateway's figure and the catalog's price each win over a
         configured one; an unpriced model is said once across two calls.
       - `Troupe.Config.PricesTest`: the file and `TROUPE_MODEL_PRICES`, merged by model,
         the names, the precedence, `0`, a half price, a word for a number, bad JSON,
         the report's sources and `no price`, and `--explain` as text and JSON.
       - `Troupe.Operator.ResourcesTest`: the prices reach the pod in the config's names,
         sorted, and a profile without them says nothing.
       - `Troupe.Plane.UsageTest`: a cost the pod worked out itself spends a team's
         budget and refuses the next reservation. `Troupe.Plane.PanelTest`: a save from
         the profile editor keeps the prices.
       - The installed daemon, with a fake-provider script that reports no cost and a
         configured price.
     - **Not done here:** editing prices in the console, and a price per model in the
       desktop app's model settings; a plane report of the calls that cost nothing.

690. **A pod's slot is given back before the session's row is marked, and a release that
     finds nothing to give back counts the profile again.** Issue #173, found by the
     fixer of #135. `Placement.release/2` finds a pod's slot by the session row's
     `worker_id`, and `Sessions.dormant/2`, `read_only/1` and `unrestorable/2` all clear
     that column. A pod's own `session.dormant` report, an erasure and a
     `session.unrestorable` report each marked the row first. Their release found nothing,
     and the placement actor went on counting a session that had left the pod. Only a
     reserve about to be refused counted again, so until then the least-loaded pod was
     chosen on counts that were too high.
     - **The order.** The dormancy report and an erasure now release first, as
       `Drain.strand/2` already did. The control connection's orphan path calls
       `Drain.strand/2` rather than keep its own copy of it. The `unrestorable` report
       cannot release first: it is fenced on the epoch, and a release ahead of the fence
       would let a pod on a stale epoch give back a slot a newer epoch holds.
     - **The recount.** A release whose session is on no pod reloads the actor's counts
       from the database, as the refusal path does. That covers the `unrestorable`
       report, and any caller that gets the order wrong again. It costs a group-by only
       on a release that found nothing: a session never placed, or one given back
       already. A second release of the same session finds nothing and recounts, so no
       slot is given back twice. The refusal path keeps its recount for sessions taken off
       their pods with no release at all, which a revoked grant's
       `Sessions.read_only_for/2` still does.
     - **Proof:** `Troupe.Plane.ControlTest`: a pod's dormancy report takes a full pod
       from four to three without a recount, and the next reserve fits without one; an
       `unrestorable` report gives its slot back; a session the plane strands and the pod
       then reports dormant twice gives back one slot. `Troupe.Plane.HarnessTest`:
       erasing one of two running sessions leaves the pod counting one.
       `Troupe.Plane.PlacementTest`: a release after the row went dormant gives the slot
       back at once. All but the one about giving back once fail on the chunk's tip.

691. **What `troupe-daemon` prints names `troupe-daemon`'s commands, in ASCII, with paths
     as Windows writes them.** D20 in docs/developer/defects.md. What loading warns about
     is written once, naming `troupe config migrate` and `troupe config trust`, and both
     programs print it. `config --explain`, `validate`, `migrate`, `trust` and `untrust`
     now take `command:`, as `Config.describe/2` has since #153, and
     `Troupe.Config.as_run_by/2` names the program printing. The text is rewritten where
     it is printed rather than where it is written, because the loader does not know who
     will print it, and the same warnings reach a session's clients; a migration's diff
     is a file's own text and is left alone. The masked key and the model report's
     separators are ASCII (`sk-a...op`, commas), because the Windows console shows
     anything else as stray characters. `Troupe.Paths.display/1` also gives a drive
     letter the case Windows shows (`File.cwd!/0` says `c:/`), and is used for every path
     a config report prints, an issue's file included; what is stored, and the JSON,
     keep the path as loaded. `troupe-daemon status` says where the sessions are kept,
     which is what the TUI's help sends a person to it for. `Troupe.Protocol.Daemon`
     starts a daemon on Windows with `start "" /b` through `cmd /s /c`: `start` read a
     program's quoted path, which one in a directory with a space has to be, as a window
     title, and started nothing. A worker's activation error that is an exception is
     its message. Proof: `Troupe.Daemon.CLITest`, `Troupe.Config.ExplainTest` and
     `TrustTest`, `Troupe.PathsTest`, `Troupe.Gateway.AutospawnTest`,
     `Troupe.Worker.UnrestorableTest`, and the installed build on this machine.

692. **A `user_input` names the send it was taken from.** `input_queued` and
     `input_accepted` carried the client's `command_id` and `user_input`, the copy with
     the text, did not, so a client that draws a line as it is typed could not tell the
     durable copy for the same line, and the TUI drew every typed line twice (issue #181).
     The agent now writes the command id on the `user_input` of every input it takes, a
     person's, the watcher's, a loop's iteration and a task edit alike: the id its
     `input_accepted` has, which the agent generates where the caller had none. A
     `harness` note, which nobody sent, has none. It is an added, optional field, which
     PROTOCOL.md §11 allows. Neither the agent's replay nor the fold reads it, so a log
     written before it replays as it did and no recorded fixture's hash moves. The GUI
     keeps its pending send outside the stream and draws `user_input` once, and is
     unaffected; the TUI draws a line once by it (clients/tui Decision 117).
     - **Proof:** `Troupe.Agent.InputTest`, the loop's ids in `Troupe.Session.LoopTest`,
       the watcher's in `Troupe.Watch.WatchSessionTest`, `Troupe.Session.LogSchemaTest`,
       `Troupe.Log.FoldTest` and `mix troupe.schema.diff`.

693. **A subagent is stopped once its parent has its result, and a restart closes what it
     leaves behind: the calls of a child nothing starts again, a turn's results already
     back, and a root's note about a failed request.** Issue #171, and D18 and D19 in
     docs/developer/defects.md.
     - **Stopped on report (#171).** A finished subagent kept its process, and with it its
       whole conversation, until its session's tree stopped. Nothing addresses a finished
       child by its process. Input, a cancel, the loop, the watcher and an approval's
       answer go to the root. `read_branch` reads branches, which are sessions, off disk.
       The TUI's agent detail and the desktop app build an agent from events. A restart
       replays the root's own log, and a delegation it takes up again gets a new child
       (688). `Troupe.snapshot/2` and `Troupe.agent_tree/1`, which the worker's drain and
       the sleep rule (#166) walk, take a stopped child for what a `:done` one was, not
       at work. So the parent stops the child's Node as soon as it has taken the result,
       through its own `Agent.Children` as a cancel does. An idle time first would keep the
       memory for nothing. The child writes `agent_done` and announces `done` before it
       reports, so its parent's `tool_call_completed` always follows its `agent_done`, and
       stopping it cuts nothing off.
     - **An unpriced model's warning (689)** was claimed in the registry by the agent whose
       call it was, and the claim went with that agent: a subagent that stops would have
       left the next one to warn again, once a delegation. The session's `Log` now makes
       the claim, and it lives as long as the tree.
     - **A delegation a restart closes or takes up again (D18, D19).** Nothing starts its
       child again, so the child never reports and never closes its own calls. After the
       session came back, an approval it had waited on stayed open in `Summary`, the
       worker's status and the desktop app's transcript (a test confirmed it), and its log
       had no `agent_done`. The parent now writes, under that child and every agent below
       it, a `tool_call_completed` with `ok: false` for each call still open, which is how
       every reader already closes an approval or a question (#142, #145) and the per-call
       half of what a cancel writes (#138). Then `agent_done`, with the new reason
       `interrupted`, where the agent has none.
     - **A turn a restart comes back in the middle of (D19).** The results that were back
       before it were not put back. The next `tool_results` held only the calls re-run or
       closed, which a provider refuses (every `tool_use` is owed a `tool_result`), and a
       `finish` among them lost its summary and took another model turn. Replay now puts
       the completed calls back from their `tool_call_completed`, with the summary of a
       `finish` among them, when the restart re-runs or closes the rest; one that takes
       nothing up leaves them, so a summary cannot outlive its turn (688). A call closed
       as interrupted and one put back out to a person now reach the conversation in one
       `tool_results`, not two.
     - **A root's failed request (D19).** "The previous model request failed: ..." went
       into the conversation and not into the log, so the conversation a restart rebuilt
       did not have it. It rides in the `llm_error` as `note`, and replay folds it. Not a
       `user_input` from the harness, as the other notes are: a client reads one of those
       as the turn going on, and the A2A mapping would turn a failed task back to
       `working`, while this note ends the turn.
     - **Old logs** have no `note` and no `interrupted`, and replay as they did.
       `Troupe.Log.Fold` counts a `note` as a message, and the recorded fixture hashes are
       unchanged.
     - **Proof:**
       - `Troupe.Agent.DelegationTest`: five delegations with one still at work hold that
         one alone (the agent tree and the registered processes counted), five in a row
         hold none, and a stopped child is still read from its log, before and after its
         parent restarts; each child's `agent_done` comes before its result is taken.
       - `Troupe.Agent.ResilienceTest`: a restored session leaves no approval of its
         subagent open, in `Summary` or the gate; the child a restart re-ran a delegation
         past ends `interrupted` with nothing open; a root's failure note survives the
         session coming back; a turn keeps the results already back when the session comes
         back, a call closed as interrupted and one put back out to a person reach the
         model together, and a `finish` among them ends a root, and a subagent with the
         summary its parent is handed, after the agent restarts.
       - `Troupe.Agent.CutShortTest`: a subagent cut short is stopped, and its session
         still sleeps. `Troupe.Session.LocalPricingTest`: a model only subagents call is
         said once a session. `Troupe.Log.FoldTest`: the fixture hashes, unchanged, and
         the note.
       - The installed daemon, driven with a fake-provider script.
     - **Not done here:** a subagent a cancel takes down still leaves its own calls open in
       its own log; the `cancelled` on the agent above closes them for every reader (#145).

694. **A session that leaves its pod for good gives back its slot and its budget slice,
     each once, however it left.** Issue #190, D22 in docs/developer/defects.md, found
     by the fixer of #173. A pod's dormancy report gives back both. Three other endings
     gave back less, and a budget slice left open is held for good, because every rung
     reloads the ledger's open reservations. A slot came back at the next refused
     reserve (Decision 690); a slice never did.
     - **A revoked grant.** `Identity.revoke/2` froze the team's sessions on the profile
       with one `Sessions.read_only_for/2`, which clears `worker_id` and gives back
       nothing. It now takes each running one off its pod first, then freezes the rest.
     - **An erasure.** It gave back the slot but not the slice. The pod's `session.erase`
       fences the session and throws it away without reporting it dormant.
     - **A dormant session its pod will not take back.** Waking it reserves the slice
       again before `session.activate` is pushed, and a refusal left the slice held. The
       pod does report `workspace_gone` as `session.unrestorable`, which releases, but
       only when that report arrives.
     - **`Drain.park/1`** is `Drain.strand/2` for a session that is not going back to
       any pod: the slot first, then the row read-only, then the slice at every rung.
       Erasure, a revoked grant and a `workspace_gone` refusal park; any other refusal
       strands, so the session is dormant again and holds nothing.
     - **Once.** A second release finds nothing. `Placement.release/2` counts again, as
       Decision 690 says, and a budget release is by session. So when a pod that went on
       running a revoked session reports it dormant later, nothing goes back twice.
     - **Since Decision 697** a revoked grant also puts the session to sleep on its pod,
       leaves the row read-only when the pod reports it, and parks the team's sessions
       still waiting for room.
     - **Proof:** `Troupe.Plane.BudgetLadderTest`: revoking the grant of, or erasing, a
       running session leaves nothing held by the team, the person, the ledger or the
       pod. `Troupe.Plane.HarnessTest`: a pod that will not take back a dormant session,
       with `workspace_gone` or without, leaves no slice held. `Troupe.Plane.ControlTest`:
       a revoked session's pod reporting it dormant twice gives back one slot. All five
       fail on the chunk's tip.

695. **On Windows the desktop app installs into `%LOCALAPPDATA%\Programs\troupe-desktop`,
     and a setup moves an install out of the daemon's state directory.** Issue #185, D15
     in docs/developer/defects.md. Tauri's per-user NSIS setup installs into
     `$LOCALAPPDATA\<productName>`, `%LOCALAPPDATA%\Troupe`, which NTFS reads as the
     daemon's `%LOCALAPPDATA%\troupe`: the app and its uninstaller sat beside the
     sessions and `identity.json`, one recursive delete of "the app's folder" from losing
     them.
     - **Where.** Under `%LOCALAPPDATA%\Programs`, where per-user programs go, but not in
       `Programs\Troupe`: that is `Programs\troupe`, which `install.ps1` puts on the
       `PATH`, and an `uninstall.exe` on the `PATH` is a command to type by accident.
       `troupe-desktop` is named for the binary and sits beside `troupe-daemon`.
     - **How.** An installer hook, `installer-hooks.nsh`, rather than a copy of Tauri's
       template that would have to follow every Tauri release. It moves `$INSTDIR` when
       it is `$LOCALAPPDATA\<productName>`, whether that is the default or the registry's
       record of the last install: as the window opens, so the directory page shows the
       new place, and again before the files are copied, which is all a silent setup
       (`install.ps1 -Gui`) runs. Once the app is in, the old install's Start menu,
       desktop and taskbar shortcuts are pointed at it, and the old install's two files
       are deleted by name. The directory stays. The uninstaller is Tauri's, unchanged: it
       deletes its own files by name and its directory only when that is empty.
     - **Kept.** `install.ps1 -Uninstall -Purge` still runs the app's uninstaller before
       it deletes the state, for an install from before 0.5.2 that no newer setup has
       moved. A silent setup on a machine without the state directory still creates it,
       empty, because the template enters the default directory before the hook runs; the
       daemon would create it anyway.
     - **Proof.** On this machine, with the product renamed (`TroupeD15`, binary
       `troupe-desktop-d15`) so no setup could touch the installed app, and a stand-in
       state directory at `%LOCALAPPDATA%\TroupeD15`. The chunk tip's setup installed
       beside the stand-in state. The fixed one moved that install to
       `Programs\troupe-desktop`, repointed its shortcuts and left the state byte for
       byte: silent, silent with no shortcuts of its own (`/NS`), silent while the old
       app ran, and through the window choosing "Do not uninstall". The directory page
       showed the new place for that upgrade and for a fresh install; `/D=` naming the
       state directory was overridden; a reinstall of the same version kept the new
       install; its uninstaller left the state. Not run: the real product's setup, which
       would have replaced the maintainer's install.

696. **A librarian's run stamps the brief it checked, whether or not it rewrote any of
     it.** The brief counts as built when a curated section is written (Decision 649),
     one never built is stale, and a client with `memory_auto_refresh` starts a
     librarian on a stale one. A librarian that found nothing to rewrite, or wrote only a
     note, left the brief unbuilt or as old as it was: a brief of notes, or one a person
     wrote by hand, stayed stale for good, and every new session in that repository
     started another librarian and paid for it. Found in chunk 5; the TUI's test that said
     a second session "starts nothing" listened for the librarian after it had started.
     Now a `librarian` agent whose run ends as it meant to, by answering or with
     `finish`, stamps the brief (`Troupe.Session.Memory.checked/1`: `built_at`, `head`
     and `files`, and no word of the text), so the brief is stale again only when it is
     older than `memory_max_age_days` or the repository has drifted. What is stamped is
     the run, not what it wrote, because finding nothing to change is the librarian's
     answer too; a run that failed, was cancelled or ran out of budget stamps nothing and
     is tried again by the next session. The agent knows the profile by its name, as the
     client does when it starts it, and the stamp makes no brief where there is none.
     - **Proof:** `Troupe.Tools.RememberTest`: a brief of notes and a hand-written one,
       each left fresh and word for word as it was by a librarian that wrote nothing,
       while another agent's turn and a librarian's failed request stamp nothing. The
       TUI's `Troupe.MemoryClientTest`, whose second session now reads its own journal
       for the librarian. Both failed on the chunk's tip.

697. **A team's grant on a profile holds wherever one of its sessions could run or
     start: on the pod running it, in what that pod reports afterwards, when it is woken
     and when it is placed after a wait.** Decision 694 made a revoke leave the team's
     sessions on the profile read-only and give back what the running ones held. These
     are the places that went on without looking at the row or the grant.
     - **The pod.** `Identity.revoke/2` takes each running session through
       `Drain.withdraw/1`: `Drain.park/1`, then the `session.dormant` an archive sends,
       pushed to the pod running it, which seals the session, uploads its workspace and
       deletes its own copy. The plane does not wait for it, because a pod takes as long
       as a seal and an upload take and a revoke can cover many sessions; a pod that does
       not answer is logged.
     - **What the pod reports.** `Sessions.dormant/2` leaves a `read_only` or `erased`
       row as it is and answers `{:error, :parked}`. It reads the state under the row's
       lock, so a park or an erasure landing at the same moment is wholly before it or
       wholly after it. The control connection applies a dormancy report's status only to
       a row the report made dormant; the slot and the slice releases stay, and give back
       nothing twice.
     - **Sessions waiting for room.** A revoke parks them as well
       (`Sessions.holding_for/2`), which gives back the slice each reserved when it was
       created, and `Sessions.read_only/1` drops the prompt kept for one.
     - **Waking and placing.** `session.open` in `activate` mode, for a session that is
       not already running, and the scaler's `Harness.admit/1` check that the session's
       team exists and holds a grant on its profile (`Identity.granted?/2`). A wake is
       refused with `forbidden`. Admission checks before it reserves anything, parks the
       session and answers `:no_grant` or `:no_team`, and the scaler goes on to the next
       session, since no room was taken.
     - **The pod's harness.** An activating command reaches a tree that is running on the
       pod and never brings one back: the worker's endpoint gives the gateway
       `Troupe.Worker.Sessions.running/1` in place of `Troupe.activate/1`, through the
       endpoint's new `activate` option. A session with no tree there answers `not_found`
       with `data.kind` of `session`, which a client follows to the plane (PROTOCOL.md §6,
       "A session that moves"), whatever the pod has of it on disk. A manager still
       putting its tree back is waited for. The local daemon's endpoint has no such
       option and restores as before, and `session.create` on a pod, open only to a token
       with no session (PROTOCOL.md §7), is unchanged.
     - **Proof:** `Troupe.Plane.GrantEnforcementTest`: a revoke pushes `session.dormant`
       to the pod and parks a waiting session with its slice back; a wake is refused with
       the grant gone and with the team gone; admission parks instead of placing in both
       cases, and the scaler places the next session. `Troupe.Plane.ControlTest`: a pod's
       dormancy report leaves a revoked session read-only and an erased one erased.
       `Troupe.Worker.PlaneLinkTest`: a revoke stops the session on a real pod, and the
       pod's report leaves the row read-only. `Troupe.Worker.HarnessWebSocketTest`:
       activating commands for a session the pod has only on disk answer `not_found` and
       start nothing. All ten fail on the chunk's tip.

698. **The slash commands a client offers are one table in the harness,
     `Troupe.Commands`, published as `commands.list`; a client keeps only the code that
     runs each one, and the TUI's suite holds its set equal to the table.** Issue #124.
     The TUI had three lists that had to agree (the dispatch table, Tab completion and
     the window-path commands), `/help` opened the settings, and the desktop app had no
     commands at all, so nothing told a person what they could type. Now every built-in
     has one entry — name, aliases, section, a one-line summary, usage, arguments, what
     it needs (`availability`) and where it came from (`source`) — and the agents are
     entries in a section of their own, described by their definition rather than
     pretending to be built-ins: the same primaries `agents.list` answers with, so a
     palette and a session picker never disagree. `availability` is a requirement the
     client judges, not a verdict the harness passes (`always`, `window`, `local`,
     `plane`), so a client shows a command it cannot run greyed with the reason rather
     than hiding it, which is how somebody learns the tool. `/goal` and `/loop` (#59)
     are entries like any other. A worker answers the same method through the same
     handler, so a pod's palette lists its bundle's agents. Still owed to #124, and out
     of this: commands defined as markdown files, and generating `troupe --help` and the
     docs' command reference from the table. Proof: `Troupe.CommandsTest`,
     `Troupe.Gateway.CommandsListTest` (over a socket) and the TUI's
     `Troupe.CommandPaletteTest`, which fails the moment the two sets differ.

699. **The budget question is answered with how much more and for how long: a typed
     amount raises the limit that asked, for this run, this session or this workspace;
     an answer that cannot be read is asked back; a pod's terms are a ceiling.** Issue
     #183. Answering `50` to the budget question stopped the session: `budget_decision/1`
     knew `allow`, `always` and `deny` and read everything else as a refusal, the only
     sizes were "the same slice again" and "no limit at all", and nothing could make a
     limit stick for a repository.
     - **Every amount is an increment on the limit that asked**, whatever the spelling —
       `50`, `+50`, `50 turns`, `+50k tokens`, `+15 min` — because "raise it to 50" reads
       two ways when 40 is used and "50 more" reads one. The steps offered are increments
       too: three round numbers from a quarter of what the session has used (10, 25 and
       50 turns after 40), so a session that burned 40 turns is never offered 5.
     - **Three scopes, one list.** *This run* raises the limit for the turn in flight and
       gives back what the turn did not use at `turn_ended` or `agent_done`, folded from
       those events as well as applied live, so the next turn — a loop's next iteration
       — meets the checkpoint again; that is what makes it differ from *this session*,
       which keeps the raise and asks again when it is spent. *No limit this session* is
       the old `always`, kept as its own clearly worded choice. *This workspace* keeps
       the raise for the session and writes `max_<x>: <new limit>` to the workspace's
       `.troupe/config.yaml` through `Config.write_key/3` — `Migrate.write/2`, the writer
       every settings screen has used since #122 — and names the file in the answer
       (`path`); the file is rendered again, so its comments go to the `.previous` copy
       beside it, and a file that is not YAML is left alone and the answer says so. A
       bare amount is for the session: a person who types `50` means fifty more, not
       fifty more for this turn and the question again. A fourth scope, this machine, is
       not offered; the list is eight options long already, and the user file is the
       settings screen's.
     - **An answer that cannot be read is asked back**, under the next id, with the
       reason first (`decision: unclear`, `note`): a typo must not stop a session, and a
       silent stop was the bug. The old words keep their meaning — `allow` buys the first
       slice again, `always` lifts, `deny` stops — so a client from before this still
       answers.
     - **The words.** The question names the limit, says it is a safety net against
       runaway loops and runaway spend, what the session has used and spent in money
       (the index's running cost, where every priced response lands) and what the middle
       step would cost at the session's own rate — spend so far over units used, the one
       rate that needs no price list — and each option carries its own estimate. Calm: a
       checkpoint, not an error.
     - **On a pod** the worker hands the limits the terms set to the config as `terms`,
       and the gate offers a raise only inside them, refuses one past them with the
       reason, and offers no workspace scope: a pod's limits are the terms and the
       profile, in the plane. `budget_asks: false` still asks nothing at all, and every
       session the plane places has it, so this holds for the day the terms let one ask.
     - **`/loop`.** "This run" means this iteration, and the question says so; a loop
       still stops at the question (Decision 679). A cap of the loop's own that the same
       question could raise is not designed here.
     - **Not done:** a comment-preserving scalar edit (`Yaml.edit_list/4` covers lists
       only), and a "this machine" scope.
     - **Proof:** `Troupe.Agent.BudgetAnswerTest` — the parser in every spelling and
       unit, the steps, the options and their round trip, the pod's ceiling, the words;
       `Troupe.Agent.BudgetQuestionTest` — `50`, `+50`, `50 turns`, `+50k tokens` and
       `+15 min` continue a session, nonsense is asked back, a run's raise is given back
       and a session's kept, the raise survives a restart, the workspace file is written
       and the next session there starts with it, a pod's terms cap and refuse;
       `Troupe.BudgetTest` — extend and reclaim; `Troupe.Config.WriteKeyTest`. The
       clients: TUI Decision 120, and the GUI's transcript test.

700. **A person's own MCP servers and skills live in two layers beside `config.yaml`,
     import from the files other tools keep, and a workspace's servers run only once
     somebody attached has said so.** Issue #60, the local half. What was there: `mcp:`
     in `config.yaml` (654), read from a project's file only in a trusted workspace
     (686), and skills read from the pinned bundle alone. What a person has is a
     `.mcp.json` from Claude Code, Cursor, Claude Desktop or VS Code and a
     `~/.claude/skills`, and bringing them in meant retyping them into YAML.
     - **Layers.** `<config>/mcp.json` and `<config>/skills/` for the user,
       `.troupe/mcp.json` and `.troupe/skills/` for the workspace: the `mcpServers`
       shape every other tool reads and writes, plus an `include` list that reads
       another file in place — a *link*; `skills.json` does the same for directories of
       skills. They stack over `config.yaml`'s `mcp:` as the config files stack (686):
       merged by name, key by key, the workspace's over the user's, `null` removing and a
       list replacing, so `{"disabled": true}` alone turns a lower layer's server off.
       Each server and skill carries its layer and its file, since that is what a person
       needs to know to change it (`Troupe.MCP.Local`, `Troupe.Skills.Local`).
     - **Import.** `Troupe.MCP.Import` reads the four shapes: `${VAR}` and `${env:VAR}`
       become `{env:VAR}`, which the loader refuses when unset instead of sending an
       empty string; a VS Code `${input:…}` skips that server and says so, since only VS
       Code could fill it in; `headers` are dropped with a warning, a credential this
       slice does not carry. `mcp.add` with `from` copies, or links; `skills.add` copies
       a directory of `SKILL.md`s or one skill's directory, or links it.
     - **Trust.** A `.troupe/mcp.json` arrives with a clone. Its servers start only after
       the session's question, through `Troupe.Session.Questions` under
       `mcp-trust-<hash>`, so any client that answers an `ask_user` answers this; `deny`
       is the first option, so a runner with nobody to ask runs nothing. `allow` is
       remembered in `<state>/mcp-trust.json` per checkout (`Troupe.MCP.Trust`), beside a
       fingerprint of the command, its arguments, environment, directory or URL, so a
       changed command is a new question and a re-ordered file is not; `once` runs them
       for the session; `deny` leaves them stopped until the next session or a reload.
       A workspace on `trusted_workspaces` is not asked, since trusting it already lets
       its `config.yaml` name what runs; the user's layer asks nothing, since the person
       wrote it. A pod session reads no layer at all, and `managed_mcp_servers_only`
       starts nothing local and says so in each server's status.
     - **Skills.** A bundle's skills stay gated by the profile's `skills:` list and the
       team's entitlements; a person's own are offered to every agent of the session,
       because the person put them there and a skill nobody can call is not one. They
       are read beside the workspace wherever the session runs, as `.troupe/agents/` is.
       A local skill's files are listed by their path, and the user's directory and every
       linked root are read roots of the session.
     - **Protocol.** `mcp.list`, `mcp.add`, `mcp.remove`, `mcp.check` and `skills.list`,
       `skills.add`, `skills.remove`, the daemon's only like `config.*`; `mcp.status`
       gains `layer` and `source`. `mcp.check` on a session's server reads its files
       again and starts what they say now — reconnect, enable and disable in one verb —
       and on a server not in a session runs it once and stops it. `mcp.list` with a
       `session_id` joins the live state onto the listing, so one call fills a page. Env
       values never go over the wire: `mcp.list` and `mcp.add` answer with the names.
     - **Out of this slice**, and said in the pull request: streamable HTTP and SSE with
       OAuth for remote servers, and keychain storage for their tokens. A `url` server
       stays the one-shot HTTP client 654 gave it.
     - **Proof:** `Troupe.MCP.ImportTest` (the four shapes, placeholders, skips),
       `Troupe.MCP.LocalTest` (layering, links, merging, writes, the trust store),
       `Troupe.Skills.LocalTest` (both layers, copy and link, the tool and the prompt),
       `Troupe.MCPLocalTest` (the question and each answer, a trusted workspace,
       `managed_mcp_servers_only`, reload), `Troupe.MCPLayersTest` (the user's layer and
       the read roots), `Troupe.Gateway.LocalSourcesTest` (the seven methods over the
       daemon's socket, and none without the daemon), the TUI's `Troupe.MCPPageTest` and
       the GUI's `local-sources.test.ts` and `servers-panel.test.tsx`.

702. **The GUI's design is Afterglow: its type, spacing and square corners in every
     theme, its palette as the default, and the three earlier palettes kept on the same
     contract.** Issue #52, part 1 of 2: the tokens, the shell, the session list and
     sign-in. The comp (`clients/gui/docs/design/afterglow.dc.html`) is a redesign, not a
     palette: Figtree at black weights, DM Mono labels in capitals, the VT323 screen face
     for a `// SECTION` label, radii of zero, a spacing scale of its own, a hard offset
     shadow under tiles. The token pipeline already emitted structure once, from the
     default theme's file, so the structure is now Afterglow's for every theme, and
     `pnpm tokens` refuses a theme file whose copy of it differs.
     - **Kept, not dropped.** Signal, Footlight and Limelight stay selectable. Whether
       they survive is a product question the issue does not settle, and the appearance
       screen, which is part 2, is where it would be answered; keeping them costs six
       colour names in three files and nothing in a component, and dropping one later
       is a file delete and a list entry.
     - **The contract grew, once.** `text.body`, `text.label`, `bg.shadow`, `accent`,
       `status.running.solid` and `status.local` are what the comp needed and the
       contract lacked. Every theme answers them; the older three answer with values
       they already had (the link blue for `accent`, the stage for the shadow, the
       neutral of `queued` for `local`). Nothing was renamed, so every variable a
       component reads today still resolves, in every theme.
     - **The reserved colour is also the brand, in Afterglow only.** Pink marks
       `waiting` and, through `--accent` and `--link`, the mask's lit half, links and
       the current nav item; the comp does this, and the rule that a component reaches
       for `--waiting-*` only for a waiting state holds. The other three keep their
       reserved colour for waiting alone.
     - **Two values moved from the comp.** `text.muted`, the comp's grey-deep at 3.7:1
       on the void, is lifted to clear the 4.5:1 floor every theme is held to; and
       `queued` is grey rather than the comp's amber, because the list's idle sessions
       read as queued and three amber rows would fight the pink. The light mode is
       derived — the comp is dark only — by inverting the ground to cream and darkening
       every accent until it clears the same floor.
     - **Generated, not typed.** `afterglow.tokens.json` carries both modes; the type
       roles are emitted as `--t-<role>` shorthands and the tracking as
       `--tracking-<role>`, so no size or weight is typed into the stylesheet.
     - **Proof:** `pnpm tokens:check`, the GUI's typecheck, its test suites unchanged
       and passing, the desktop build, and the app against `pnpm fake` in a browser:
       the shell, the list and sign-in, light and dark, at 1280px and at 380px, on the
       pull request.

703. **The desktop app's icons are generated from the mask, in one fixed cut, and CI
     fails when the committed set is not what the design file says.** Issue #159. Every
     file in `clients/gui/apps/desktop/src-tauri/icons/` was an older three-dot mark, so
     the app wore the brand inside its window and something else on the dock, the
     taskbar, the Start menu, in Alt-Tab and in the installer. `pnpm icons`
     (`clients/gui/scripts/icons.ts`) now draws the whole set from `mark.ts`, the
     constant `views/brand.tsx` draws the mask from, which `pnpm tokens` generates out of
     the design file, and from the design file's colours; `pnpm icons:check` runs in CI
     after `tokens:check`.
     - **One cut, dark.** In the app the mask follows the theme; an icon is one image.
       It bakes Signal in dark, as `public/favicon.svg` does: the tile is `bg.sunken`
       `#0B0D10`, the edge and the open eye `text.primary` `#ECEFF3`, the lit half
       `status.waiting.solid` `#FF5CB8` (the reserved colour, meaning here what it means
       everywhere), the eye cut out of it `text.inverse` `#0A0B0D`. A dark tile reads on
       a light dock and on a dark one; a light tile vanishes into a light one.
     - **Per size.** `brand.tsx`'s rules, on the size the mark's 48-unit frame is drawn
       at: stroke `lg` from 40px, `md` from 24px, `sm` below; the seam line dropped below
       32px so the colour change is the seam; bars for eyes below 24px. Inside the tile
       the mark sits at 0.86 of its frame, the favicon's cut, with the stroke at full
       weight. The tile is the favicon's, 44 of 48 with corners of 7, on Windows, Linux
       and the Store tiles; macOS draws no shape around an icon and expects Apple's, so
       `icon.icns` is 824 of 1024 with corners of 22.37%, at every size and scale the
       dock reads.
     - **Around the app.** The NSIS installer and uninstaller carry the app icon, a
       150 x 57 header with the tile and a 164 x 314 sidebar with the mark on the dark
       stage; the disk image has a 660 x 400 background with an arrow from the app to
       Applications, on Signal's light canvas, because Finder draws a window that has a
       background picture as light with dark labels whatever the appearance; `icon.png`
       (512) heads `bundle.icon` because Tauri takes the first PNG there as the Linux
       window icon, and it was the 32px one. `publisher` is "The Troupe contributors",
       as NOTICE says; `copyright` already was.
     - **Pure Node, pixels compared.** No image library and no network: the mark is a
       few quadratic curves, rasterised by a scanline pass with sixteen sub-rows per
       pixel and exact horizontal coverage, and PNG, ICO, ICNS and BMP are written by
       hand. Curves are flattened with polynomials only, so the pixels are the same on
       every machine; the check decodes what is committed and compares pixels rather
       than bytes, because two zlibs compress one image differently and the icon is the
       pixels.
     - **Not done.** `troupe.exe`, the TUI Burrito wraps, has no resource section at all:
       Windows shows the generic executable icon. Burrito's `build.zig` builds the
       wrapper with `addExecutable` and takes no Win32 resource file, so an icon needs
       Burrito to accept one (`addWin32ResourceFile`, upstream or in a fork) or a
       post-build edit of the executable's resources before it is signed. A follow-up.

704. **Every screen of the GUI is drawn in Afterglow, the launcher and the full-screen
     "new session" with them; a session doing nothing is `idle`, its own status with no
     colour, so `queued` can be the comp's amber.** Issue #52, part 2 of 2, on the tokens
     702 laid down. The session view (transcript, tool calls, the agent's and the
     harness's questions, approvals), the inbox, review, This computer with its models
     and servers panels, appearance and the command palette are restyled to the comp;
     the two screens the comp has that neither part listed are built. Nothing behaves
     differently: the same protocol calls, the same words on the buttons.
     - **The launcher is behind the lockup, not the first screen.** The comp opens on
       it; the app still opens on the one list, because the list is the whole idea
       (Sessions.tsx says so) and the app's tests and habits are built on it. The lockup
       in the rail opens the launcher — three tiles (new, open, what needs you), the
       three most recent rows, what this machine is — and every tile leads back in.
       Opening on it instead is one line in `App.tsx`, if the product wants it. (709
       reverses this: the app opens on the launcher, and a person may choose the list.)
     - **Casting a troupe is a screen, not a dialog.** `StartSession` moved out of the
       list into the shell (`where.screen === "new"`), as the comp draws it: where it
       runs as two tiles, then the questions that follow from the answer. The list's
       button and the launcher's tile both come here; the fields and the calls are the
       ones the dialog made.
     - **Idle is not a colour.** `statusOf` mapped an idle session to `queued`, which
       forced 702 to make the queued pill grey. Idle is now a status of its own — an
       open, empty eye, the chrome's label grey on a strong rule, the comp's STOPPED —
       with no token, because doing nothing is the absence of a state; and `queued`
       takes the comp's amber for a message held while the troupe works. A session
       whose only open question is the workspace's trust question, asked at its start,
       reads as waiting like any other, and a test says so.
     - **The structure grew, once more, and every theme carries the copy.** Three type
       roles the comp needed and 702 left without a token — `tile` (26px/900), `name`
       (14px/800, the byline) and `note` (14px/400) — a `border.edge` of 2px for a
       message's left edge, and `size.markDisplay` for the launcher's mask, in all four
       files, so `pnpm tokens` still finds them identical. No colour token was added.
     - **Two comp values were not taken.** The in-progress task is lit in the
       machine's cyan, not the comp's pink: pink marks a person's decision and nothing
       else, which 702 held to and this holds to. The `ag-scan` keyframe is defined in
       the comp and used by nothing in it.
     - **Room left.** The session head's subject column stacks the breadcrumb and the
       title and is where the next wave's goal line, loop controls and "while you were
       away" marker go.
     - **Proof:** `pnpm tokens:check`, `icons:check`, the GUI's typecheck, its test
       suites (the app's grew from 13 to 18: `statusOf`, the trust question, the
       launcher), the desktop build, and every screen against `pnpm fake` and the
       client's fake daemon in a browser, light and dark, at 1280px and 380px, on the
       pull request.

705. **A first run's questions are one state machine in the harness, asked over the
     protocol, so both clients ask the same things and a run done in one is done in
     the other.** Issue #76's second slice: a person with a fresh machine and one API
     key reaches a first working session in the desktop app without opening the docs,
     and the terminal client does not ask again. `Troupe.Setup` is the flow — `where`
     (this machine or a plane), `provider` (Anthropic, OpenAI, a gateway or a LiteLLM
     proxy by URL; or opencode's providers and a `config.yaml` that works, detected and
     offered), `key` (pasted, or kept as `{env:VAR}`), `models`, `workspace` with the
     approval model in two sentences, `finish` — and `Troupe.Gateway.Setup` holds one
     in progress behind `setup.get` and `setup.answer`, the daemon's only, like
     `config.*`. The choices that could have gone another way:
     - **The key is checked with a real request before anything is written**: the
       provider's model listing, which every provider authenticates and which also
       fills the models step. A refused key keeps the step; a provider that answers
       but will not list (a gateway with no listing) is `unknown` and the person goes
       on and types a model id, since a working gateway is not a wrong key. Everything
       is written as late as the answer is complete — the settings at `models`,
       `auto_approve` at `workspace` — through `Troupe.Config.ModelSettings` and
       `Troupe.Config.write_key/3`, into the user's `config.yaml` and never a
       repository's `.troupe/`. The fake provider takes part (`ModelSettings` now
       accepts it), so a packaged build's first run is driven to a written file with
       no model behind it.
     - **No keychain.** The daemon has no keychain module — the plane's refresh tokens
       are the plane's — so the key goes into `config.yaml`, readable by the user alone
       on Unix, and the flow says so (`key_storage`) rather than pretending. A keychain
       is a later slice.
     - **Completion is a record in the state directory** (`<state>/setup.json`, beside
       `identity.json`), not a config key: the settings file is what was set up, and
       the record is that somebody finished, including a person who chose a plane and
       wrote no settings. `needed` is the absence of all three (the record, a
       `config.yaml`, a model that can be asked), which is what the desktop app asks
       before showing the questions and the terminal client asks before its own
       (`setup.get`; a daemon without the method still gets the old questions).
     - **`finish` starts the first session on the daemon**, as `session.create` would
       under the caller, with a prompt suited to the directory — a repository is asked
       to explain itself — so the flow ends on a session and not on a settings screen.
     - **`troupe doctor` is `Troupe.Doctor` in the harness**, printed by both programs:
       config, provider, key (the same live check), key storage, daemon, both binaries
       on the PATH, and every plane the caller knows of, one line each, `FAIL` making
       the exit status 1. It is not a session command, so it is not in
       `Troupe.Commands`.
     - **Out of this slice:** the daemon at login (launchd, systemd, Task Scheduler),
       the full-screen terminal flow (`troupe setup`; `troupe config`'s questions
       stay), a plane pushing a recommended setup, and the keychain.
     Proof: `apps/troupe_core/test/troupe/setup_test.exs` (every path, a refused and
     an accepted key against a socket, the reference written for an environment key,
     the suggestion), `doctor_test.exs`, `apps/troupe_gateway/test/troupe/gateway/setup_test.exs`
     (over the socket to a session, the key never in an answer, a worker without the
     methods), the desktop app's `test/onboarding.test.tsx`, and the terminal client's
     `config_setup_test.exs` ("a first run done in the desktop app means no questions
     here").

706. **A repository's own instruction files are read into every prompt, from disk at
     every turn, in the order the other tools read them, and one table says what got
     in.** Issue #123, its first slice. `AGENTS.md` is the file the tools settled on,
     and a repository that has one has told agents how to work in it; Troupe read none
     of it. The only mention was the librarian's prompt, which told that one agent to
     fold `AGENTS.md` into the brief, so a repository's rules reached a session only as
     a cheap model's paraphrase, only if somebody ran the librarian, and an edit changed
     nothing until the brief was rebuilt. `Troupe.Instructions` now reads them: the
     person's own `<config>/AGENTS.md`, the repository root's (the nearest directory
     with a `.git`, so a worktree reads its own checkout's), one in each directory
     between the root and the workspace, and the brief last. Every file applies and the
     nearer comes later in the prompt, which is how "the nearest wins" is put to a
     model. In one directory `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and
     `.github/copilot-instructions.md` are the same file under other tools' names: the
     first that exists is read, the rest are named as skipped.
     - **Read every turn, cached by digest.** The agent reads the files before every
       model call and keeps a digest of what it read; an `instructions_loaded` event is
       written when the digest changed since its last turn and never otherwise. So an
       edit reaches the next turn, the log says which files each turn was read from,
       and a quiet log means the same files again. Not distilled once by the librarian,
       whose prompt still folds the same files into the brief — a follow-up stops it.
     - **One budget, the nearest whole first.** `instructions_max_chars` (16,000) is
       shared by the instruction files; the nearest takes what it needs first, and a
       file the remainder cannot hold is cut where the prompt says so, or left out with
       a line saying so. The brief keeps `memory_max_chars`. Never a silent drop.
     - **Provenance is a method.** `context.get` (`observe`, a session method a worker
       answers too) lists every file the next prompt is read from — scope, path, size,
       characters that got in, budget, share, status, what was cut, what was skipped,
       hash — read from disk when asked, as the next turn will read it, so it says what
       an edit will do; a past turn's read is its event. `/context` in the TUI prints
       it (TUI Decision 124). Nothing reaches the prompt from a file without appearing
       there: the loader that answers the method is the loader that builds the prompt.
     - **Not in this slice.** `.cursor/rules` globs, `@path` imports, a nested
       `AGENTS.md` below the workspace (attached per file, the same mechanism as the
       globs), the wider opencode and Claude Code imports, the linter, proposed edits
       to `AGENTS.md`, the organisation layer, `troupe init`, command verification, and
       a GUI view of the provenance.
     - **Proof:** `Troupe.InstructionsTest` (order, aliases and what is skipped, the
       budget with the nearest whole first, the root without and with a `.git` file,
       the digest), `Troupe.InstructionsPromptTest` (a repository with only an
       `AGENTS.md` and no Troupe setup reaches the prompt, an edit reaches the next
       turn, one event per change and none for a turn that read the same, the person's
       own file first and the brief last, the prompt names exactly what the provenance
       lists), `Troupe.Gateway.ContextTest`, and the installed build on a scratch
       repository, on the pull request.

707. **A session somebody is reading is never put to sleep, a call to a client's own tool
     outlives the connection that was serving it for a grace, and a session's row says
     what happened while nobody was reading it.** Issue #119, the daemon's last three
     parts after 140's sleeping. What was there: a subscribed client kept its session on
     a thirty-minute clock and then had it stopped underneath them; a client that dropped
     mid-call had the call failed at once with a bare `disconnected`, its tool gone; and
     a person who came back had no way to tell, short of a replay, that a turn had ended
     or a question been asked while they were gone.
     - **Read means subscribed by name.** `Troupe.Events.attach/1` is registered by the
       gateway for a subscription that names the session, `session:<id>` or
       `presence:<id>`, and taken back when the last one on that connection goes, so
       "somebody is reading this" is narrower than "somebody follows
       it" (`watched?/1`): a `fleet` subscriber and a worker's uplink follow every session
       and read none. The index skips an attached session on both clocks and restarts
       them from the sweep after the reader leaves; the watched clock (30 min) still
       covers the followers, and nothing changed for a pod, whose uplink is a follower
       and whose manager keeps its own dormancy.
     - **The call is parked in the registry, not the connection.** The connection still
       answers its in-flight `tool.invoke`s with `disconnected` on the way out — it is the
       only process that can unblock the task — and the task then asks `ClientTools` to
       wait for the tool by name (`await/4`), for the grace or for what is left of the
       call's own timeout, whichever is shorter, so the whole thing stays inside that
       timeout and a dropped laptop is never a hung turn. A client that registers the
       tool again, through a fresh consent as it always must, is asked the same call: same
       id, same arguments, over its own connection. Nobody inside the grace, and the call
       fails once, naming the tool and saying its client left. `TROUPE_CLIENT_TOOL_GRACE_SECONDS`
       (60; `0` fails at once) sits on the ladder in the daemon's README with the other
       clocks, which the three modules that keep them now point to instead of restating.
     - **`unseen` is a mark beside the log, not an event in it.** `seen` holds the head
       `seq` as of the last moment a client was attached, written on attach and on
       detach; the row counts the root agent's `turn_ended`s and its distinct
       `approval_requested`s and `question_asked`s after it, with `since`, and is empty
       while a client is attached or when no mark exists — which is also what keeps every
       session from before this from lighting up at once. A reader's progress is not
       something the session did, reading a dormant session must not write to a log it
       has not opened, and a mark in the log would reach every other subscriber as an
       event about somebody else's screen. Cleared by a subscription, never by a listing,
       so an inbox refreshes without losing its markers. The row is the contract for the
       desktop app's notification and marker; the events keep their shape.

708. **The desktop app shows a session's goal and its loop in the session's head, marks
     what happened while nobody was reading, and says it with the operating system's
     notification.** Issues #59 (the GUI's part) and #119 (its "tell the person" box).
     The harness had `/goal`, `/loop` and `unseen`, and the terminal client showed the
     first two; the desktop app dropped `goal_*` and `loop_*` on the floor, printed a
     loop's own input as the person's words, and read no `unseen`.
     - **What the events say, in the head.** The fold keeps the goal from `goal_set`
       until `goal_cleared` and the latest loop from `loop_started` to `loop_stopped`,
       so the head follows any client's change as it happens. The goal sits under the
       title on one line, whole on hover and on a click; the loop sits beside the status,
       "iteration 2/5", with a stop that works mid-iteration. A loop's turn is a note,
       "loop iteration 2/5", not the words the loop gave the model, as in the terminal
       client. `session.loop.get` is asked once per attachment for the one case the log
       cannot say yet: a session that stopped mid-loop writes `interrupted` only when it
       wakes. A refusal is said in words, not as `conflict (-32006)`.
     - **`unseen` is read at the door.** Opening a session subscribes to it, which is
       what clears it, so the line at the top ("while you were away: 2 turns finished,
       1 question waiting since 14:02") is the row as the list last showed it, kept for
       the visit until it is seen or answered. A request is `waiting` while the row still
       has one of its kind open and `asked` once it ended. The list marks a row with how
       many things, and the row the person opens loses its mark at once.
     - **Notifications are the OS's, through the notification plugin.** A Tauri build of
       this app on Windows, at its own origin, answers `Notification.requestPermission()`
       with `denied` and never prompts, and `new Notification()` fires `error`: WebView2
       refuses the permission unless the host answers its `PermissionRequested`, and wry
       answers only the clipboard's. So `tauri-plugin-notification`, pinned to 2.4
       because 2.5 wants tauri 2.12, is reached through the shell contract, and a browser
       uses its own. The capability grants three verbs: whether it is allowed, ask, show.
     - **When, and once.** News comes two ways and each is the only one for its case: a
       session nobody reads is told by its row's counts going up, whether or not the
       window is in front, since nothing on screen shows it; a session this window reads
       has an empty `unseen`, so its own events speak, after the replay and only while
       the window is not in front, and a loop's turns stay quiet until the loop ends.
       Counts are remembered per session and a request by its call id, which a waking
       session asks again under. Permission is asked once, on the person's first
       gesture, a refusal is kept, and a preference beside the appearance turns it off.
     - **Not in this slice.** A plane's rows carry no `unseen`, so a team session tells
       only while it is open; clicking a notification does not open its session, which
       the plugin cannot report on a desktop; and the launcher's rows carry no marker.
       (Both are 714.)
     - **Proof:** the desktop app's `goal-loop`, `away` and `notify` tests against the
       fake daemon, which now keeps the loop in its log and `unseen` beside it; the
       client's fold and row tests; the probe and the renamed installed build on the pull
       request.

709. **The desktop app opens on the launcher, and a person who would rather start on the
     list says so once.** Issue #52, amending 704, which built the launcher and kept the
     list as the first screen; the comp opens on the launcher, and so does the app now.
     - **The choice is at the foot of the screen it is about.** "Skip this screen when
       Troupe starts" is a checkbox in the launcher's footer, where the comp keeps its
       shortcuts, and from the next start the app opens on the list. It moves nothing
       now: the preference is read once, when the app starts. The lockup in the rail
       still opens the launcher from anywhere, with the box ticked.
     - **Turned back beside the appearance.** A person who skipped the launcher no longer
       meets its checkbox, so the same preference is on the Appearance screen under the
       notifications, as two cards — Home, the lockup's own name for the launcher, or
       Sessions. It is kept where the theme and the notifications are, as `start` in the
       app's preferences on this computer.
     - **A first run is not a start.** On a fresh machine the first run's questions (705)
       end where they did, on the session they started or on the list, and the launcher
       comes on the starts after. Sign-in, and the theme a first sign-in asks for, still
       come before it.
     - **The app's tests say which screen they start on.** The suites that open a session
       from the list start where a person who chose the list starts (`startOnTheList` in
       the desktop app's `test/support.ts`); `launcher.test.tsx` is the one about the
       first screen, and the local-only test passes through the launcher on its way to
       every other screen.
     - **Proof:** `launcher.test.tsx` (the launcher first; the box ticked and a restart on
       the list, the lockup still reaching the launcher, the box unticked and the launcher
       back; Appearance both ways; a first run ending on the list and the launcher at the
       next start), the first-run test's relaunch now on the launcher, the GUI's
       typecheck and test suites, the desktop build, `tokens:check`, `icons:check`, and
       the app against a fake daemon in a headless browser, light and dark, at 1280px and
       380px, on the pull request.

710. **The desktop app keeps its sign-in under its own bundle identifier.** Issue #224,
     defects D33. `secrets.rs` named every credential-store entry with a fixed service,
     `com.objective-mj.troupe`, so a build made with another identifier, as a test build
     installed beside the real app is, read and wrote the real app's refresh token: in
     plane mode it would restore that sign-in and could rotate it, signing the real app
     out. The service is now the running build's `identifier`, from its Tauri config,
     which `tauri build --config` sets.
     - **No migration.** The shipped identifier is the string the fixed name was, so an
       upgrade finds its sign-in where it left it, and a renamed build starts with none. A
       test in `secrets.rs` reads `tauri.conf.json` and fails if the identifier changes,
       because then the old entry has to be moved first.
     - **Proof:** the two tests in `secrets.rs`; a renamed build (identifier
       `com.objective-mj.troupe.fix224`) installed from the chunk's tip wrote a dummy key
       under `com.objective-mj.troupe`, and the same build with this change wrote,
       read and cleared it under its own identifier and did not see or touch the entry
       under the real app's name, by Credential Manager's target names and write times.

711. **A setting saved from a client changes its own line of `config.yaml` and nothing
     else; the file is edited, not rewritten.** Issue #223 (defects D28), amending 675,
     686 and 699, which each wrote a file by rendering its map again, so the first model
     picked in the desktop app, the first value changed on the terminal UI's settings
     page or the first budget raised for a workspace turned a hand-written, commented
     file into a machine-written one.
     - **One edit, in `Troupe.Config.Yaml`.** `edit/2` makes a file's text read as a new
       map key by key: a changed scalar takes the old value's place on its key's line,
       which keeps the key as it is spelled and the comment after it; a key that is not
       there is added after the last key of its map, a missing parent with it; a key
       that is gone goes with the lines beneath it; a map written one key a line is
       edited key by key, and any other map or list that changes is written out again
       under its key. `put/3` sets one key, nested or not, through it. A string goes bare
       when YAML reads it back as the same string, and would under YAML 1.1 too, and in
       double quotes when it needs them or was quoted before. The answer is read back
       and must be exactly the map asked for, as with `edit_list/4` (686), which stays
       what `troupe config trust` uses.
     - **Every writer gets it through `Migrate.write/2`.** The terminal UI's settings
       page, `config.set` (the desktop app's model settings, and a first run's), a
       budget answer for the workspace (`Config.write_key/3`), `config.import` and a first
       run's approvals all write through it, so none of them changed. A file that is
       there is edited; a new file, or one the edit cannot follow — a value an alias
       shares, a key written twice, a document in braces — is written whole as before,
       with `version: 1` and the header, whose words no longer say comments are lost. The
       file before the save is kept as `.previous` either way.
     - **The keys a writer sets are written in the new spellings; the others are the
       file's.** 686 had every writer write the new spellings only, which a whole-file
       write did for every key in it. An edit writes what the writer brings by its new
       name and removes that setting's old spellings, and leaves an old spelling of a
       setting it did not touch as it is, with its load warning, for `troupe config
       migrate --write`, the one rewrite, which is asked for and shows its diff first.
       An edited file gets no `version` line it did not have: a missing one reads as 1.
     - **Not done:** `troupe config migrate --write` still renders the file, since a
       migration moves keys between blocks; and a string with a space or a letter
       outside ASCII is quoted, though YAML would take some of them bare.
     - **Proof:** `Troupe.Config.YamlTest` (one key written is one line changed, nested,
       added under its parent and with a missing parent, quoting, a key with only a
       comment, a map in braces, line endings and a byte order mark, a key of the same
       name elsewhere, removal with the lines beneath, `{}` and new maps and lists);
       `Troupe.Config.WriteKeyTest`, `Troupe.Config.ModelSettingsTest` and the terminal
       UI's `Troupe.SettingsTest`, each keeping a comment and changing one line;
       `Troupe.Agent.BudgetQuestionTest`'s workspace answer; `Troupe.Config.ExplainTest`
       for a new file and an edited one; and `config.set` over the installed daemon's
       socket on a commented file, the diff that one line.

713. **A librarian's try at the brief is recorded when it starts, and one that built
     nothing holds off the next automatic refresh for `memory_max_age_days`.** Amends
     696, which left a run that failed, was cancelled or ran out of budget to be tried
     again by the next session: with `memory_auto_refresh` that was every new session
     until one got through, and in a repository whose librarian writes nothing and has
     no brief to stamp, every session for good, each paying for it (defects D24).
     - **The try is the start.** A `librarian` agent given something to do records the
       time before it asks a model anything (`Troupe.Session.Memory.attempted/3`), so a
       run that crashes, is closed with its session or is still going when the next
       session opens counts as well as one that failed. It is kept in the state
       directory, `librarian.json`, filed under the brief's path, never in the
       repository.
     - **The daemon says whether a refresh is due.** `memory.get` answers `refresh_due`:
       the brief is `absent` or `stale`, and no librarian has started on it in the last
       `memory_max_age_days` without its being built since. A try the brief was built
       after holds nothing off, so a brief a librarian stamped that went stale because
       the repository grew is refreshed at once, as before. `status` is unchanged, so
       `/memory` still says what the brief is. `memory.forget` forgets the try with the
       brief, so a person who clears it gets a new one at the next session. The TUI
       starts its librarian only when the refresh is due (TUI Decision 127);
       `/memory refresh` is a person asking and is never held off.
     - **The librarian stops copying the instruction files.** Decision 706 put
       `AGENTS.md` and its aliases into every prompt ahead of the brief and left the
       librarian's prompt folding them into the brief. It now reads them to leave out
       what they say, and describes the brief as Troupe's own notes on the repository.
     - **Proof:** `Troupe.Tools.RememberTest` (a librarian whose request failed, and one
       that wrote nothing where there was no brief, each leave the refresh not due; the
       hold's length, a build after the try, and `forget`), `Troupe.Gateway.MemoryTest`
       (`refresh_due` over the wire), and the TUI's `Troupe.MemoryClientTest` (a session
       after a failed librarian starts none), which failed on the chunk's tip; and the
       installed build, where three sessions on a repository whose librarian fails start
       it once, on the pull request.

714. **A desktop notification leads back to its session, the launcher marks what was
     missed, and a first run's plane is signed in to without being asked for again.**
     Issues #119 and #76, following 708, 705 and 709, with D26's GUI half.
     - **The click where it is reported, the window coming back where it is not.** A
       browser's `Notification` reports a click: it brings the window forward and opens
       the session. `tauri-plugin-notification` does not on a desktop, in 2.4 or 2.5: it
       shows the toast through notify-rust in a task of its own and drops the handle
       whose `wait_for_response` would hear the click, and its `onAction` listens on a
       channel only the phone plugins feed. So in the shell, the window coming to the
       front within 15 seconds of a notification said while it was not is taken as the
       answer to it, however it came forward, and opens the session the last one was
       about. Windows itself can report the click, through the toast's own `Activated`
       event, but only for a toast the shell shows itself rather than the plugin, which
       it now does (730).
     - **The launcher's recent rows carry the list's marker**, "2 new" with the sentence
       behind it, from one component the two screens share.
     - **The plane's address is asked once.** A first run that chose a plane and was
       given its address ends on the sign-in screen signing in to it: the field is
       filled, and the provider's page or its code comes next, unless the store already
       holds a sign-in for it. An address kept from an earlier sign-in only fills the
       field, since signing out is not a request to be signed in again.
     - **Signing back in is a start.** After signing out, the next sign-in in the same
       run lands on the launcher, or on the list for a person who chose it (709).
     - **A session is finished when its root agent is.** A subagent's `agent_done`, and
       one a restore ended `interrupted`, is its own agent's state and a note in the
       transcript, not "Finished" in the session's head (D26).
     - **A dropped socket reopens a team session in `read` mode.** `SessionAttachment`
       opens in the mode it is asked for, reconnects in `read` as PROTOCOL.md §6 says,
       and follows a pod's `not_found` for an activating command in `activate`. Since
       707 a subscribed session is never put to sleep, and the reconnection's backoff
       (about 19 seconds) ends well inside the two-minute unwatched clock, so a session
       no longer falls asleep on its own while a view is attached; what reconnecting in
       `activate` still did was place again, at once, a session that a drain or a
       replaced pod had left asleep. A session on this computer never went through the
       plane and wakes for nothing a subscription does.
     - **A local view is listened to before it subscribes.** `DaemonClient.open` takes
       the caller's listener and attaches it before `subscribe` is sent, and `close`
       takes it off again. A replay can arrive in the same read as the subscription's
       answer, before `open` resolves; a screen that listened once it had the view saw
       no history in Node, and in a browser only because each message is a task of its
       own.
     - **Proof:** the desktop app's `notify` (a click, the window back soon after, and
       too late), `launcher` (the marker, and gone once read), `signin` (a first run's
       plane signed in to with nothing pressed, a kept address that waits, and sign-out
       and back to the launcher or the list) and `history` (a seeded session's replay)
       tests; the client's fold, `move` and `stage2` tests; the command palette's with
       `/loop` in the fakes' table; and the renamed desktop build installed from its
       setup, on the pull request.

716. **The design tokens are one set of files, the GUI's; the plane's front page and the
     TUI are generated from them, and the front page stays in Signal.** Issue #228,
     defect D30. `docs/design/themes/` was a copy of `clients/gui/docs/design/themes/`
     from before Afterglow: three themes on the old structure, with the kits and
     `support.js` byte for byte the same. It is gone, and `mix troupe.theme` reads the
     GUI's directory.
     - **One copy rather than a checked one.** The GUI's image builds with `clients/gui`
       as its only context, so the files stay where `pnpm tokens` finds them; nothing
       else needs them anywhere else, since the plane's image copies no `docs/` and
       `theme.css` is committed. A generated copy with a check that fails on drift would
       have worked too; a file that exists once cannot drift at all.
     - **The front page keeps Signal's colours and takes the shared structure.**
       Graphite, cyan for the machine, magenta on the mask and the approval figure and
       nowhere else. Afterglow spends its pink on links and the accent (702), which is
       exactly what the front page's rule and `front_page_assets_test.exs` forbid, so
       moving it to Afterglow is a change to that rule and not to this file; the one
       line is `@default_theme`. What changes is what every theme has carried since 702:
       Figtree and DM Mono (the page's webfont link follows), black-weight headings,
       square corners, Afterglow's spacing.
     - **Three generators, three checks.** `pnpm tokens:check` (the GUI), `mix
       troupe.theme --check` (the front page) and `mix troupe.palette --check` in
       `clients/tui` (TUI Decision 126), and CI's path filters send a change to the
       themes directory to all three.
     - **Proof:** the three checks and `mix troupe.admin.tokens --check`;
       `front_page_assets_test.exs` and `console_assets_test.exs`; `/` and `/docs`
       before and after, at 1280px and 380px, on the pull request.

717. **The desktop app's Tauri plugins move when tauri does, their Rust and JavaScript
     halves together.** Folding Dependabot's updates into the 0.6.1 chunk; the rule 708
     followed for the notification plugin, made the rule for all of them.
     - **The CLI checks the pairs.** `tauri build` refuses a build whose `tauri-plugin-*`
       crate and `@tauri-apps/plugin-*` package differ in their minor ("Found version
       mismatched Tauri packages"), and so does `tauri-action` in `native.yml`. Dependabot
       updates the crates and the npm packages in separate groups, so one of its pull
       requests can move one half alone: #120 took `tauri-plugin-http` to 2.7.0 with
       `@tauri-apps/plugin-http` on 2.6, and the build stopped there.
     - **A plugin's next minor waits for tauri's.** `@tauri-apps/plugin-http` 2.7 depends
       on `@tauri-apps/api` 2.12, and `tauri-plugin-notification` 2.5 on tauri 2.12; beside
       tauri 2.11 the first would put a second, newer copy of the API into the bundle. So
       both stay on the minor that goes with tauri 2.11, pinned with `~` on both sides
       (`tauri-plugin-http ~2.6` and `~2.6.1`, `tauri-plugin-notification ~2.4` and
       `~2.4.0`), and the pins come off in the change that moves tauri, `@tauri-apps/api`
       and the CLI to 2.12 together. `tauri-plugin-single-instance ~2.4` (730) has no
       JavaScript half, and its 2.5 wants tauri 2.12 too.
     - **Proof:** the renamed desktop build (`pnpm tauri build --bundles nsis`) with the
       pins; with #120's lock as Dependabot wrote it, the same build stops at the check.

718. **A session starts without reading the workspace's ignore rules; watching reads them
     when it starts.** Issue #231's cause (TUI Decision 128 has the rest). The watcher and
     `Session.Files` each walked the workspace for its `.gitignore`s in `init`, whether or
     not they would ever watch: two walks per `session.create`, inside `Troupe.Sessions`'
     `start_child`, which does not time out, for rules only a watch or `fs_events` backend
     uses, and both are off by default. A directory with no `.gitignore` to prune the walk
     is walked whole, and a home directory, where a new terminal opens, is the worst of
     them: one walk of it took over 150 s on the machine of the issue (this repository,
     8 s). So the TUI's embedded daemon answered `session.create` long after the client's
     30 s, and plain `troupe` died in its boot. The rules are now read by the backend's
     start, in both, and by a scan asked for (`Watcher.scan_now/2`). A session that
     watches from its start still walks there, as before; that is a watch in a home
     directory, which polling would not survive either. Proof: `watch_session_test.exs`
     ("a session that is not watching starts without reading the ignore rules"), and
     plain `troupe` in a directory of 360,000 files, which died in its boot after 30 s
     before and opens now, on the pull request.

719. **On Windows the daemon's VM reads nothing of the console and has no break menu for
     Ctrl-C: `-noinput` and `+Bc`, and the null device for standard input.** Issue #231's
     follow-up for the daemon (TUI Decision 130 has the TUI's side). The daemon release
     had the stock `vm.args`, so a daemon in a console, `troupe-daemon run` typed there
     or the one `troupe daemon run` starts, had a reader on it and the break handler's
     menu for Ctrl-C and Ctrl-Break, which then read the console beside the shell.
     `apps/troupe_daemon/rel/vm.args.eex` now gives the Windows build `-noinput` and
     `+Bc`, and `bin/troupe-daemon.cmd` starts every VM with the null device as standard
     input. The two go together: `+Bc` turns off the console's processed input through
     the VM's standard input, so given the console it would make Ctrl-C a key nobody
     reads here, and the daemon could not be stopped with it. Given the null device it
     leaves the console alone, Ctrl-C stays a signal, and under `+Bc` that signal is
     passed to Windows' own handler, which ends the VM at once with no menu to answer.
     `+Bi` would ignore Ctrl-C and leave the daemon running, and `+Bd` is not read on
     Windows. Ctrl-Break still opens the menu, which then reads the null device, finds
     nothing and ends the VM. The Unix build is unchanged: there Ctrl-C is SIGINT to the
     terminal's process group. Proof: the Windows release, `troupe-daemon run` in a
     console window and under `troupe daemon run`, with Ctrl-C, before and after, on the
     pull request.

721. **With Cilium, the operator admits the installation's own OpenBao and object store
     by name when they are outside the cluster; a pod that cannot reach its object store
     says `object_store_unreachable`.** Issue #249. Since 0.5.0-beta.1 the worker
     NetworkPolicy has no public rule where Cilium is, only a `.svc` OpenBao or object
     store had a rule of its own (`in_cluster_rules/2`), and the `CiliumNetworkPolicy`
     named the profile's hosts alone (`WorkerProfile.egress_destinations/1`). So an
     installation whose object store was a hosted S3 service activated no session: every
     restore waited out a connect timeout, and the plane relayed `timeout`. The hosts of
     `bao.address` and `objectStore.endpoint` that are not in the cluster now go into the
     `toFQDNs` rule beside the profile's (`Resources.platform_hosts/1`), and not into the
     profile's allowlist: they are the platform's, set by whoever installed it, and the
     allowlist is the profile's own destinations, which the plane shows and admission
     checks against `allowedEgress`. Asking for them in every profile's `egress.fqdns`
     would make each profile name, and each policy allow, a host no profile chose. On the
     worker, a transport error from the object store during a restore is
     `{:object_store_unreachable, endpoint, reason}` (`Restore.unreachable/2`), answered to
     the plane as `unavailable` with that reason and the endpoint. It is not a
     `session.unrestorable` (Decision 661): the session is intact and the plane retries.
     A pod also lists the bucket once at each enrolment and logs when it cannot
     (`Restore.check_reachable/1`, `Link.info/1`); a log line rather than a readiness
     condition, because failing readiness over a storage outage would take the pod's
     attached sessions off its Ingress as well. Proof: `resources_test.exs` (external
     endpoints with and without a port, in-cluster ones, a host named twice),
     `object_store_unreachable_test.exs`, `plane_link_test.exs`; and the cluster suite's
     `egress_test.exs`, which dials the pod's own `TROUPE_OBJECT_ENDPOINT` and
     `TROUPE_BAO_ADDR` and activates a session that seals, where it runs with Cilium.

722. **A workspace is restored from what storage says it has, or the activation fails; a
     key manager the pod cannot reach is `kms_unreachable`; the worker image watches with
     `inotifywait`.** Issue #252. The restore reads the events and then finds the
     workspace's newest archive by listing `workspace/`, and a listing that failed was read
     as "no archive": the session came back with an empty tree, or with an older one from
     the pod's cache, under a history that had moved past it, and its next archive sealed
     that over the newer one. A failed listing now fails the activation, as
     `object_store_unreachable` when it was the network's (Decision 721), and the plane
     tries again. The cost is that a pod whose cache is current cannot use it while
     storage does not answer; a cache is only trusted once storage has said it is not
     behind, which is the rule the cache already had. A transport error from
     `Context.open` is `{:kms_unreachable, address, reason}`, answered as `unavailable`,
     for the reason 721 names the store: the bare error said neither which host nor that
     it was the key manager. The worker image installs `inotify-tools` (GPL-2.0, a
     separate program the VM starts, as `git` is; the licence inventory lists lock files,
     and Debian keeps the package's licence in the image), so `Troupe.Session.Files` on a
     pod reports a deletion, inside a second; and where `inotifywait` is installed but
     refused or stopped, as on a node whose inotify limits are used up, `Files` polls
     rather than going quiet, as the session watcher already did. Proof:
     `workspace_listing_test.exs`, `kms_unreachable_test.exs`, core `files_test.exs`, and
     the worker image with a session deleting a file.

723. **With Cilium, an allowed host that is an IP address is admitted as that one
     address, by a `toCIDR` rule.** Issue #251. The `CiliumNetworkPolicy` wrote every
     external host as a `toFQDNs` `matchName`, the installation's OpenBao and object store
     among them since Decision 721, and Cilium learns what a `matchName` admits from the
     DNS answers its proxy sees. Nothing looks an address up, so an object store at
     `http://192.0.2.10:9000`, or an address a profile named, was admitted by nothing. A
     host that parses strictly as an address (`:inet.parse_strict_address/1`) now goes
     into one `toCIDR` rule beside the `toFQDNs` one, as `/32`, or `/128` for IPv6, in its
     shortest form, and with no ports, as the FQDN rule has none. `toCIDR` rather than
     `toCIDRSet`, which exists for `except`, and nothing here excepts anything. It does
     not reach an address inside the cluster, because Cilium matches a pod, and a
     Service's backends, by identity and not by CIDR; an in-cluster endpoint is still
     named as a `*.svc` host, which is its namespace and port. Without Cilium nothing
     changes. Proof: `resources_test.exs` (the platform's endpoints as IPv4 and IPv6
     literals; a profile's own addresses beside its names).

724. **Without Cilium, the operator admits the installation's own OpenBao and object store
     outside the cluster on the port they name: an address as that one address, a name on
     another port as the public rule's addresses on that port.** Issue #257, the half of
     #249 that Decisions 721 and 723 left. Without Cilium the worker NetworkPolicy reaches
     outside the cluster through one rule, public addresses on 443 and 80, so an object
     store on 9000, or an OpenBao at a private address, was admitted by nothing and no
     session activated. For `bao.address` and `objectStore.endpoint` that are not `*.svc`
     hosts, `Resources.platform_rules/1` now adds a rule on the endpoint's own port: an IP
     address, private or public, as an `ipBlock` of that one address (`/32`, `/128`), and
     a name on a port other than 443 and 80 as the public rule's ranges on that port. The
     public rule itself stays 443 and 80: opening it to the private ranges or to more ports
     would widen it for every destination, to admit two that the installation chose. The
     cost is that a name on 9000 opens 9000 to every public address, which is as much as a
     NetworkPolicy can say about a name. About a name that resolves to a private address it
     can say nothing, and nothing here tries: such an endpoint is given as its address, or
     admitted by a NetworkPolicy the installation adds to the worker namespace (policies
     add up, and the operator prunes only what carries its label), or Cilium is used. With
     Cilium nothing changes. Proof: `resources_test.exs` (a name on another port, a name on
     443 and 80, a private and a public address, `*.svc` endpoints, and the Cilium path).

725. **An activation that fails takes away the log and the workspace it put on the pod,
     and leaves what it found there; a read and a fork name an unreachable store or key
     manager as an activation does.** Issue #259. An activation restores the session's
     log into the pod's state directory, then its workspace, then starts the sealer and
     the actor tree. A failure after the log was written (storage that stopped answering
     at the workspace listing, which Decision 722 made a failure; a config the session
     would not start with; a raise on the way) left the log and the workspace until the
     session was next activated on that pod or went dormant there, which for a session
     that goes on to run on another pod is never. `Manager.put_back/3` now removes them on
     any such failure, returned or raised. It removes only what the activation added. A
     log that was there before it started is a reader's, restored for `session.read` and
     perhaps still served, and a workspace with anything in it is one a pod that stopped
     without putting the session to sleep left, which may hold files no archive has: both
     stay, and a failure before the events step touches nothing. The pod's cache is
     sealed bytes the activation only read and stays too, with 722's rule that it is
     used only once storage has answered unchanged. `session.read` and the fork step of
     `session.activate` opened their contexts and read storage without the names
     Decisions 721 and 722 gave an activation, and answered `internal_error` with the
     inspected transport error. They now go through `Restore.open_context/2` and
     `Restore.unreachable/2`, answer `unavailable` with `object_store_unreachable` or
     `kms_unreachable` and the endpoint or address, and say so in the pod's log, which
     for a read is the only place: the plane hands the client an endpoint whatever the
     pod answered. Proof: `failed_activation_test.exs`, and the read and fork cases in
     `object_store_unreachable_test.exs` and `kms_unreachable_test.exs`.
726. **A worker upgrade finishes by itself: the plane drains a pod behind once it holds no
     active session and records that on the profile, and the operator then deletes it.**
     Issue #258. A worker StatefulSet rolls `OnDelete`, and since #253 `UpgradePending`
     names the pods behind, but nothing replaced them. The operator cannot tell a drained
     pod from a draining one, since readiness fails as a drain starts, and only the plane
     knows when a pod holds nothing; the plane has no pod `delete` and gets none (#253's
     option (c)). So each writes what it alone knows, where it already writes: the
     operator lists the pods behind in the status it owns (`status.podsBehind`, name, uid,
     revision), and the plane its finished drains in an annotation (`troupe.dev/drained`,
     pod to revision), because its grant is `patch` on the resource and not on the status,
     under a field manager of its own so its profile writes do not remove it. The plane,
     on the scaler's tick, drains the highest-ordinal pod behind that holds no active
     session, only while no other pod behind is draining, and records a pod once it is
     draining and a count taken on a later tick finds it empty. The operator deletes a pod
     that is behind, recorded at the revision it still runs, and not Ready, one at a time,
     highest ordinal first, and never while one is terminating or missing; not Ready is
     what keeps a pod that restarted after its record, and may have been given a session,
     from being deleted. The operator's list carries each pod's uid, and the plane keeps a
     worker's uid from its enrolment token's `pod-uid` claim, because a pod's replacement
     has the same name and can enrol before the next pass: drained by name, it would be a
     current pod drained for good. Placement puts a new session on a current pod while one
     has room (`workers.upgrade_pending`), so a busy pod's sessions go dormant in their own
     time. A profile with one pod gives it new sessions until every one is dormant, then is
     without a pod while the replacement starts. This is the "removes a drained pod" that
     Decision 633 still owed, for pods behind only: a drained current pod still waits for
     a person. What it costs: an idle pod's drain is started without waiting for it, and a
     drain whose answer never arrived leaves the pod Ready and recorded until somebody
     drains it again; a CRD without `podsBehind` drops it and the roll stays manual.
     Proof: `reconciler_test.exs` (behind and drained is deleted; not drained, Ready again
     or drained on another revision is kept; one at a time; current never), the plane's
     `upgrade_test.exs` and `placement_test.exs`, and the cluster suite's `upgrade_test.exs`,
     which rolls a one-pod profile with nobody deleting anything.
727. **A root agent that keeps crashing ends its turn saying why, and its session stops
     instead of starting it again.** D37. A root whose start failed every time, or that
     crashed every time on the turn it came back to (a reaper that could not spawn, under
     the `git` call `Instructions.load` makes), was restarted by its `Agent.Node` three
     times in five seconds, and then the session's `rest_for_one` started the Node again,
     three times more: fifteen `agent_restarted` in a fraction of a second, then the
     session gone, nothing in its log saying why, and every client still showing the turn
     at work.
     - **The session does not multiply the Node's restarts.** The root Node is a
       `significant`, `transient` child, and the session shuts itself down when it exits
       (`auto_shutdown: :any_significant`). When the Node gives up the session stops and
       comes back dormant from its log, as `Troupe.Sessions` always said it would. A
       Node that is killed is still started again.
     - **The root says why before it goes.** `Session.Log` counts how often each agent
       has started again, for as long as the tree is up, as it already knew whether one
       had started at all; the agent reads from it whether this start is the last its Node
       allows. A start that fails then, or a crash in a state callback then, writes
       `turn_ended` with `reason: agent_failed` and `detail`, the first line of what was
       raised, and crashes as before. The count looks a second further back than the
       Node, which counts restarts in whole seconds: a word one start early, when the Node
       allows another after all, is better than none.
     - **That turn is not taken up again.** A restart, and `resume_on_restart`, read it as
       a cancel, as they read a turn the failure guard stopped (687).
     - A subagent is unchanged: its parent turns its Node's `:DOWN` into an error result.
       There is no backoff: a delay in a restart blocks the supervisor making it, and the
       Node's three quick tries are what it was built around.

     The A2A facade fails the task with the detail. The TUI and the desktop app show
     `agent_failed` as an ordinary rest until they learn the reason. Proof:
     `crash_loop_test.exs` (a start that fails every time; one that crashes on the turn it
     takes up, which wrote 15 `agent_restarted` before this and 3 now; a session brought
     back with `resume_on_restart` that does not take the turn up) and the A2A app's
     `events_test.exs`.

729. **Dependabot moves Tauri's crates and its npm packages in one pull request, and keeps
     `@types/node` on the runtime's major.** defects.md D37, in the 0.6.3 chunk. Decision
     717's pairs were in two groups, npm `tooling` and cargo `tauri`, so one pull request
     could move one half alone, as #120 did.
     - **One group across the two ecosystems.** `multi-ecosystem-groups: tauri`, monthly,
       takes `@tauri-apps/*` from `clients/gui` and `tauri*` from `src-tauri`, and the
       ordinary npm and cargo entries ignore those names, so the group's pull request is
       the only one that moves them. Dependabot still opens it when only one ecosystem
       has an update, so a registry that lags the other can yet send half a pair; the
       Tauri CLI's check then refuses the build, as it should, and the pull request waits.
     - **`@types/node` is the Node the tools run on**, `.tool-versions`' 24, not the
       newest: 26's types describe APIs 24 does not have. It is back on 24, Dependabot
       ignores its majors, and the major moves by hand in the change that moves that line.

730. **On Windows the desktop app shows its notifications itself, so that a click on one
     opens its session, and it runs as one copy.** Defect D35, following 714 and 708.
     - **The toast is the one the plugin shows underneath.** `tauri-plugin-notification`
       hands its toast to notify-rust and lets go of the handle that would hear a click
       (714). On Windows the shell's `notify_show` builds the same WinRT toast through
       `tauri-winrt-notification`, which notify-rust had already brought into the lock:
       the same app id (the bundle identifier, which the installer writes on the Start
       menu shortcut, and PowerShell's for a build run from `target`), silent and short
       like the plugin's, and an `Activated` handler that holds the session's id. A click
       sends `troupe://open-session` to the page, then brings the window forward. On
       macOS and Linux `notify_show` answers false and the page uses the plugin, as it
       does when the shell's toast fails.
     - **The window coming back stays the answer where no click is heard** (714): macOS
       and Linux, a toast the shell could not show, and a click that Windows turns into a
       launch.
     - **One copy.** `tauri-plugin-single-instance`, registered first and pinned `~2.4`
       (717). A second launch, from the Start menu or from a click, hands its arguments
       to the copy that is running and exits. The running copy comes forward, and opens
       the session a `--session=<id>` among those arguments names, as a click would. A
       toast from `tauri-winrt-notification` 0.8 carries no launch argument, so a copy
       that Windows starts for a click names nothing. The app has no COM activator, and
       whether Windows starts one at all is unsettled here. In that case the window coming
       forward is the answer. A debug build does not register the plugin: `tauri dev` has
       the installed app's identifier and would hand itself over to it.
     - **Proof:** `cargo test` (the launch argument, and the app id for an installed
       build and a build run from `target`); the desktop app's `notify` test, where a
       reported click opens its own session and not the last one's; and a renamed
       installed build against a fake daemon. Its toast is in Windows' history under the
       build's id with the shell's two fields, where the plugin's has three. A second copy
       with `--session=` exits in about 40 ms, and the first comes back on that session,
       17 s after the last toast. A second copy with no arguments, just after a toast,
       brings the first back on the toast's session. No toast was clicked: this machine
       shows no banners, and its notification centre was not opened while in use.

731. **A scale-down drains the pods it removes before it lowers the count, and finishes
     once it has started; a worker stopped by anything else drains itself.** Issue #273.
     The scaler wrote a lower `spec.replicas` as soon as the grace period had passed, and
     the StatefulSet took the highest ordinals with what they held: a turn in flight and
     the workspace since its last archive, while clients saw the session vanish until the
     sweeper marked it dormant from its last seal. `Drain.scale_down/3`, which the
     scaler's documentation relied on, had no caller but a test, and is gone. Now the
     scaler marks the pods above the count it wants `retiring` and draining, drains them
     in the background with the drain an administrator starts (`Drain.start/2`, which the
     upgrade of 726 uses too), and lowers the count from the top past each retiring pod
     that is draining and holds no active session on a count taken before that tick,
     never past one the plane still counts a session on. A turn in flight gets the drain
     timeout, the number the grace period is set from, and is then cancelled with
     everything before it sealed: bounded, because a session that never rests would
     otherwise keep a pod nobody needs, and no harsher than deleting the pod. Nothing
     retries; the pod is asked once and each tick reads the count. A scale-down that has
     started is finished even when the sessions come back, because a drained pod takes no
     session until it restarts (633) and kept it would be room counted that is not there:
     the count comes down past it and the next tick asks for a fresh pod. `retiring` is
     what tells this drain from an administrator's, which stays a person's (633, 726)
     unless its pod is above the wanted count; it is cleared when the count passes the
     pod and whenever a pod is not draining. 726's `troupe.dev/drained` record is not
     used: it tells the operator to replace a pod behind, and nobody but the plane is
     needed to remove a pod, since it writes the count. A count that grows while a
     retiring pod still drains grows past it, and that pod goes with the next scale-down
     that reaches it. The worker drains on SIGTERM as well (`prep_stop/1`) for pods the
     plane did not stop: turns get half its drain timeout and the rest of the grace
     period is for sealing, archiving and reporting; a shorter grace period ends it as a
     stop always did. The plane migrates (`workers.retiring`). Proof: the plane's
     `scaling_test.exs` (drains first, a busy pod delays it, a drained pod goes, a started
     scale-down finishes, an administrator's drain is left), the worker's `drain_test.exs`
     (a pod stopped mid-turn puts its session to sleep and its files survive the volume),
     and the cluster suite's `capacity_test.exs`.

     

732. **A reader takes the log it restored with it, and stays while a client reads the
     session; a fork whose parent's workspace listing fails makes no child.** Issue #269.
     `session.read` restores a dormant session's log into the pod's state directory, and
     nothing removed it: it stayed, in plaintext, until the session was next activated on
     that pod and put to sleep there. The reader now removes it when it stops, however it
     stops: its last follower gone, closed, idle, or the pod shutting down. Not a log that
     was there before the read (725's rule for an activation, from the other side), and not
     one an activation has: a manager registered for the session, whether it is starting
     over the log or running, or one that has written to it since, which the reader tells
     by the log no longer being the size it wrote, a log only growing. Such a log may hold
     events storage does not have yet. A restore writes the log and a reader removes it
     under one lock per session on the pod (`Restore.with_log/2`), so an activation that
     starts as a reader leaves is either seen by it or writes its log after. Taking the log
     away made the reader's lifetime matter: a client reading through the pod's harness
     reads the log from disk and follows no process, and a reader that went after its 30
     seconds would take the log from under them. So a reader stays while a client is
     attached to the session (`Troupe.Events.attached?/1`) or an activation is starting,
     and goes once one has taken the log over; the cost is a process and the log on the
     pod for as long as somebody reads. One case is left as before: an activation that
     wrote the log again with a longer history and then failed, which by its size is not
     the reader's. On the fork's side, `Storage.workspace_archives/2` read a failed listing
     as no archives, so a fork that met storage going away at that one request sealed a
     child with the parent's history and no tree, and the child, having segments, was never
     forked again: 722's failure for an activation, in the fork. A failed listing now fails
     the fork before anything is written for the child, as `object_store_unreachable` where
     it was the network's, and the plane tries again; `workspace_at/3` says the same, and
     `Fork.copy/3` is its only caller. Proof: `reader_log_test.exs`, the fork case in
     `object_store_unreachable_test.exs`, and `storage_test.exs`.

     

733. **A reaper helper that will not start is an error its caller gets back, never a
     raise: the session answers, runs no command, and `troupe doctor` says why.** Issue
     #270. `Troupe.Reaper.open/3` called `Port.open/2` directly, and that raises when the
     program is there and will not start: no execute bit or a mount that forbids running
     it on Linux, a file that is not a program on Windows (`eacces` on both). Every model
     call asks `git` where the repository is, in the agent's own process
     (`Instructions.load`, then `Session.Memory.path/1`), so such a helper crashed the
     root agent on every turn and the session never answered; the loop that followed is
     what Decision 727 bounds. `open/3` and `open_stdio/3` now return
     `{:reaper_unstartable, reason}` with the OS's reason, and log it once for each helper
     and reason, not at every call. On Windows a working directory that has gone raises
     the same way; that is `{:no_directory, cwd}`, and not blamed on the helper. The
     callers: the brief's `git` calls read the workspace as no repository, as a missing
     `git` already did, so a session at the repository's root still reads its brief and
     one in a subdirectory or a worktree reads none that turn; `shell` answers the model
     with the helper's path, the reason and that nothing runs until it does; `grep` scans
     in the VM, as it does without a helper; `git_read` and an MCP server say they could
     not run, and why. `troupe doctor` gains a `reaper` line, `reaper --version` started
     in the workspace: `ok` with what it printed, `warn` for a build without a helper (a
     source checkout without Zig, where `shell` never ran), and `FAIL` for one that will
     not start, since that is an install a person has to put right and a session shows it
     only through the model's words. A harness note in the session was the other place to
     say it, and would say in every session what the doctor's one line says once.
     `config :troupe_core, :reaper` names a helper elsewhere, as `:bwrap` does for
     bubblewrap; the suite points it at one that will not start. Proof: `reaper_test.exs`
     (a turn answered, a shell call that is a tool error and a turn that goes on, the
     brief read as no repository with one warning over three loads, `grep`, `git_read`,
     an MCP server, a directory that has gone), nine of whose eleven tests fail on the
     chunk's tip with the config key alone; `doctor_test.exs`; and the installed build
     with its helper swapped for a file that is not a program.

734. **This repository names no deployment of Troupe, and a check in CI keeps it so.**
     Issue #186. The repository is the product: the chart, the images, the clients and
     how to build them. The deployment its maintainers run lives in a repository of its
     own, which consumes the published chart and images as any adopter's would, so its
     cloud, cluster, domain, registry, identity tenant and deploy account are not named
     here. A reader used to learn one cluster's topology from this repository, and an
     adopter had to guess which parts of an example were somebody's own.

     *What stays.* `values.example.yaml` is the one worked example: a managed cluster,
     PostgreSQL and object store, ingress-nginx, cert-manager, OpenBao in the cluster,
     the chart's own images (735), and every value that has to be the reader's marked
     `CHANGE ME`. `values.small.yaml` is the same shape turned down. What the provider
     walkthrough knew that holds anywhere — the two DNS names, the ingress settings, the
     HTTP-01 issuer, how to run OpenBao, sizing — is in `docs/admin/installing.md` §6.
     `authentik.md` is a guide to any Authentik instance.

     *What went.* The provider's own values and cluster extras, the deploy account's
     manifest and the script that made it a kubeconfig, and `scripts/deploy`, whose
     only callers left with the deploy (735). An upgrade is the steps in
     `routine-tasks.md`, which now say what the script knew: CRDs server-side, a
     rollback on failure, the version at `/.well-known/troupe`, and the digests actually
     running. `scripts/remote-up` has no default model gateway: a placeholder under
     `example.test` that resolves nowhere, with the host of `TROUPE_GATEWAY_URL` put
     first in the kind policy's egress list (`--set` on that index keeps the rest), and
     the key in `TROUPE_GATEWAY_KEY`. CI's cluster job names a public host, so the
     egress suite still has a model endpoint a pod can dial.

     *The check.* `scripts/check-neutral.exs`, in the `versions` job, reads every file
     git knows and fails on a line that names one. The names are kept as SHA-256 digests
     of their lowercase spelling, so the file that keeps them out does not name them;
     each run of letters, digits, dots and hyphens is checked whole, by label, by word
     and by dotted suffix, which catches a host under any subdomain. A file that must
     keep a name for a while is allowed with the reason, and an allowed file that names
     nothing fails too, so the list only shrinks; it is empty. Git history keeps every
     old name, and nothing here rewrites it. Proof: the check names 161 lines in 39
     files at 0.6.3-beta and none here, and CI lints and renders the chart with both
     remaining values files, one of them with a pull secret.

735. **A release publishes its images and its chart to `ghcr.io`, public, and deploys
     nothing.** Issue #186. The images went to whichever registry four repository
     secrets named, which was our own cloud's, and `release.yml` ended by rolling our
     cluster with a kubeconfig from its `production` environment, as `deploy.yml` did by
     hand: the product's repository held a credential for one deployment's
     infrastructure and knew which cluster was ours. Now `images.yml` pushes the five
     images to `ghcr.io/<owner>/troupe-<name>` with the workflow's own `GITHUB_TOKEN`
     (`packages: write`), tagged as before (`sha-<short>`, and the version for a release
     or a pre-release), labelled with this repository as their source. There is no
     registry to configure and no override for one: a secret naming a registry is a door
     into somebody's infrastructure, and a deployment that wants a mirror copies from
     `ghcr.io`. The packages are public, so a cluster pulls them with no credential;
     GitHub creates a package private, and an organisation owner makes each one public
     once, which no workflow can do. A release also pushes its chart as
     `oci://ghcr.io/<owner>/charts/troupe` at its version, beside the `.tgz` on the
     release page (322), in the job that publishes the release and just before it does,
     so a chart version in the registry is a release that finished; the release's notes
     show both. A pre-release pushes its chart too, when it built its images, since a
     chart whose images were never pushed installs nothing that runs; Helm takes a
     pre-release version only when it is named. `release.yml` ends at the published
     release and `deploy.yml` is gone: a deployment pins a version, holds its own values
     and credentials, and takes the published chart and images from a repository of its
     own, which nothing here names, dispatches to or waits for. `charts/troupe/values.yaml`
     names the `ghcr.io` images and its policy allows the worker's, and the development
     loop (`scripts/build-images`, `scripts/remote-up`, `dev/kind/values.yaml`, the
     cluster suite) builds and runs under the same names, so a kind cluster runs the
     chart's own defaults. Supersedes the deploying half of 669.

736. **In gitops mode a repository holds the profiles and the policy, and the plane reads
     them from the cluster and never writes git.** Issue #186. `provisioning_mode: gitops`
     made a profile save a commit to a checkout configured only by `:gitops[:path]`,
     which nothing set in a real plane, whose image has no `git` and no push credential:
     the mode worked in tests. Now the `WorkerProfile` and `TroupePolicy` resources a
     repository holds, applied by Flux or anything like it, are what a gitops plane runs
     on. A cluster singleton (`Troupe.Plane.Gitops`) lists the profiles in the plane's
     namespace every fifteen seconds and makes its rows follow them, making, changing and
     deleting them, audited as `system:gitops`: a tick and not a watch, because a list
     sees what is not there without a watch's bookmarks and relists, a plane that was
     down is right at its first tick, and the change it waits for arrives after the
     applier's own interval. A resource is used only if the plane could have saved it
     itself (its annotations parse, it has an image, its `sessionsPerPod` is a class's,
     the cluster policy allows it, nobody else sets the plane's fields); otherwise it is
     reported in `gitops_reports`, the log once, `admin.profiles.list` and the console,
     and not used: a new one gets no row, and a changed one leaves the last version that
     passed. The plane still writes the three fields that are projections of its own
     state, `spec.replicas`, `spec.teams` and `spec.mcpServers`, server-side as
     `troupe-plane`, where they differ and only onto a resource something else holds. One
     only the plane has written is reported `plane_only` and not written to, because three
     fields applied by the only owner of the rest would give the rest up. It is the
     manager name direct mode uses, so the first write after adoption releases what
     direct mode took and a field the repository drops then leaves the cluster. The
     `troupe.dev/drained` record (726) keeps its own manager and survives the applier,
     which owns only what its manifest names. The plane's answers the CRD has no field
     for are annotations (`troupe.dev/max-sessions`, `warm-workers`, `provisioner`), the
     class is read off `sessionsPerPod`, and `release` is not followed: a manifest pins
     its image, and 672's comparison against the last commit goes with the commit.
     `admin.profile.put` and `admin.profile.delete` refuse as `managed_by_gitops`
     (-32015), audited with `outcome: refused` as a refused break-glass login is; the
     exception is deleting a row the cluster has no resource for, reported `missing`
     after a switch and never deleted by the plane itself. There is no policy write to
     refuse, the plane's grant on `TroupePolicy` being read-only already, and in gitops
     mode its `:policy` configuration is not read. The console shows profiles locked, with
     `gitops_source`, a display-only setting; `admin.profiles.export` gives every profile
     and the policy as a repository would hold them, without runtime fields, the plane's
     three or its drained record. `provisioning_mode` becomes the deployment's: a console
     that could switch it back would be a lock with the key hanging beside it, and a
     profile made then would be one the repository never saw and its applier never
     prunes. A value stored before is ignored, and the chart's Role drops create and
     delete on `WorkerProfile` in gitops mode. The plane migrates
     (`profiles.resource_generation`, `gitops_reports`); another kind of resource joins
     by implementing `Troupe.Plane.Gitops`'s behaviour. Proof: `gitops_test.exs`, against
     a model of server-side apply's field ownership (made, changed, removed, refused, the
     plane's fields, the drained record under Flux, the refusals over the API and MCP, the
     export and its round trip, both switches), `gitops_console_test.exs`, and the
     updated `provision_test.exs`, `release_image_test.exs` and `settings_test.exs`.

737. **In gitops mode a repository holds the triggers too, as `Trigger` resources the
     plane reads; a trigger's key, runs and revisions stay the plane's.** Issue #186. A
     gitops plane's profiles were reviewed files and its triggers were rows somebody typed
     into a console, so what fires unattended, as whom and with what prompt was the one
     part of the fleet no repository could restore. Now a `Trigger` CRD, one resource per
     trigger in the plane's namespace, is the second source of 736's pass, read after the
     profiles so a trigger and the profile it names can land in one commit. Its name is
     `<team>.<trigger>`: a trigger's name is unique in its team and a resource's in its
     namespace, a dot is in neither, and a team said once has no second field to disagree
     with. Its spec is the trigger's document in the CRD's spelling (`promptTemplate`,
     `notifyUrl`, and `budgetMicros`, `maxTurns`, `wallClockSeconds` in `terms`), the
     principal by subject; a field left out is its default, not what the row said. A
     resource is used only if `admin.trigger.put` would have saved it and what it names is
     here — the team, a service principal of that team, and a profile, which `put` never
     checked and which a trigger fails on at every firing without. A spec key a `Trigger`
     has not got is refused too, and the CRD keeps unknown fields so that a misspelt
     `promptTemplate` reaches the plane instead of being pruned into a trigger that asks for
     nothing. Otherwise 736 holds: reported and not used, a changed one left at the last
     version that passed and still firing, a removed one deleted with its runs as
     `admin.trigger.delete` did, each audited as `system:gitops` with the revision it made,
     a row the cluster never had kept as `missing`. The row is changed in place, so its id,
     URL and key survive every commit, and a row from direct mode is adopted by the
     resource of its name. `admin.trigger.put` (enabling and disabling included) and
     `admin.trigger.delete` refuse as `managed_by_gitops`, audited, the delete again except
     for a `missing` row; switching a trigger off is a commit, or in a hurry a patch while
     the applier is suspended, or disabling its principal. `admin.trigger.run` and
     `admin.trigger.key.rotate` keep working: firing is something done with a trigger, not
     what it is, and a key is not configuration. The key stays plane-held rather than a
     Secret reference because the plane mints it and keeps only a salted hash, so a
     resource has nothing to carry; a reference would give an internet-facing plane a
     grant on Secrets its Role deliberately lacks, to hash a value it could mint; and a
     rotation answers a leak, which cannot wait for a review and an applier's interval.
     Teams, their grants and service principals stay the plane's database's, and a
     trigger names them. Taking them into a repository later would need a `Team` resource
     (the group it maps, its budget, retention and grants, with enabling and disabling
     following it, and a prune that disables a team a decision rather than an accident)
     and a `ServicePrincipal` resource without its secret, which would stay plane-minted
     as a trigger's key does, applied before the profiles and triggers that name them.
     `admin.triggers.list` carries `gitops` per trigger and lists a refused resource of the
     team by name, and one naming no team here to a platform admin; the Triggers page is
     locked with `Layout.locked/1`, which the profile editor now shares, and keeps run,
     key and revisions. `admin.profiles.export` gives every trigger as
     `triggers/<team>/<trigger>.yaml`, without the plane's own fields. The chart's gitops
     Role gets `get`, `list`, `watch` on `triggers` and nothing else; the plane migrates
     (`triggers.resource_generation`). Proof: `gitops_triggers_test.exs` (made, changed,
     switched off, defaults, unchanged, removed, a failed list, a profile and a trigger in
     one pass; refused for a team, a principal, a profile, a name, `put`'s checks and an
     unknown key; a failed change still firing; the refusals over the API and MCP; a key
     that survives a change; a run by hand; a `missing` row kept and deleted; the export
     and its round trip keeping the id, revision and key; the CRD against the plane's
     fields; direct mode) and `gitops_triggers_console_test.exs`.

738. **A profile whose workers are machines has nothing in the cluster: no `WorkerProfile`
     in direct mode, and a count of none on the one a repository holds.** Issue #290. An
     `ssh` profile's workers are machines somebody registers, and the worker on each dials
     the plane; but `admin.profile.put`, a grant, a bundle's projection and a release all
     wrote it a `WorkerProfile`, and the operator, which reads no provisioner, made a
     StatefulSet of pods for it. `Provision.apply/2` now asks `in_cluster?/1`, which is
     the Kubernetes provisioner and nothing else. In direct mode a profile that is not in
     the cluster is written nothing, and a resource left from before (a profile that was
     Kubernetes's, or one saved before this was asked) is deleted, so the row stays the
     whole of what is wanted; the answer is `:not_in_cluster`. In gitops mode a repository
     holds every profile as a `WorkerProfile`, so the resource is there, and the plane
     writes `spec.replicas: 0` onto it rather than the scaler's count, which for such a
     profile is a number of machines. Between Flux's apply and the plane's first write the
     CRD's default of one replica still stands; teaching the operator the
     `troupe.dev/provisioner` annotation would close that, and would make it read an
     annotation it deliberately reads none of. `ReleaseImage` passes such a profile by:
     whoever installs the worker on a machine installs the release. Proof: `admin_test.exs`,
     `provision_test.exs`, `release_image_test.exs`.

739. **The documentation is one site, built from `docs/` and the documents its nav names
     elsewhere, and each document stays where whatever reads it looks for it.** Issues #51
     and #188. The docs were thorough and had no front page a reader could navigate:
     nothing was published, and a reader browsing the repository met the tracks, the root
     documents and the clients' own READMEs as three unrelated heaps. Now `mkdocs.yml` at
     the root builds a site with MkDocs Material, which #51 names, and
     `.github/workflows/pages.yml` builds it on every pull request and publishes it from
     `main` to GitHub Pages, at `it-minds.github.io/troupe` until the product site (#189)
     gives it a domain. The build is strict: a link to a page that is not there, a
     `#fragment` naming no heading of it, a nav entry to a missing file, or a page left
     out of the nav fails it. Heading anchors are spelt as GitHub spells them, so one
     `#fragment` works in both places. The nav is by
     reader — using Troupe, running a deployment, contributing, writing a client — each in
     the order to read it, and `docs/README.md` says the same in prose for whoever reads
     the repository on GitHub. MkDocs and its theme are pinned in `docs/requirements.txt`
     and Dependabot moves them monthly, but not MkDocs to 2: that drops the plugin and
     theme systems the site is built on, and Material requires 1, so leaving MkDocs 1 is a
     choice for the product site (#189) to make, not a bump.

     *Where documents live.* MkDocs builds one directory, and several documents a reader
     needs are read where they are by something else: the TUI's tests read
     `PROTOCOL.md`'s error table, the core's config test reads the YAML in the TUI's and
     the daemon's READMEs, GitHub finds `CONTRIBUTING.md`, `SECURITY.md` and
     `CODE_OF_CONDUCT.md` at the root, and code cites `ARCHITECTURE.md`, `PROTOCOL.md` and
     decisions by number. So none of them moved. A nav entry that names no file in `docs/`
     names one by its path from the root, and `docs/overrides/hooks.py` puts that file on
     the site at the same path. Links stay written for GitHub, relative to their file, and
     `scripts/doc-links.exs` keeps checking them; the hook rewrites each one for the site,
     to the page where the site has it and otherwise to the file on GitHub at `main`, and
     one that names nothing in the repository fails the build. A copy in `docs/` would be
     a second version to drift, a symlink fails on a Windows checkout, and a plugin for it
     would be a dependency doing what a page of Python does. The hook also reads `VERSION`
     into the banner every page carries, so the site says which release it describes.

     *The root.* It holds what somebody arriving at the repository needs, and what a tool
     reads there. `.github/CI.md` is contributor documentation and moved to
     `docs/developer/ci.md`; `.console-rig.exs`, a screenshot rig, moved to `scripts/`.
     No reports, audits or programme briefs remained after #54. The three `DECISIONS.md`
     files stay where they are: append-only records that changes add to while others are
     in flight, cited by number, and a reader gains nothing from their moving. The two
     plans under `docs/plans/` and `docs/program/` stay too, because #56, open, names them
     by path. The clients' READMEs stay as each directory's front page, and are the
     user's and the contributor's pages for their client on the site.

     *Diagrams are Mermaid in the source.* The topology and the order of a sign-in and a
     session (`ARCHITECTURE.md` §6), the session lifecycle (§4), the daemon on a person's
     machine (`docs/user/README.md`), the sign-in alone (`docs/admin/roles-and-permissions.md`
     §1), the supervision trees of a session and of the TUI's remote client
     (`docs/developer/architecture.md` §3 and §6, which were drawn in text), and a turn
     through the log (`docs/developer/tour.md`). The GUI README's path of a client, drawn
     in box characters, is a sequence diagram. No diagram is a checked-in image;
     `repo-structure.md`'s annotated tree is a listing and stays text. Contributors get a
     tour of their own, `docs/developer/tour.md` — where things live, running the suite,
     adding a tool, how the event log works — so neither they nor an operator reads the
     other's track. Proof: `mkdocs build --strict` in `pages.yml` on this change, and
     `doc-links.exs` and `check-neutral.exs` passing over the moved files.

740. **The README is a front door, the quick start it points to is run by CI, and the
     product is shown with example data.** Issue #188. A stranger landing here met the
     umbrella's layout, five images, a deploy command and the release process before
     anything said what Troupe is for, with no picture of it, no page that set it beside
     the agent CLIs a reader already runs, and six of its own words in the first paragraph
     with nowhere to look them up.

     *The README* is one screen: what Troupe is in two sentences, one Mermaid diagram of the
     machine and the cluster, what it is not, the install from the release installers for
     Linux, macOS and Windows, where to go next, and the licence with the name's terms. The
     rest moved to where it was already said: the images and the deploy to
     `docs/admin/installing.md`, which now also lists the plane's front-page paths;
     releasing to `docs/developer/ci.md` and `docs/developer/deployment.md`; building from source
     to `docs/developer/`; writing a client to PROTOCOL.md. Five badges, each something a
     reader can act on: CI on `main`, the quick start's own run, the latest release, the
     protocol's version and the licence. The protocol badge is static, so the quick start's
     job fails when it stops naming PROTOCOL.md's version.

     *The quick start* (`docs/quick-start.md`) is install, a key, a first session, what it
     cost, a cap, and what a plane adds, in that order, because the budget is the part a
     newcomer would not guess exists. The first session is `troupe run plan … --headless`,
     which reads and never writes, so nothing in it waits on an approval; the fix is made
     next in the TUI, where an approval is a key. What it cost is read from the session's
     log with `jq`, because Troupe keeps no price table and the log is where the answer is:
     a figure from the nightly live check for scale, prices marked as an example, and
     `models.prices` for a provider that reports tokens only. The cap is three keys in
     `config.yaml`, shown in force with `--explain`.

     *Run by CI.* A block the page marks `<!-- quick-start -->`, `<!-- quick-start: sh -->`
     or `<!-- quick-start: powershell -->` is one `quick-start.yml` runs:
     `scripts/quick-start-blocks` takes them out in order, and the job runs them as one
     script, in `sh -e` on Ubuntu and in PowerShell with native exit codes fatal on Windows,
     from the installers a reader downloads, with `TROUPE_PROVIDER=fake` answering from a
     file. Then it checks that a session's log holds the reply and that the cap is in
     force, and that the README's install blocks are the page's word for word. It runs on a
     pull request that changes the page, the README, PROTOCOL.md or itself, and nightly,
     because what breaks it with no change here is a release; by hand it installs a named
     release. It cannot run a real model, the TUI, macOS or a plane, and the page says so.
     Markers rather than a script of its own, because a script beside a page is a second
     copy of it and the page is what a reader follows.

     *Why Troupe* (`docs/why-troupe.md`) says who it is for, how it compares with an agent
     CLI on a laptop without a claim about one it could not show, what a plane buys and
     what it asks, and when you do not need it, each claim linked to the page or code
     behind it. *The glossary* (`docs/glossary.md`) defines each word once, and a page links
     to it the first time it uses one.

     *Pictures*, under `docs/assets/`, made with a headless Chromium from made-up data only:
     no real person, host or key. The desktop app is its web build against `pnpm fake`,
     signed in as that deployment's Alice. The console is its teams page from the plane's
     own endpoint, rendered in its test environment against the development PostgreSQL
     from made-up teams, people and spend, as the page is before its script runs. The TUI is
     `View.render/2` drawn into a headless `CellSession` from made-up events, as its suite
     draws it, then cell by cell into HTML. A recording of a live terminal session needs a
     recorder this project does not use yet; the capture stands in for one. Proof: the
     quick start's job on both platforms, `scripts/doc-links.exs` and
     `scripts/check-neutral.exs`.

741. **A person's own MCP server that wants them signed in, rather than a machine, is
     signed in to by the daemon, with PKCE and a loopback redirect, and its tokens never
     leave the person's machine.** Issue #300, the local slice. What was there: a bundle
     server is called from the pod with one shared token from a Secret, which such a
     server refuses; a person-mode bundle server reads a value the person pasted into the
     key manager, not a sign-in that runs out every hour; and a `url` in the person's
     `mcp.json` (700) was the one-shot HTTP client with no credential at all, `headers`
     dropped on import. A server that publishes OAuth protected-resource metadata, answers
     `401` with `WWW-Authenticate: Bearer resource_metadata="…"`, and has an authorization
     server with no dynamic registration could not be used from Troupe.
     - **What the person writes.** `oauth` on the entry, in `mcp.json` and in
       `config.yaml`'s `mcp:`: `client_id`, required, a public client registered in
       advance; `scopes`, `redirect_uri` (a loopback `http` URL, a fixed port when the
       client was registered with one), `resource: false` and `issuer`, each optional.
       Import reads `clientId`, `redirectUri` and `callbackPort` too. An `oauth` with no
       `client_id`, one on a `command`, or a redirect that is not loopback refuses the
       server, naming why. The fingerprint (700) takes the client and the issuer, so a
       workspace's server whose `oauth` changed is asked about again.
     - **Discovery, as the MCP authorization specification orders it.** The server's
       `401` names its protected-resource metadata (RFC 9728), or the two well-known
       places are tried; that names the authorization server, unless `issuer` does; its
       metadata is tried at the three places for an issuer with a path (RFC 8414 and
       OpenID Connect, inserted, then OpenID Connect appended) and the two without. Scopes
       are the entry's, else the `401`'s, else the metadata's `scopes_supported`, and
       `offline_access` is added when the authorization server offers it, since without a
       refresh token a person signs in every hour. Every URL that carries a sign-in is
       `https`, or `http` on loopback. Two deliberate departures, each with a switch: the
       specification has a client refuse an authorization server whose metadata does not
       list `code_challenge_methods_supported`, and OpenID Connect discovery does not
       define the field, so one that says nothing is used with S256 anyway and only one
       that lists other methods is refused; and the resource indicator (RFC 8707), sent
       by default as the server's canonical URL in the authorization and token requests,
       is left out with `resource: false` for an authorization server that refuses it,
       where the scopes say which API a token is for.
     - **The daemon runs the sign-in** (`Troupe.MCP.OAuth`, `Troupe.MCP.OAuth.SignIn`),
       because it is the process that calls the server and runs the person's other
       servers: the authorization code flow with PKCE (S256) and a `state`, and a
       listener on the loopback address the redirect names, on any free port unless the
       entry fixes one (RFC 8252 §7.3), for the one answer; anything else that arrives
       there is turned away, and an answer with another `state` is not this sign-in's.
       It waits five minutes; a second sign-in replaces the first. `mcp.sign_in` answers
       the URL and the redirect, and the TUI (`/mcp sign-in`, `s` on the page) and the
       desktop app (**Sign in** on "Servers and skills") open it and show the URL for a
       browser that did not open; the browser must be on the daemon's machine. Signing in
       to a workspace's server waits for the workspace's question (700), since its
       `oauth` came with the repository and says where a token of the person's would go.
     - **Where the tokens live.** `<state>/mcp-oauth.json` (`Troupe.MCP.OAuth.Store`),
       restricted to its owner before anything is written into it, renamed into place,
       never kept as a `.previous`. Not the OS keychain, because the daemon has none in
       this build (the model key is in `config.yaml` for the same reason) and a keychain
       only the desktop app could read would leave a terminal-only person with nothing;
       not `mcp.json`, which people link, copy and commit; not the configuration
       directory, which people keep in their dotfiles. Nothing of a token is in an answer,
       an event or a log line: `mcp.list` carries `auth`, `{state, account, error}`, and
       `account` is read from the ID token's claims for showing only.
     - **Use, refresh, and the `401`.** One process (`Troupe.MCP.OAuth.Tokens`) hands out
       tokens and is the store's only writer, because a public client's refresh tokens
       rotate and two sessions refreshing at once would spend one twice. A token is
       refreshed a minute before it runs out. A call that comes back `401` is refreshed,
       or given the token another session just refreshed, and tried once more; a refused
       refresh (`invalid_grant`) or a second `401` drops the tokens, keeps the account,
       and marks the sign-in `expired`. The model then gets `sign_in_required` as a tool
       result it can relay, like an unconnected person-mode server, and the session's
       server shows `sign_in` in `mcp.status`, which both clients draw as "sign in again".
       A refresh that could not be asked keeps the sign-in. When a sign-in lands, every
       local session that waits for the server asks it for its tools
       (`Troupe.Session.MCP.signed_in/1`). `mcp.sign_out` forgets it on this machine.
     - **A pod session gets none of this yet, and never the token.** The path is there in
       the protocol: a client offers tools it hosts through `tools.register` with a
       consent round trip, and serves `tool.invoke` (section 8); the pod sees names,
       schemas, arguments and results, and the call is made on the person's machine. What
       is missing: a daemon method that lists a person's own servers' tools and calls one
       outside a session, and a client that registers them with a pod session it attaches
       to — the desktop app's library has `registerTools` and `onToolInvoke` and nothing
       uses them, and the TUI's remote connection answers no `tool.invoke` — with the
       consent shown to the person and the registration made again after a reconnect.
       That is the next slice, issue #308. A server without `oauth` that answers `401` is
       `error`, naming `oauth.client_id`, rather than unreachable.
     - **Out of this slice.** Dynamic client registration and client ID metadata
       documents, for a provider that offers them, so a person needs no client id; a
       confidential client's secret; a step-up sign-in on `403 insufficient_scope`;
       revoking the refresh token at the provider on sign-out; the session handshake a
       stateful streamable-HTTP server wants (`initialize` and `Mcp-Session-Id`), which the
       one-shot client from 654 still does not make.
     - **Proof:** `Troupe.MCPOAuthTest` (against `test/support/fake_oauth.exs`, an
       authorization server with a path issuer and no registration and a server that
       wants a person: the session waiting, discovery in order, PKCE, `state`, the resource
       indicator, the redirect, the tools with the token, one refresh for five askers, a
       `401` refreshed, a refused refresh turned into `sign_in_required` and back, a
       refusal kept, a forged answer turned away, the store's mode, no token in an event),
       `Troupe.Gateway.MCPSignInTest` (`mcp.sign_in`, `auth`, `mcp.sign_out` over the
       daemon's socket, and the refusals), the TUI's `Troupe.MCPPageTest` and the GUI's
       `local-sources.test.ts` and `servers-panel.test.tsx`.

742. **The chart keeps the namespace it makes and can be told not to make one, and a count
     the cluster did not take is sent again.** Issue #303, D44 and D40 in
     docs/developer/defects.md. `templates/namespace.yaml`
     rendered the release's namespace as an ordinary resource, so `helm uninstall`, a
     reinstall, or a GitOps controller's remediation that uninstalls deleted it with
     everything else in it: an OpenBao beside the plane, the Secrets the chart expects, volume
     claims, the `WorkerProfile` resources. It now carries `helm.sh/resource-policy: keep`, as
     the default `TroupePolicy` already did; an upgrade puts the annotation on the live
     namespace and in the release's manifest, which is what an uninstall reads.
     `createNamespace` (true by default, so an upgrade changes nothing else) leaves the
     namespace out where something else made it: Helm refuses to take over a namespace it did
     not make, and the install guide's order, the Secrets first, makes one. Turning it off on
     an install from an older chart is safe only after one upgrade with it on, because an
     upgrade deletes what the chart stops rendering unless the live object says keep. Not
     chosen: dropping the namespace from the chart, which would delete it at the next upgrade
     of every install that has no keep yet.

     In direct mode the scaler wrote the row and then the cluster, and judged the next tick by
     the row, so a write the cluster refused was never sent again. On a tick that changes no
     count it now reads the resource's `spec.replicas` back and sends the row's count where
     they differ, the comparison gitops mode's pass already makes. Not chosen: writing the row
     only after the cluster took it, which would let any other write from the row (an edit, a
     grant, a release) put the old count back in between. Proof: `scaling_test.exs` ("a count
     the cluster did not take") and the chart job's "The namespace outlives the chart".

743. **A read writes nothing over a log an activation has, and a reader whose log has
     gone does not answer from it.** Issue #302. Decision 732 put a reader's restore of the
     log and its removal under one lock per session on the pod, and left three gaps where a
     `session.read` meets a `session.activate` of the same session, which the pod's link
     runs at the same time. `Reader.open` looked for a manager before it started the reader
     and not again, so an activation that registered while the reader fetched the segments
     had storage's copy written over its log, losing what it had logged since its last
     seal. The reader now looks where it writes, under the lock (`Restore.events/3` with
     `unless_active`), writes nothing if a manager holds the session's name, and the read
     is answered as one of a running session. An activation looked for a log already on
     the pod outside the lock, so a reader writing its log as the manager registered went
     unseen and a failed activation removed it from under whoever read it; the activation
     now looks under the lock, once it holds the session's name, so a reader has either
     written and its log is found, or finds the name taken and writes nothing, and the log
     the activation wrote is removed under the lock too. A reader whose log is no longer
     the one it restored, taken over by an activation and erased when that one put the
     session back to sleep, answered a later read from the history it had until its next
     idle tick, with nothing on disk; asked now, it goes, giving up its name after it has
     dealt with its log, and the read starts another over what storage has, once. The lock
     is still the only one either side takes, and nothing done under it calls a manager or
     a reader, so neither can hold it waiting for the other. Proof: the cases of a read
     racing an activation in `reader_log_test.exs` and `failed_activation_test.exs`, each
     failing before this change.

745. **The desktop app shows a turn the root failed as a failure, and follows a daemon that
     restarted to where it is now.** Defects D42 (the desktop app's part) and D41, following
     727 and the redial of PR #263.
     - **A failed turn is a failure wherever the app says how a session is.** `turn_ended`
       with `agent_failed` folds into the transcript as a note in the error colour, "the
       agent kept crashing and the session stopped: <detail>", and the session's status
       reads Failed, the detail on hover, until the next input starts a turn. A turn that
       ends any other way is still a rest and says nothing. A notification says "The turn
       failed: <detail>", in a loop too, since the loop stops with the session. A turn
       `tool_failures` ended is still shown only as the failure guard's question answered
       `stop`.
     - **The daemon's listing says it, read from the log.** A session stops on a failed
       turn, so nothing live is left to report it, and an app that was not watching had a
       dormant row like a sleeping session's. `session.list` rows carry `failed`: `{reason,
       detail}` from the root's last `turn_ended` when that is `agent_failed` and no input
       has come since, otherwise null, read from the log as `interrupted` is. A field and
       not a new `status`, which every other reader of the status would meet unannounced.
       The launcher's row and the list's say Failed, and the notification for a session
       nobody is reading says the turn failed rather than that one finished. A plane's rows
       carry no reason, so a team session's row is as it was.
     - **A redial reads where the daemon is.** A daemon that restarts serves a new port with
       a new token (`loopback.ex`), and the client dialled the old pair until a person
       pressed Find. `DaemonClient` takes `locate`, which it asks before dialling after a
       dropped socket or a failed dial, and dials what it answers; views open across it
       subscribe again from their cursors, as #263 made them. The desktop shell's
       `readDaemon` reads `daemon.json` with the command `findDaemon` reads it with, and
       starts nothing: starting is Find's, which a person asks for, and a daemon somebody
       stopped stays stopped. A browser build has nothing to read and dials where it was
       told.
     - **Connected again when a dial works.** `useDaemon` said "not answering" when the
       socket closed and nothing said otherwise after; the client's `onOpen` does, with the
       address it reached, which This computer shows.
     - D41's last item, whether Windows raises `Activated` in the running app for a click
       in the notification centre, is still unverified.
     - **Proof:** the desktop app's `failed-turn` and `daemon-restart` tests and the
       client's `stage2`, `transcript` and `fleet` tests, against the fake daemon, which now
       restarts on a new port with a new token and lists `failed` as the daemon does;
       `crash_loop_test.exs` (listed, and cleared by the next turn) and the gateway's
       `daemon_test.exs` (over the socket).

746. **An MCP server is opened with the lifecycle's handshake, and the session it issues is
     kept by whoever calls it, per server and credential, opened again once on a `404`,
     and ended when the caller stops.** Issue #319. `Troupe.MCP.Client` sent `tools/list`
     and `tools/call` as lone POSTs with no `initialize` before them and kept nothing a
     server answered, so a server that keeps state per client, and refuses a request
     without the `Mcp-Session-Id` its `initialize` issued, could not be used from a local
     session or a pod at all. That is the handshake 741 left out.
     - **The handshake, once.** Before the first request to a server: `initialize` with
       the version Troupe speaks (`2025-06-18`), then `notifications/initialized`, whose
       answer is waited for and not read. Every request after carries the session id the
       server answered and, in `MCP-Protocol-Version`, the version it chose. A server that
       answers with no session id keeps none, and is called without one, as before.
     - **Where the session lives.** `Troupe.MCP.Sessions`, an ETS table owned by a small
       process in the caller's supervision tree: one per local session, before
       `Troupe.Session.MCP`, and one per pod, in the worker's application before
       `Troupe.Worker.MCP`. A `Troupe.MCP.Server` carries the table as `sessions`, so the
       tools built at discovery find it, and `client.ex` stays the only module that talks
       to a server. Not one table for the node: `troupe_protocol` has no application to
       own it, and a session's MCP sessions should end with it. Not the state of
       `Troupe.Session.MCP`: the lookup is on every call's path, and a table is read
       without queueing.
     - **The key** is the server's URL and a hash of the headers the call carries, which
       is the credential: a person's token and a profile's are two sessions, as a server
       that binds a session to whoever opened it needs, and a refreshed token opens a new
       one. Not keyed on whose credential it is, which the client does not see for every
       caller and which would present one token's session with another.
     - **A forgotten session.** A `404` to a request that carried a session id drops it,
       opens one more and sends the request again, once. Two calls that open a session at
       once both finish the handshake; `:ets.insert_new/2` keeps one and the other is ended.
     - **Its end.** The holder traps exits, and when its supervisor stops it, after the
       servers that use it, it sends each session a server issued a `DELETE`, a few seconds
       at most, whatever the answer (`405` included). That needs the credential the
       session was opened with, so it is kept beside it, except a person's on a pod, which
       is held for as long as a call takes (`Troupe.MCP.person_credential/2`): that session
       is left to the server's expiry. A call with no holder (`mcp.check` on a server not
       in a session) opens a session for its one request and ends it after;
       `Client.initialize/1`, the bare call sign-in discovery makes, ends any session it is
       given.
     - **Out of this slice.** A `400` to a request that carried a session id, which some
       servers built from the SDKs' examples answer for a session they have forgotten, is
       an error rather than a reason to open another. A session left behind by a refreshed
       token is ended only when its holder stops. Streams the server opens (`GET`) and
       resuming one.
     - **Proof:** `Troupe.MCPHandshakeTest`, against `test/support/fake_mcp.exs`, which
       refuses a request without its session id (`400`), with one it has forgotten (`404`)
       or with another credential than the session's (`403`), answers an older protocol
       version, and ends a session on `DELETE` or refuses it (`405`): an agent lists and
       calls the tools in one session carrying the version the server chose, a forgotten
       session is opened again once, the session ends when the local session stops and a
       `405` is let be, two credentials are two sessions, a server that keeps none is
       called without one, and a check's session lasts its one request; and
       `Troupe.Worker.MCPTest`: discovery per server and credential, every session of a pod
       in the profile's one, a person's in their own, a forgotten one opened again, and the
       pod's stopping. The fakes in `Troupe.MCPTest` and `fake_oauth.exs` now answer the
       `notifications/initialized` they had never been sent, with `202`.

747. **A worker calls an MCP server as its profile's own identity, by OAuth client
     credentials with an assertion signed through OpenBao transit; the profile says who it
     is, and the bundle only that the server is called so.** Issue #315. A bundle server
     was reached from a pod with one static token from a Secret, and servers that take
     machine callers only by client credentials, want a private key JWT (RFC 7523) rather
     than a shared secret, issue tokens for an hour and grant tools per client could not
     be reached. Federated workload identity (the pod's own ServiceAccount token as the
     assertion) needs a publicly discoverable issuer, which some managed clusters do not
     allow, so the credential is a certificate whose key OpenBao keeps.
     - **Where it is configured: a field on the `WorkerProfile`**, decided on the issue.
       The bundle marks a server `credential_mode: client_credentials` and names no
       reference (one beside it is refused at publish, as `secret_ref` beside `person` is);
       a channel serves several profiles and each is its own client at the server. The
       profile's `spec.mcpIdentities`, one entry per server keyed by `server`, has
       `clientId`, `scope`, `tokenUrl` (absent: the authorization server's metadata, found
       as 741's sign-in finds it), `transitKey`, `keyVersion` (absent: the latest),
       `certificateThumbprint` (the `x5t#S256`, base64url, or as `openssl -fingerprint
       -sha256` prints it) and `algorithm` (`RS256`, the default, or `PS256`). Nothing in it
       is secret, so it is in git in gitops mode and in the row in direct mode, the owner's
       to write in both; the plane projects only `credentialMode` onto `mcpServers`.
       `tokenUrl`'s host is egress, in `egress_destinations/1` and the admission policy.
     - **How the key is used: through transit, never read.** The worker builds the
       assertion (`iss` = `sub` = the client, `aud` the token endpoint, `iat`, `nbf`, five
       minutes to `exp`, a random `jti`; header `alg`, `typ`, `x5t#S256`), sends its
       signing input to `transit/sign/<key>` with SHA-256 (`pkcs1v15` for RS256, `pss` with
       a salt the length of the hash for PS256, which JWS requires and transit's default
       is not) and the pinned version, and appends the signature. The key is imported with
       `bao transit import` and is not exportable; not even the worker holds it.
     - **One token per server in the worker, renewed before it runs out.**
       `Troupe.Worker.ClientCredentials`, one process, so two sessions asking at once ask
       the token endpoint once: a token is handed out until a minute before it expires (or
       three quarters of its life when that is shorter), and the call after that gets a new
       one; a token got as an identity the profile no longer describes is not handed out
       again. `Troupe.MCP.authorized/2` puts it in `Authorization` through the server's
       `credential` and, on a `401`, asks once for a token other than the refused one and
       tries once more; a second `401` is the call's error. Discovery and calls both go
       through it, and `troupe_core` reaches the token through a function the worker
       installs (`:profile_tokens`), as it reaches a person's credential. The token is in
       no log line, error or event; the event log records the call as the profile's, as
       before.
     - **Rotation without a restart.** The operator writes the identities into the
       ConfigMap `troupe-mcp-identities` in the worker namespace and mounts it as a
       directory, and the worker reads the file again whenever it asks for a token. A
       variable in the pod template would have made every change a new revision and a
       drained, replaced pod (726); the kubelet replaces a ConfigMap volume in place. To
       rotate: register the new certificate beside the old, import the new key as the next
       transit version (`bao transit import-version`), change `keyVersion` and the thumbprint
       together, and remove the old certificate once the old tokens are out. The pinned
       version is why there is no gap: transit's latest alone would sign with the new key
       under the old thumbprint, or the other way round, until both halves had landed.
       The operator's ClusterRole gains ConfigMaps, and a ConfigMap is pruned with the
       identities.
     - **Profiles kept apart at OpenBao.** `Troupe.KMS.Policy.mcp_identity/2` lets a pod
       sign with `transit/sign/<its namespace>.*` and nothing else, templated on the
       namespace Kubernetes auth vouched for, as the person policy is on the subject: one
       policy on the one worker role, and a pod of one profile cannot sign as another, nor
       with the plane's session-token key, whose name has no dot. Hence transit keys are
       named `<worker namespace>.<anything>`. The dev cluster's job writes it; an
       installation writes it once with its Kubernetes mount's accessor.
     - **Reported, not refused.** A server marked `client_credentials` with no identity,
       or an identity without its client or key or with a malformed field, is the
       operator's `MCPIdentityMissing` condition and the plane's `identity_problems` in
       `admin.profile.get` and `admin.profile.put`, from one function
       (`WorkerProfile.identity_problems/1`), the plane reading the channel's current
       bundle: the bundle and the profile are written by different people, and either may
       be first. The pods start regardless, without that server's tools. A worker's errors
       name the server and the cause: the token endpoint refused the client (with the
       provider's `error` and description), the transit key is not in OpenBao, the pod may
       not sign with it, or the server answered `403` to a tool the identity lacks.
     - **Out of this decision.** Federated workload identity as a second credential kind;
       the console's view of `mcpIdentities` (the integrations page says a server is the
       profile's own identity, nothing more); an existing installation applies the new
       `WorkerProfile` CRD (Helm does not upgrade CRDs), the chart's operator ClusterRole,
       and the policy above.
     - **Proof:** `Troupe.Worker.ClientCredentialsTest`, against the development OpenBao's
       transit and a fake identity provider and MCP server (`FakeIdentityProvider`) that
       verifies the assertion's signature against the registered certificate's key with
       its algorithm, `aud`, `exp`, `jti`, `x5t#S256` and scope, and answers only its own
       tokens: tools listed and called as the profile with one token, renewal before expiry
       in the same processes, one new token after a `401` and none after the second, a
       `403` for a tool the identity lacks, a second identity seeing only its tools, PS256,
       the token endpoint from metadata, a rotation used from the next token, a pinned
       version after a rotation, a refused client, a missing key and a missing identity
       named, and a session's event log with the call's result and no token; failing on the
       tip, where nothing could get such a token. `open_bao_test.exs` (signatures that
       verify, a pinned version, a missing key, the policy against a real token),
       `worker_profile_identity_test.exs`, `bundle_test.exs`, the operator's
       `resources_test.exs` and `reconciler_test.exs`, the plane's `bundles_test.exs` and
       `admin_test.exs`, and `mcp_test.exs` for the core's half.

748. **A person's own signed-in servers are offered to a pod session they open in the
     desktop app, as tools the app hosts, and the daemon makes every call with their
     sign-in.** Issue #308, the first part, following 741. What was there: a server a
     person signed in to served their local sessions only. A pod session reads none of the
     person's files and holds none of their sign-ins, and the protocol's path for tools a
     client hosts (section 8) had nothing in the app using it.
     - **The daemon lists and calls a server outside any session.** `mcp.tools {name}`
       answers the server's tools with their descriptions and schemas, asked as a local
       session asks (`Troupe.Session.MCP.discover/1`), with `state` and `error` as
       `mcp.check` reports them. `mcp.call {name, tool, arguments}` makes the call through
       `Troupe.MCP.Tool.invoke/4`, the path a local session's tool takes, so a refresh and
       one more try on a `401`, and the `sign_in_required` note once the sign-in has run
       out, are the same, and `content` is what a local session's model would read. Both
       are `admin` and the daemon's only, like the rest of `mcp.*`. A server with a `url`
       only: one that runs a command is a process a local session keeps, and starting one
       per call for somebody else's session is a question of its own. A refused, disabled
       or unapproved workspace server is refused, as for a sign-in. `mcp.call` carries a
       `command_id`, which the app makes from the session and the pod's `call_id`, so a
       call the pod sends again after a drop is answered from the ledger rather than made
       twice.
     - **The desktop app offers them** (`ServerOffer` in `@troupe/client`). On a team
       session opened on its own screen, with a daemon to make the calls and a token with
       `control`, it lists the person's servers whose sign-in stands `signed_in`, asks the
       daemon for each one's tools, and registers them with `tools.register`. The session's
       challenge is shown in a panel where the approval and question panels sit, in the
       session's words and naming the servers, and **Offer them** sends it back with the
       person's subject as `confirmed_by`. Every signed-in server rather than a choice
       among them: the prompt names every tool, the person can say no to the lot, and a
       choice per server is a refinement the first slice does without. Names are
       `<server>.<tool>`, so the pod sees `client.<server>.<tool>`, under the prefix no
       built-in and no profile's `mcp.<server>.<tool>` carries, and two servers' tools
       never meet. Their permission is the default `ask`: the consent is to offering the
       tools, not to every call, and the entry's own `permission: auto` is about the
       person's own sessions.
     - **A `tool.invoke` goes to `mcp.call`**, and only `{content}` goes back to the pod. An
       error from the daemon goes back as an error.
     - **Again on every socket.** `SessionAttachment` takes `onToolInvoke`, and says
       `tools` at `initialize` when given one, and `onLive`, called on each socket it
       opens. A registration goes with its socket, so each new one is offered the tools
       again; the session issues a fresh challenge per socket, and the app answers it with
       the consent the person gave for the same tools in this attachment rather than asking
       again, since a parked call has the call grace, a minute, and asking again for what
       was just allowed teaches people to say yes without reading. A different set of
       tools is asked about again, and **Not now** holds for the attachment. Leaving the
       session's screen closes its socket, and the tools go with it.
     - **No token reaches the pod or the plane.** The pod is sent the tools' names,
       descriptions and schemas, the consent, and each answer's text. The daemon uses the
       token on its call to the server, and no answer of `mcp.tools` or `mcp.call` has it.
     - **Out of this slice.** The TUI's half (#308); offering again when the person signs
       in to another server while attached; choosing servers; a stdio server; the reason
       of a client's error reaching the pod's model (the pod's `ClientTool` reads only an
       error's `message`); dynamic registration, step-up and revocation (#308); the session
       handshake (#319).
     - **Proof:** `Troupe.Gateway.MCPCallTest` (against `fake_oauth.exs`: listing and
       calling with the sign-in, a refresh on a `401`, `sign_in_required` before a sign-in
       and after a refused refresh, the refusals, and a session started as a pod's, whose
       agent calls the person's server through the client that offered it, with no token in
       its log), the client's `own-servers.test.ts` (a fake pod and daemon: the call made
       by the daemon, no token in any frame the pod got, offered again on a new socket
       without asking, a no kept, a reader offering nothing) and the desktop app's
       `own-servers.test.tsx` (the panel, the line, and a call through the app).

749. **Without Cilium, a profile's own endpoint its workers cannot reach is refused where it
     is set up, and reported on the profile where nothing could refuse it.** Issue #268, its
     smallest option; admitting such an endpoint without Cilium stays open there. Without
     Cilium a worker's NetworkPolicy reaches outside the cluster through public IPv4
     addresses on 443 and 80, and a `*.svc` host through its namespace; 724 added the
     installation's own OpenBao and object store and nothing of a profile's. So an LLM
     gateway on 8443, or an MCP server at an address on the office network, was saved,
     applied and reconciled without a word, and a session found out at its first call.
     `Troupe.WorkerProfile.Reach` now says, a sentence each, which of a profile's LLM
     endpoint, MCP servers and `egress.fqdns` entries such a worker does not reach: a port
     other than 443 and 80 in the URL (or the entry), or a host that is an address in a
     range the public rule leaves out, loopback, or IPv6, which the rule has no block for.
     The public rule's excepted ranges are read from it, so the two cannot drift. A name on
     443 or 80 is taken at its word: a NetworkPolicy cannot name a host and what a name
     resolves to is not known where it is typed, so one that resolves to a private address
     is still not reached and still not said. The git hosts are not checked, as #268 does
     not name them. In direct mode `admin.profile.put`, and so the
     profile editor, refuses a profile whose workers are pods (`invalid_params`, the
     sentences as `unreachable`, and with why and what to do as `reason`, which the editor
     shows), counting the servers its channel's bundle hands its pods, and publishing a
     bundle naming such a server to a channel a profile whose workers are pods follows is
     refused (`invalid_bundle`, naming the profiles). A profile whose workers are machines
     has no NetworkPolicy and is not checked (738). The operator reports it in either mode
     as `EndpointUnreachable` (`True`, `NoCilium`, the same sentences), beside `Ready` as
     `SecretMissing` is, since the profile reconciled; it is how a profile a repository
     holds, applied where nothing could refuse it, reads as broken on the Workers page.
     What to do is in the message: Cilium, a public address on 443 or 80, or for an
     endpoint in the cluster its Service's name. With Cilium nothing is refused and the
     condition is `False`. The plane learns which from the chart, which now gives it
     `operator.ciliumAvailable` as `TROUPE_CILIUM_AVAILABLE`, as it gives the operator: that
     setting decides which rules the operator writes, so it, and not the cluster's CNI, is
     what a pod will reach. The operator's `EgressByHostname` condition says the same, but
     only of a profile it has reconciled, which the one being written is not. A plane told
     nothing, run without the chart, refuses nothing, and the operator still reports. Not
     chosen: admitting a profile's endpoint on its port as 724 admits the platform's,
     which would open that port to every public address for one profile's gateway; and
     CIDRs a profile names, which needs a field and a policy for it. A NetworkPolicy an
     installation adds to the worker namespace, 724's remedy for the platform's endpoints,
     does not get a profile past the refusal. (752 admits the first after all, and what is
     refused and reported is now an endpoint at a loopback or link-local address; 758
     refuses that with Cilium too, and the plane is no longer told about Cilium.) Proof: `reach_test.exs` in the protocol (the
     sentences: ports, each range, IPv6, `*.svc`, names, entries) and in the plane (the
     refusal and its message, a name on 443 and a Service saved, machines, a channel's
     server, with Cilium, a plane told nothing, the bundle, the editor, the Workers page),
     and `reconciler_test.exs` (the condition without Cilium, with it, and reachable); the
     plane's refusals and the operator's three cases failed on the chunk tip.

750. **On a plane, a turn the harness stopped is a failed turn: the row says why, the run
     is failed and its target is told, and a pod whose session stopped under it puts it to
     sleep then.** Issue #320, defect D47, following 687, 727 and the daemon's `failed`
     (745).
     - **The worker reports `failed_reason`.** `turn_ended`'s `reason`, `tool_failures`
       (the failure guard's `stop`) or `agent_failed` (a root that crashed as often as it
       may be restarted), goes into `session.status` and the dormancy report beside
       `done_reason`, from that `turn_ended` until the root's next `user_input`; an
       activation reads it back from the log as it reads `interrupted`. The words are the
       event's. The turn's end also rests the root in the report, because a root that
       crashed sends no `agent_state` after it. A field and not a new `status`, for 745's
       reason.
     - **Not 745's `failed`.** The daemon's `failed` is `{reason, detail}`, for
       `agent_failed` only, and `detail`, the first line of what the agent raised, is
       content, which a plane never holds. A string under its own name carries the reason
       alone, for both stops, and no key a client reads changes shape between a daemon and
       a plane.
     - **The plane keeps it** on the session row, set whenever a report carries the key,
       as `done_reason` is, and lists it in `sessions.list` and a run's listing. A run
       whose session has one is `failed`, awake or asleep (it read `running`, then
       `created`), and holds no place under its trigger's concurrency cap. The status page
       calls the row broken even asleep, since a root that kept crashing is always asleep
       after it; the review queue and the runs table name the reason.
     - **`notify_url` is posted the outcome, read from the row.** A report with a reason
       announces the run as `done` and `interrupted` do. The body's `state` is the run's
       state as a listing gives it, `done` or `failed`; it was the worker's status, so an
       `interrupted` run now says `failed`. `done_reason`, which the body named and was
       never given, is filled, and `failed_reason` is beside it.
     - **The manager watches its tree.** A tree that stops by itself (727) was noticed only
       when the idle timer next looked, ten minutes on: the slot and the budget slice held,
       and an activation answered `ok` for a session that was not there. The manager now
       monitors the session it started and puts it to sleep when it stops, sending first a
       report the debounce held, since that is the one that announces. The cost is folded
       from the log left on the pod, because the projection that knew it went down with
       the tree and the dormancy report said `0`.
     - The desktop app's team rows don't read `failed_reason` yet.
     - **Proof:** the worker's `stopped_turn_test.exs` (a tool that fails ten times with
       nobody to ask; a root that keeps crashing, asleep within seconds with its cost; the
       same session woken, saying so until a turn starts) and `approval_status_test.exs`
       (the fold over a recorded log), and the plane's `triggers_test.exs` (a pod's report
       makes the run failed, on the row and in the post, with no place under the cap; a
       crashed session asleep is failed and broken, and told once). Each failed before
       this change.

751. **The person is the claim `subject_claim` names, `sub` by default and `oid` for Entra
     ID, and a plane switched to another claim moves each person it already knows once, at
     their next sign-in.** Issue #267, the other half of defect D9. Entra's `sub` is
     pairwise, a different string in every app registration and no attribute its SCIM
     client can send, so the person SCIM made and the same person signing in were two rows.
     - **One setting, every door.** `subject_claim` (`TROUPE_OIDC_SUBJECT_CLAIM`,
       `plane.oidc.subjectClaim`) is read in `Login.from_claims/1`, which the CLI's and the
       desktop app's exchange, the console's sign-in and an MCP client's provider token all
       go through. SCIM's subject stays `externalId`, else `userName`; for Entra the
       provisioning mapping sends `objectId` as `externalId`. `oid` is unique within a
       tenant and the plane trusts one tenant's issuer, so `tid` is not part of it. A token
       without the claim is refused as `{:no_subject, claim}`, which names it. A provider
       whose `sub` already is what SCIM sends keeps the default, and nothing changes there.
     - **The deployment's, not the console's.** Shown on the Identity provider card and not
       editable there, as `provisioning_mode` is (736): switching it moves people, and
       switching back does not move them back, since somebody moved to `oid` is not found
       under their `sub`. A setting `reset` cannot undo is not one to offer beside a reset.
     - **A move, not a fresh start.** Somebody not found under the claim's value but found
       under the `sub` the same token carries is the same person by the provider's word in
       one signed token, and that token would have signed in as them the day before, so
       moving them gives it nothing it did not have. Their row is renamed. If SCIM
       provisioned them under the new value first, which is the order an Entra rollout
       usually goes in, the old row is folded into that one and removed, so SCIM's own id
       for the person stays good; their own spend ceiling is kept where SCIM's row has none.
       Moved is every column that says *who*: a session's owner and the sponsor in a run's
       origin (whose cap it counts against), ACL entries, shares made out to them, the teams
       they administer, triggers' `notify`, usage records and open reservations, and the
       principals they sponsor (left behind, deprovisioning them would leave those firing).
       What says *who did*, the hash-chained audit trail and every `*_by`, keeps the name it
       was written with. One transaction with the old row locked, so two devices signing in
       at once move the person once; afterwards nobody is under the old value, and the next
       sign-in has nothing to do. Logged and audited as `person.rekey` with the two
       identifiers and the claim's name, and nothing else from the token.
     - **A plane token minted before the move is refused**, `unauthenticated` with "no such
       user", as a disabled principal's is, because the router resolves the subject on every
       request. Honouring it would need a second name per person that every lookup by
       subject knew, for one token lifetime of fifteen minutes; a client exchanges again on
       its own. A console session holding the old name is turned away and signs in again.
     - **The key manager is not moved**, since the plane holds no credential that can read
       or write it (375, 377), and does not need to be: a person's name there is not their
       subject (755).
     - In `gitops` mode a trigger's `notify` is the repository's, and the next change to the
       resource puts back whatever the repository says.
     - **Proof:** the plane's `subject_claim_test.exs`: with `oid`, an Entra-shaped user
       SCIM provisioned and the same user signing in are one person; the default, with an
       Authentik-shaped `sub`, unchanged; a person known by `sub` moved once at their next
       sign-in, keeping a session, the team they administer and the team they are in, and
       every other column above moved while `created_by` and `granted_by` are not; a second
       sign-in moving nobody; SCIM first, folded in; a token without `oid` refused naming
       it; a plane token from before the move refused. The first and every move failed on
       the chunk tip.

752. **Without Cilium, a profile's own endpoints are admitted as the installation's are: a
     name on another port as the public rule's addresses on that port, an address as that
     one address on its port. One at a loopback or link-local address is admitted by
     nothing, and is what is still refused.** Issue #268, its second part, as decided
     there; 749 did not choose this. 749 refused an LLM gateway on 8443, or an MCP server
     on the office network, where the profile was set up, so an installation without
     Cilium that ran its gateway in-house could not use it.
     - **What is admitted.** The worker NetworkPolicy gives each of a profile's endpoints
       the public rule does not reach a rule of its own, as 724 does OpenBao and the object
       store: the LLM endpoint, each MCP server (its own, and its channel's bundle's
       through the `mcpServers` the plane projects) and each `egress.fqdns` entry, whose
       port is written `host:port`. An entry with none is reached where a name is, on 443
       and 80, an address as itself on those. An IPv6 address, which 749 refused because
       the public rule has no v6 block, is its `/128`. A public address on 443 gets its
       own rule too, as 724's do; a name on 443 and 80 needs nothing and is unchanged. No
       CRD change.
     - **The cost is 724's.** A name on 8443 opens 8443 to every public address for that
       profile's workers, which is as much as a NetworkPolicy can say about a name. A name
       that resolves to a private address is still not reached and still not said, since
       what it resolves to is not known where it is typed; the docs say to give it as its
       address or use Cilium.
     - **Loopback and link-local stay refused,** `127.0.0.0/8`, `::1`, `169.254.0.0/16`
       and `fe80::/10`, and a v4 address in v6 spelling (`::ffff:169.254.169.254`) is the
       v4 address it names, where the connection goes. From a pod, loopback is the pod
       itself, and link-local is the node's, where a cloud's metadata service answers: a
       rule would open that to the pod for one profile's endpoint. These are what
       `admin.profile.put`, the editor, a bundle's publish and `EndpointUnreachable` name
       now, and the message says why and to give the endpoint as a pod reaches it.
     - **One judgement.** `Troupe.WorkerProfile.Reach` judges each endpoint once, into the
       rules that admit it (`admitted/1`, through `admission/2`, which the operator also
       uses for the platform's endpoints) or the sentence that refuses it
       (`unreachable/1`), and the public rule's ports and ranges are read from it. So the
       NetworkPolicy, the refusal and the condition cannot disagree about an endpoint.
     - The git hosts and an MCP identity's token endpoint are still not judged, as #268
       does not name them. With Cilium nothing changes.
     - **Proof:** the protocol's `reach_test.exs` (admissions and refusals: ports, both
       families, the ranges' edges, the v6 spelling, entries with and without a port, the
       platform's), the operator's `resources_test.exs` (a name on 8443, private and public
       addresses in both families, entries, loopback and link-local admitted by nothing, a
       port the platform shares, the Cilium path) and `reconciler_test.exs` (the condition
       reachable for the gateway and the server, beside their rules; named for loopback and
       link-local), and the plane's `reach_test.exs` (saved, refused, a channel's server,
       the bundle, the editor, the Workers page). The operator's NetworkPolicy and
       condition cases and the plane's saves failed on the chunk tip.

753. **A worker logs in to OpenBao under the role its pod is given and keeps the login
     until shortly before it runs out; the operator names a role per profile where the
     installation made them, and says a person-mode server's mode.** Issue #336, defect
     D52. What was there: the worker's configuration never read `TROUPE_BAO_ROLE`, so every
     pod logged in as `troupe-worker` and the per-profile policy `Troupe.KMS.Policy.worker/2`
     renders could not be bound to one profile's pods; `Troupe.KMS.OpenBao` logged in again
     for every request; and a person-mode server reached a pod's `TROUPE_MCP_SERVERS`
     without its mode.
     - **The role is the pod's.** The worker reads `TROUPE_BAO_ROLE`, `troupe-worker` when it
       is unset. The operator writes it as `troupe-worker-<profile>`
       (`Policy.worker_role_name/1`, the name of the profile's policy) when the chart's
       `bao.workerRolePerProfile` (`TROUPE_BAO_WORKER_ROLE_PER_PROFILE`) is on, and nothing
       otherwise: an existing installation's pod templates are unchanged and its pods keep
       logging in as `troupe-worker`. A switch rather than a role name with a placeholder,
       because the name follows the policy's and the one thing an installation decides is
       whether it made the roles. Each such role is bound to the ServiceAccount
       `troupe-worker` in its profile's namespace, audience `troupe-kms`, and carries the
       profile's policy and, where its profile calls an MCP server as itself,
       `troupe-worker-mcp-identity` (747), which does not change: it is templated on the
       namespace Kubernetes auth vouched for, not on the role. Once every pod is on its own
       role, the installation deletes the shared `troupe-worker` or takes its wide policy
       off, since a pod names the role it asks for. Turning the switch on is a new pod
       template for every profile, which reports `UpgradePending` until its pods are
       replaced.
     - **One login, kept.** `Troupe.KMS.OpenBao.Login`, one process first in the worker's
       tree, holds the client token per OpenBao address, mount and role, and hands it out
       until a minute before its lease ends, or three quarters of the lease when that is
       shorter (747's rule for a profile's tokens); a lease of zero does not end. A request
       whose login token is answered `403` asks for one other than it, new unless another
       caller already got one, and is made once more; a second `403` is the answer. A static
       token is never retried. Outside a tree that started it, each call logs in, as before.
       A failed login is logged with the role and mount; the token and the projected JWT are
       in no log line, and `format_status` keeps both out of the process's state and last
       message.
     - **A person-mode server says so before the first bundle.** The operator writes
       `credential_mode: person` and the slot as `credential_ref`, the bundle's own shape,
       where a pod read such a server as one it calls as the profile, with no credential,
       until the plane's bundle arrived. 747 left the mode out so that no profile's
       template changed; here the cost is taken: on upgrade every profile with a
       person-mode server has a new template once and reports `UpgradePending` until its
       pods are replaced. Profile mode, the default, is still left out.
     - **Out of this decision.** Nothing writes the roles or the policies, and a profile's
       policy names its granted teams, so the installation writes it again when they
       change; the worker's auth mount is `kubernetes` (`TROUPE_BAO_AUTH_PATH` is the
       plane's); the development cluster keeps its one role.
     - **Proof:** the worker's `bao_login_test.exs`, against the development OpenBao behind
       a fake Kubernetes login (`FakeBaoLogin`) that issues OpenBao's own tokens with the
       role's policy and lease: the role read from `TROUPE_BAO_ROLE` through
       `config/runtime.exs` and logged in under, `troupe-worker` without it, one login over
       six requests, a new one past three quarters of a six-second lease, one more after a
       revoked token's `403` and none after a second, no token in a log line or
       `:sys.get_status/1`, and none in the events of a session opened with it; five of them
       failed on the chunk tip. The operator's `resources_test.exs` (the role with the
       switch and none without, a person-mode server's mode and slot); the first and the
       last failed on the tip.

754. **The plane's SCIM endpoints answer a filter and take PATCH the way Microsoft Entra
     ID sends them, keep a user's `userName` beside the subject, and never move a person in
     a push.** Issue #340, which #267 needs: with 751 the plane keys a person as Entra's
     sign-in does, and Entra's provisioning client still could not find or change them.
     `GET /scim/v2/Users` ignored `filter` and answered with everybody, a `PATCH` was read
     as a whole user and answered `500`, and `GET /Users/:id` looked the id up as a subject.
     - **One filter, and nothing half-read.** `<attribute> eq "<value>"`, on `userName` or
       `externalId` for users and `displayName` or `externalId` for groups: what a provider
       matches on before it creates. Attribute names and `eq` in any case; a `userName` or
       `displayName` compared ignoring case, as RFC 7644 compares them, and `externalId`
       exactly. Anything else is `invalidFilter`, since an answer to part of a filter is
       read as a match.
     - **`userName` is kept.** Where an `externalId` comes with it, which under 751 is every
       Entra user, the `userName` was nobody's subject and kept nowhere, so Entra's default
       match, `userName eq "<their UPN>"`, answered nobody about a person the plane had:
       each change after the first push would have been a create, and a removal from
       scope a skip. It is a column on `users`, written by a push and a PATCH and rendered
       as `userName`, and the subject stands in for it on a row no push has named. A label,
       as the email is; a sign-in does not write it.
     - **A PATCH changes what a push would**, a user's `userName`, `externalId`,
       `displayName`, email and `active`, a group's `displayName` and members, and accepts
       and ignores the rest (`title`, `name.*`, the enterprise extension), as a `POST`
       does. It is read the way Entra writes one as well as the way the RFC does: `op` in
       any case, a value object without a path whose keys are paths, `"False"` for `false`,
       `members[value eq "<id>"]`. `active: false` is a `DELETE`, and the principals the
       person sponsors stop. It is applied whole or refused whole with SCIM's error body
       and a `400` (a bad op, path or value; removing what is required), never a `500`.
     - **A PATCH does not make somebody else.** One that would key the person on another
       subject, a different `externalId` or, without one, a different `userName`, is
       refused as `mutability`: a person moves at sign-in under 751, with their sessions,
       and a push that moved them would leave those under the old name. A group's
       `externalId` is what a groups claim names it by, and does not change either.
     - **Members by PATCH are a change, not a list.** A push carries the whole list and
       replaces it; a PATCH names members and adds or removes them, read and written in one
       transaction with the group's row held, so two at once do not lose one. An id nobody
       has is nobody to add, as in a push. A group's PATCH answers `204`, a user's the user.
     - **Addressed by the plane's `id`**, `GET /Users/:id` and `/Groups/:id`, and
       `excludedAttributes=members` leaves a group's members out, as Entra asks for groups.
       `DELETE` on a group empties it, which the docs said and the route did not do.
     - Unchanged: `POST` and `PUT`, which upsert on the subject and answer `200`; no
       pagination, bulk, ETags or `/Schemas`. (759 revises this: a `POST` answers `201`.)
     - **Proof:** the plane's `scim_entra_test.exs`, Microsoft's documented provisioning
       requests with `example.test` names, sent to the router as Entra sends them: a filter
       finding one user and nobody, a group by name without its members, and refusals as
       `invalidFilter`; a user and a group by id; a user's whole sequence (filter, `POST`,
       `Replace` with paths, a new `userName`, `Add`, `Remove`, attributes not kept,
       Disable User) leaving one row with those attributes; the value-object form and
       `"False"`; `active: false` stopping a sponsored principal and refusing sign-in; a
       group's members added and removed by value and by path filter, then renamed, one
       row; `DELETE` emptying it, `PUT` still replacing; and refused PATCHes changing
       nothing. All 13 failed on the tip of #339's branch: the filter answered with
       everybody, an unread filter with `200`, and every PATCH raised.

755. **A person's name at the key manager is a column of its own, fixed when the plane first
     knows them and left alone by a re-key, and whatever reaches the key manager for a
     person takes it from the plane.** Issue #341. What a person keeps there, their
     credentials for person-mode MCP servers and their private sessions' data keys, was
     under `troupe/people/<subject>/`, and the plane cannot move that subtree (375, 377), so
     a person moved to another claim (751) connected their servers again and could not
     restore a private session on another device.
     - **The name.** `users.kms_name`, unique. The migration fills it with each person's
       subject, so nothing in the key manager moves and an installation that never switches
       its claim sees no difference. Somebody first known afterwards is named by their
       subject too, rather than by `users.id`: the key manager's tree then reads as the
       people in it, and a daemon older than its plane keeps working for everybody it
       worked for. An id never collides, and that is the one case it is used for: a
       newcomer whose subject is already somebody's name, which only a switched claim can
       bring about (one person's new value being another's old one), is named by their own
       id rather than share a subtree. Nullable, because a replica of the release before,
       still serving during the rollout, writes people without one; `User.kms_name/1` reads
       such a row as its subject, which is what the name was, and a re-key writes that
       down before it moves the subject.
     - **A re-key leaves it.** `Identity.rekey/2` moves the subject and every column that
       says *who*, and not the name. Where SCIM made a row under the new value first, the
       row the old one is folded into takes the old one's name, once the old one is gone:
       everything the person stored is under it, and nobody could sign in as SCIM's row
       without being moved first.
     - **Carried with the assertion.** A pod or a daemon does not derive the name; it comes
       in the answer whose token reaches it. `kms.assertion` answers `key_manager: {name}`
       beside the assertion, and `session.assertion` and `me.connections.grant` add `name`
       to their `key_manager`. The assertion's `sub` is the name, so the person policy,
       templated on the alias name OpenBao takes from `sub`, covers the name's subtree with
       no change to the role, the policy or anything an installation wrote. The pod
       (`Troupe.Worker.Connections`) keeps the name beside the token and reads slots under
       it; the daemon (`Troupe.Gateway.Private`) makes or finds a private session's key
       under it; `me.connections.list` and the console's per-server list ask under it. Not
       carried at activation or in the plane token: those name the session's owner and the
       caller, who are subjects, and a name that arrived apart from its token could
       disagree with it.
     - **Older clients.** A plane that answers no name is from before this, and a pod or
       daemon then uses the subject, which is what the name was there. A daemon from before
       this, against a plane with it, reads under the subject; for a moved person it is
       refused, and their private sessions stay local on that machine until it is upgraded.
       Nobody else sees a difference.
     - **Proof:** the plane's `person_credentials_test.exs`, against the development OpenBao
       and its JWT auth: a credential connected through the grant and a private session's
       key written where `session.assertion` says, before a switch to `oid`; after her next
       sign-in moves her, she is listed as connected, the grant and `session.assertion`
       answer her old name and path, and the tokens they exchange for read both back. The
       worker's `person_credentials_test.exs`: a pod, with a real plane over its link, finds
       the credential before the move and after it, with the session's owner as either
       subject. The gateway's `private_test.exs`: a second device, linked under the new
       subject, gets the key the first sealed with and reads its segment. These three
       failed on the tip of #339's branch. Also the plane's `subject_claim_test.exs` (the
       name kept by a move and by a fold, a newcomer named by their subject or, where a
       moved person has it, their id, a row without one keeping its subject) and
       `control_test.exs` (`kms.assertion` for a moved owner names their old name).

756. **Erasing a private session is final when the plane has destroyed its key, which it
     does itself and at once; the session is `erasure_pending` until then, and its objects
     and the device's copy go when the owner's daemon next connects.** Issue #348.
     `Erasure` handed every erasure to a healthy pod of the session's profile, and a private
     session has none. On the tip the first `session.erase` of one exited in the placement
     actor, which cannot load a `nil` profile, after the tombstone was written: the row
     stayed `active`, every later erase answered `erased: true` from the tombstone, the key
     stayed in the key manager, and `session.assertion` and `session.presign` went on
     answering, so a daemon still running the session could have made a fresh key where the
     old one was and sealed into the erased prefix.
     - **The key, by the plane, now.** With the plane's own credential, whose policy has
       `delete` on `metadata/troupe/people/+/sessions/*` for exactly this and no rule for the
       data path (`Policy.plane/1`): every version goes and none could have been read. That
       revises 90's first sentence for a session with no pod and keeps its reason, since the
       component that decides to erase still cannot read what it erases. Under the owner's
       name at the key manager (755), looked up from their subject. No slot, budget slice or pod to give back, so the drain's park is
       not run, and that is what failed on the tip.
     - **`erasure_pending` until it is gone.** A session state, for a private session whose
       key the key manager refused or could not be reached to destroy. Listed as it is, to
       its owner and to an administrator, so somebody can see an erasure did not finish.
       Nothing seals, keys, signs or lists for it: `session.register` (with `claim` or
       without), `session.assertion`, `session.presign` and `session.objects` answer
       `not_found` with `reason: "erased"`, as they now do for an erased one, and it is not
       forked. `session.erase` answers `erased: false, state: "erasure_pending"`, and
       `admin.session.erase` the same `state`. Erasing again tries again, and so does the
       owner's daemon connecting. A row a plane from before this tombstoned and then failed
       on is finished the same way.
     - **The objects when the daemon next connects.** A daemon connects to its plane when a
       client links it with a plane token. It asks `session.erasures {device}`, the owner's
       erased private sessions this device has not acknowledged, as `pending_for/2` tells a
       pod on enrol; for each it stops the sealer, erases its own copy and answers
       `session.erased {session_id, device}`, and on that the plane deletes every version
       under `sessions/<id>/` and records the device in the tombstone's `applied_by`. After
       the device rather than at the erasure, because the device is the only writer: a
       deletion before it had stopped could be followed by the segment it was uploading.
       By the plane rather than the daemon, which is where this departs from the issue's
       wording: the issue took the objects to be reachable only by the daemon, and the plane
       holds the object-storage credential it signs with (390). `ObjectStore.Signed` keeps
       deletion off a daemon on purpose, and a presigned `DELETE` per version would let a
       person destroy their own session's ciphertext outside an erasure. Only for an erased
       session of the caller's own, since saying a session is erased does not erase it.
       Every device is told until it acknowledges, since any of them may hold a copy; the
       second one finds nothing left to delete.
     - **A device that never comes back.** Its key is gone, so the objects are unreadable to
       anybody, the plane included, and they stay until one of the owner's devices connects:
       the deletion is tidiness, as `Erasure` says of a pod's. The copy on that machine is on
       the person's own disk, which no erasure reaches.
     - **A team session is unchanged**: handed to a healthy pod of its profile, or left for
       the next one to enrol, and its key is never the plane's to touch.
     - **Proof:** the plane's `private_erasure_test.exs`, against the development OpenBao and
       MinIO with a plane credential carrying the plane's policies and nothing more: the key
       destroyed at once under a moved owner's name; `erasure_pending` under a credential
       that may not delete (listed so, not handed to the daemon, everything refused), and
       finished by erasing again, by an administrator's erase and by the daemon connecting;
       a row tombstoned the tip's way finished; the objects, a prior version included, kept
       until a device acknowledges and then gone, that device told once and another until it
       acknowledges; an acknowledgement refused for a live session and for somebody else's;
       and a team session as before, with a pod and without, and never handed to a daemon.
       The gateway's `private_test.exs`: a sealing daemon told of its session's erasure stops
       sealing and erases its copy, the objects go, and it is told once; nothing is deleted
       for a session the plane did not erase; and a link through the daemon is when it
       happens. All but the two team pins failed on the tip of `development-2026-10-03`.

757. **A session a newer credential replaced is ended when the new one is kept, a server
     a bundle drops has its sessions ended, and a `400` to a request in a session is a
     forgotten session, once.** Issue #358, defect D51, and two of the things 746 left
     out of its slice. 746 kept a server's MCP session under its URL and a hash of the
     call's headers and ended it only when its holder stopped. A pod calling a server as
     its profile (747) gets a new token about once an hour, and each opened a new session
     and left the one before open at the server until the pod stopped; a daemon's
     refreshed sign-in (741) did the same for as long as the local session ran. A bundle
     that dropped a server left its sessions open. And a server that answers a session it
     has forgotten with `400` rather than the specification's `404` failed every call
     after it restarted, until the pod did.
     - **What a session is kept for.** The key does not change: two credentials are two
       sessions, and a person's and a profile's are never one. Beside it each session
       records the server it was opened for, by URL and name, and its credential mode
       (`Sessions.kept_for/1`). A call that keeps a new session takes out any kept for the
       same under another key and ends it with a `DELETE` carrying its own credential,
       best-effort and `405` let be, before its request goes out. Not keyed on the server
       and mode instead: a session would then be presented with a token it was not opened
       with, which a server that binds a session to a credential refuses.
     - **Not a person's.** On a person-mode server every person is a caller of their own,
       the client does not see whose credential a call carries, and on a pod it does not
       hold a person's credential to end their session with (746). A person's session a
       refreshed token left behind stays in the pod's table until the pod stops or the
       bundle drops the server, and at the server until it expires it.
     - **Two tokens at once.** A call still holding the old token while another holds the
       new may open one more session in the overlap, and each one kept ends the other's;
       once the old token is no longer handed out (747 hands out one), that stops.
     - **A bundle that drops a server.** `Troupe.Worker.MCP.put_servers/2` keeps only the
       sessions of the new bundle's servers (`Sessions.retain/2`) and ends the rest before
       it discovers again. A server still there by URL, name and mode keeps its session,
       and one whose credential changed has its session replaced by discovery, as above.
     - **A `400` to a request that carried a session id** drops the session, ends it (a
       server may answer `400` for something else and still hold it), opens one more and
       sends the request again, once, as a `404` does. A `400` the new session does not
       cure is the call's error: one handshake more for such a call, never a loop. A
       `400` to a request without a session id is the call's, as before. Read from the
       SDKs: the TypeScript SDK 1.30.0's transport answers `404`, but its example servers
       look the session up before it and answer an unknown one with `400`, `DELETE`
       included; the Python SDK's session manager answered `400` through at least 1.23.0
       and answers `404` on its main branch now.
     - **Proof:** `Troupe.MCPHandshakeTest`, against `test/support/fake_mcp.exs`, which
       now takes `forgotten: 400` and `bad_calls: true`: a credential that replaced another
       ends the session the other opened and leaves a person's be; a session the server
       answers `400` for is opened again once and the call goes through; a `400` a new
       session does not cure is the call's error after one retry, with one session left.
       `Troupe.Worker.MCPTest`: a profile's renewed token, through `:profile_tokens`, ends
       the session the token before it opened, and a bundle that drops a server ends the
       session discovery opened for it, lets go of a person's and keeps the other
       server's. All five failed on the tip of `development-2026-10-03`.

758. **With Cilium as without, a profile's endpoint at a loopback or link-local address is
     admitted by no rule and refused where it is set up, so the plane no longer needs to
     know which.** Issue #355, the first part of defect D54. With Cilium the plane refused
     nothing (749), and the `CiliumNetworkPolicy` writes a host given as an address as a
     `toCIDR` of that one address (723). So a profile naming `http://169.254.169.254/` got
     a rule to the node's metadata service wherever the TroupePolicy's `allowedEgress`
     named the address, and that list was all that stood between a profile and it.
     - **No rule in either mode.** The `CiliumNetworkPolicy` now leaves out every host of
       the profile's that `Troupe.WorkerProfile.Reach.refused?/1` names: loopback
       (`127.0.0.0/8`, `::1`) or link-local (`169.254.0.0/16`, `fe80::/10`), a v4 address in
       v6 spelling as the address it names, the one judgement 752 made for the
       NetworkPolicy. Every host means the git hosts and an MCP identity's token endpoint
       too, though only the LLM endpoint, the MCP servers and `egress.fqdns` are judged and
       named, as before. The installation's own OpenBao and object store are its choice and
       stay as they are. A profile applied in `gitops` mode, which nothing refused, gets no
       such rule either.
     - **Refused and reported in both.** `admin.profile.put`, the editor and a bundle's
       publish refuse such an endpoint whatever the plane was told, and
       `EndpointUnreachable` is `True` in both modes, with the reason
       `LoopbackOrLinkLocal` where it was `NoCilium`; `False` stays `Reachable`, or
       `Cilium`. The message names both policies.
     - **The plane is not told about Cilium.** 749 gave it `operator.ciliumAvailable` as
       `TROUPE_CILIUM_AVAILABLE` to know what the operator would admit, and a plane told
       nothing refused nothing for want of knowing. What it refuses no longer depends on
       the mode, so the chart no longer gives it the value, the plane no longer reads it,
       and a plane run without the chart refuses what one with it does. Undoes that part
       of 749.
     - Public and private addresses and in-cluster Services are unchanged in both modes. A
       name is still taken at its word (749): with Cilium, a name in `allowedEgress` whose
       DNS answer is such an address is admitted by the `toFQDNs` rule, which cannot be
       seen where the name is typed.
     - **Proof:** the protocol's `reach_test.exs` (`refused?/1` over both families, the v6
       spelling and the ranges' edges; the message), the operator's `resources_test.exs`
       (with Cilium, every spelling and every kind of profile host left out of `toCIDR`,
       a public and a private address kept) and `reconciler_test.exs` (with Cilium, the
       condition naming the gateway on loopback and the server at the metadata address,
       and no `toCIDR`, then the same message without; reachable endpoints with Cilium
       stay `Cilium`), and the plane's `reach_test.exs` (the metadata address refused
       whatever the plane was told, a public address and a Service saved, the bundle
       refused with Cilium). The operator's two and the plane's two failed on the chunk
       tip.

759. **A SCIM create answers `201` with where the resource is, a delete of an id the plane
     does not have answers `404`, and a push with `active: false` deactivates a person the
     way a `DELETE` and a `PATCH` do.** Issue #356, the SCIM items of defect D56, left by
     754, which kept `POST` and `PUT` as they were.
     - **The answers RFC 7644 gives.** A `POST` to `/Users` or `/Groups` answers `201`, the
       resource, and its path in `Location`, the same as its `meta.location` (section 3.3);
       both are relative to the plane, as `meta.location` already was, because a plane
       behind an Ingress without `TROUPE_BASE_URL` does not know the name it is reached by.
       A `PUT` still answers `200` (3.5.1). A `DELETE` of a user answers `404` for an id
       nobody has, as one of a group already did (3.6), and `204` otherwise.
     - **A create of somebody the plane has is still a create.** A push upserts on the
       subject, so a `POST` of a person who signed in before their first push, or one
       pushed before, updates that row and answers `201`. The RFC's answer to a duplicate
       is `409`, which would leave somebody who signed in first unprovisionable: a row
       sign-in keyed on Entra's object id, which no push has named yet, does not answer the
       provider's filter on `userName` (754), so the provider creates, and a refusal there
       is a refusal at every cycle.
     - **One way to deactivate.** `put_user/1`, behind `POST` and `PUT`, writes through
       the same function as a `PATCH` and a `DELETE`, which stops the principals the
       person sponsors before it writes `active: false`. Stopping only touches principals
       still running, so the same push again, or a `DELETE` after a `PUT`, stops nothing
       twice; a push that keeps them active does nothing to principals.
     - Unchanged: a `PUT` keys on the body's subject rather than the `id` in its path, and
       a refused `POST` or `PUT` answers `400` without SCIM's error body.
     - **Proof:** the plane's `scim_answers_test.exs`, through the router with the
       connector's bearer: a user's and a group's create with `Location` equal to
       `meta.location`, a person who signed in first created as the same row, a replace's
       `200`, a delete's `204` and `404` for an unknown and a malformed id on users and
       groups, a `PUT` with `active: false` stopping a sponsored principal (and refusing
       sign-in) and the same `PUT` again leaving its `disabled_at`, and a `PUT` with
       `active` true or absent leaving it running. The creates, the unknown delete and the
       stop failed on the tip. `scim_entra_test.exs`, `scim_connector_test.exs`,
       `subject_claim_test.exs` and `web_test.exs` asked for `200` or either on a create,
       and now ask for `201`.

760. **The desktop app shows a team session whose turn the harness stopped as failed, and
     says why in words.** Issue #354, defect D53's first bullet, following 745 and 750.
     - **A plane's row is read for its reason.** `rowFromPlane` maps `failed_reason` to
       `FleetRow.failed` as `{reason, detail: null}`, the field a daemon's rows fill (745),
       so the list's row, the launcher's and the review queue's status say Failed for a
       team session as they do for a local one, and nothing that reads `failed` has a new
       shape to learn. `detail` is null because a plane holds no content (750). A plane
       from before the column, or a row without one, says nothing failed.
     - **Each reason has its words.** `failedTitle` says "The agent kept crashing and the
       session stopped" for `agent_failed`, as before, and "A tool kept failing and the
       harness stopped the turn" for `tool_failures`: the failure guard counts one tool's
       failures in a row, so it is a tool and not the agent. A reason the app does not know
       reads "The turn failed (<reason>)" rather than nothing.
     - **A local session still cannot say `tool_failures`.** The daemon's `failed` is
       `agent_failed` only (745), so those words reach a local row only once a daemon lists
       it, and the transcript still shows such a turn as the failure guard's question
       answered `stop`, as 745 left it. A notification that reads a row's `failed` follows,
       though a plane's rows count nothing unseen and so raise none.
     - **Proof:** the client's `fleet` test (a plane row with each reason, one with none,
       one from before the column) and the desktop app's `team-failed` test (a fake plane
       lists a session stopped on each reason beside one that finished; the launcher's
       recent rows and the list say Failed, with the reason's words on hover), both failing
       on the tip; and the web build against `pnpm fake`, which now seeds a run stopped on
       `tool_failures`.

761. **The desktop app and the terminal UI share one set of settings: `config.yaml` at the
     ladder's scopes, served by the daemon with where each value came from, one key set
     into the scope a client names, and every client told when a file changed.** Issue
     #57, as decided on it and on #122: no second settings file and no second schema.
     Amends 675, which had the methods read and edit the user's file alone, for the model
     panel.
     - **`config.get` is additive.** It keeps every field it answered (the model panel's,
       what the user's file says) and adds `keys`, `files`, `workspace`, `trusted`,
       `warnings` and `errors`, so the protocol stays version 1 and an older client reads
       what it read. `keys` is `Troupe.Config.Explain.rows/1`, what `troupe config
       --explain` prints, as JSON: every schema key with its value in effect, the layer
       and file that set it, its default, the scopes it may be written to here, and its
       label and help. A secret is `****`, not `Config.mask/1`'s first and last letters:
       those are for the person at the console, and nothing of a key goes over a socket
       (675). `Troupe.Config.Settings` is the new module behind both methods.
     - **`config.set` takes one key by name, or the panel's fields.** With `key` (or
       `path`, for a name under a map with a dot in it) it writes `value` into the file of
       `scope` (`user`, the default, `project` or `local`), through `Migrate.write/2`, the
       writer 711 made every screen use; `null` takes the key out. With `provider` it is the
       model panel's save, unchanged. Nothing is written for a key the schema does not know,
       `version` and `$schema`, a value the loader would refuse or warn about (the value is
       checked by the loader's own walk, `Layers.check_map/2`), or a scope that may not set
       the key: `trusted_workspaces` outside the user's file, and a key marked trusted in the
       project or local file of a workspace that is not trusted, the trust rules of 686. A
       daemon from before this reads a `config.set` without `provider` as the panel's and
       would write `provider: anthropic`, so both clients set one key only on a daemon whose
       `config.get` answers `keys`.
     - **`config.changed` goes to every client after a write that changed a file.** The
       daemon reads the file before and after a `config.set`, a `config.import` and a
       `setup.answer`, and names the keys whose values differ (`Settings.changed/2`; the
       writer's own `version` is no change), to every connection that speaks the protocol,
       the writer's included: it is how one client shows what another set. A save that
       changed nothing says nothing. **A file edited by hand is not announced:** the
       daemon would need a watcher for every workspace a client names, and nothing in the
       daemon goes stale without one, since it reads the files at every session start and
       every `config.get`. A watcher on the user's file is the follow-up if a screen left
       open turns out to matter.
     - **A `ui` section holds what follows the person**: `ui.theme`, `ui.mode` and
       `ui.notifications`, the desktop app's three. The daemon keeps them and acts on none,
       as it does `mouse`, which keeps its name (686 made it a key, and moving it is a
       migration). The theme is a string, one the app does not know reading as its
       default, so a newer app's theme is not a file an older daemon refuses; the mode is an
       enum. Neither client has keybindings a person sets, so `ui` has none yet. What
       belongs to one device — a window's size, the plane the app last used, whether it
       opens on Home — stays in that window. The desktop app keeps its `prefs` as the
       first frame's and a browser's copy (`shared.ts`): what a file sets wins when the
       daemon is reached and whenever `config.changed` names a `ui` key, a choice made there
       is written through, and a default met at first contact does not undo a choice made
       before there was anywhere to share it.
     - **One key table.** A schema key a settings page shows has a `label`, and its `doc`
       is the help both clients show; the terminal UI's own table (`Troupe.Settings`) is
       now `Schema.settings/0` less the `ui` keys, and its longer help is folded into the
       docs. The generated reference has a `Shown as` column. The TUI reads the schema as
       data, the one door added to its `troupe.xref` list. TUI Decision 136 is the page.
     - **The desktop app follows.** The model panel reads `config.get` again on
       `config.changed`, and its form follows unless somebody is part way through an edit,
       who is told instead; the Appearance screen's theme, light or dark and notifications
       are the `ui` keys.
     - **Not done:** "set by your organisation", which waits for #122's organisation layer;
       a desktop screen listing every key, rather than the ones it acts on; and two clients
       saving one file at the same moment, which stays last-write-wins as it was.
     - **Proof:** `Troupe.Gateway.SharedSettingsTest` (two clients on one daemon: a model
       saved in one announced to the other, one key set by name into the user's and a
       project's file, null taking a key out, every refusal, `config.get` with layers,
       scopes and no secret), whose announcement tests failed on the tip;
       `Troupe.Config.SettingsTest`; `Troupe.Gateway.ModelSettingsTest` unchanged; the
       terminal UI's `Troupe.SharedSettingsTest` (a model the desktop app saves shows on the
       open settings page; one picked there reaches the desktop app's `config.get`), both
       failing on the tip; `@troupe/client`'s `config` test and the desktop app's
       `shared-settings` test against the fake daemon; and the installed daemon and terminal
       UI on scratch homes, a model set through the daemon from a script showing on the
       running terminal's settings page, on the pull request.

762. **The daemon starts at login when a person says so: one module writes the platform's
     own per-user entry, removes it and says whether it is there, and a daemon started
     that way stays up until the person logs out.** Issue #76's last item, after 705.
     `Troupe.StartAtLogin` is the one place; `troupe-daemon login on|off|status` (so also
     `troupe daemon login …`) and the first run's new `daemon` step both call it. It is in
     the harness, beside `Troupe.Setup`, because the step is the setup flow's and the
     terminal client embeds the same code.
     - **The entry is each platform's own, and none needs an administrator.** Windows: a
       `troupe-daemon.cmd` in the Startup folder, a file a person can see and delete, which
       Task Manager's startup list shows. macOS: a launchd agent run at load,
       `com.objective-mj.troupe.daemon`, named under the desktop app's identifier (710).
       Linux: a `systemd --user` unit wanted by `default.target`, written with the link
       `systemctl --user enable` would make, where `/run/systemd/system` says systemd runs
       the machine; elsewhere an XDG autostart entry, which only a desktop session reads,
       so a console login there starts nothing.
     - **On Windows the daemon runs in a console minimised to the taskbar.** A start with no
       window needs a script host (VBScript, which Windows is retiring) or a hidden
       PowerShell, and both are how malware keeps itself running, which is what a virus
       scanner looks for. A minimised console can be seen, and closing it stops the
       daemon. The entry runs `cmd /c` so the window goes when the daemon does, and switches
       the console to UTF-8 only for a path beyond ASCII.
     - **Only files.** Nothing is loaded into launchd or systemd and nothing is started:
       turning it on takes effect at the next login, and turning it off stops nothing that
       is running. The same on every platform, testable in a scratch home without the
       person's session manager, and a test cannot leave a service running.
     - **It starts `troupe-daemon run` as a client finds it**: `TROUPE_DAEMON_COMMAND`, then
       the `PATH` (the installers' shim, whose path an upgrade or a rollback keeps), then the
       wrapper of the release it runs in. With none, turning it on is refused with the
       reason and writes nothing, and the desktop app's choice is greyed.
     - **A daemon started at login does not exit when idle**: the entry sets
       `TROUPE_DAEMON_IDLE_MINUTES=0`. Starting at login is for having the daemon there;
       one that went away ten minutes after login would leave the entry doing nothing a
       client's start on demand does not. A daemon a client starts still exits when idle,
       and one stopped by hand is started on demand by the next client, idle rules and all.
     - **The step is the answer, not a toggle.** `daemon` comes between `workspace` and
       `finish` on the local paths, `{"at_login": true | false}`: true writes the entry
       (again, picking up a moved binary), false removes one, so re-running Setup is also
       how it is turned off, and what is there now is the answer a screen presses.
       `setup.get` reports it as `daemon` (`at_login`, `kind`, `path`, `command`). A plane's
       path stays `where`, `finish` (705); `troupe daemon login on` is there for its users.
     - **The terminal client asks it too**, after a first run saves settings and only where
       a `troupe-daemon` is installed, Enter meaning no, and answers yes with `troupe daemon
       login on`. Its full-screen flow is still a later slice.
     - **Not the installer's.** #76 asked whether this belongs in the installer: the entry
       is the daemon's, so that one module knows the paths. An installer that offers it
       runs `troupe-daemon login on`, as it runs `config import-opencode`, and its
       uninstall should run `login off` first; neither does yet. A switch on the desktop
       app's settings screen is not in this change either: Setup asks again.
     - **Proof:** `start_at_login_test.exs` (each platform's entry in a scratch home, its
       exact text and quoting, its removal, a unit nothing wants being off, the binary's
       discovery), `setup_test.exs` ("the daemon step …") and the daemon's `cli_test.exs`
       ("login turns …"), both failing on the chunk's tip; the gateway's setup test over
       the socket; the desktop app's onboarding test (the first run through the step, the
       screen on its own) against the client's fake daemon, and the first run in a browser
       against that fake, dark at desktop width and light at 380px; the terminal client's
       `config_setup_test.exs`; and on Windows, the installed `troupe-daemon login on`,
       `status` and `off`, and `troupe daemon login …` through the installed TUI, against a
       scratch `APPDATA`, the entry run as Explorer runs a Startup item starting a daemon
       that was still up after 100 seconds with `TROUPE_DAEMON_IDLE_MINUTES=1` around it,
       and the real Startup folder untouched, on the pull request. Every test writes
       into a scratch home: the suites set `:troupe_core, :start_at_login` to one.

763. **A command a person or a repository writes as a markdown file is a row of the
     command table, in a section of its own, and the harness runs it: the file's prompt,
     with what follows the name for `$ARGUMENTS`, goes to the session as input.** Issue
     #124, its third done-when item, left by 698. A prompt somebody types every day had
     nowhere to live, and a team had no way to hand its repository's prompts to whoever
     opens it.
     - **Files.** `<config>/commands/<name>.md` (the user's) and
       `<workspace>/.troupe/commands/<name>.md` (the repository's), the shape other tools'
       command files have: optional frontmatter, then the body. The file name is the
       command; a name is what an agent's may be, lower-case letters, digits and dashes.
       `description` is the summary (the body's first line without one) and
       `argument-hint` what the usage line says follows the name; other keys are left
       alone. The workspace's file wins over the user's of the same name, as the skills'
       layers resolve (700). `Troupe.Commands.Local` reads them; a file that cannot be
       read, whose frontmatter is not YAML or whose body is empty is skipped with a
       warning.
     - **In the table.** The `custom` section, between `agents` and `quit`, with `source`
       `user` or `project` and a `detail` that names the file, so a person knows where to
       change it. The files are read whenever `commands.list` is asked, so one written a
       moment ago is listed. A pod reads its own config directory and workspace, as it
       reads `.troupe/agents/` there.
     - **A built-in's name stays the built-in's**, and so do an alias's and an agent's:
       such a file is skipped, with a warning in the daemon's log. A built-in is code in
       each client that a person's fingers know, and a repository's file arrives with a
       clone; letting `merge.md` turn `/merge` into a prompt would change what a known
       command does without anyone being told. A name is one row, so a client finds a
       command by name and nothing has to choose between two.
     - **The harness runs it** (`commands.run`, `control`): it finds the name among the
       session's defined commands, replaces every `$ARGUMENTS` with what was typed after
       it, trimmed — or adds that as a paragraph of its own where the body has no
       placeholder, so nothing typed is dropped — and sends the result as `input.send`
       would, under the same `command_id` and actor. A client keeps no copy of the
       expansion, so the terminal and the desktop app cannot disagree on what a command
       sends, and `$1` or `@file` later are one change. Anything else is `not_found` with
       `kind: "command"`.
     - **No trust needed.** A command is a prompt sent only when somebody types it, and
       does nothing the same words typed by hand would not: the turn goes through the
       session's approvals as any other. So a workspace's commands are read whether or not
       the workspace is trusted (686), as its `.troupe/agents/` and `AGENTS.md` are.
       Frontmatter that changed what may run without asking — a tool list, a model on
       another endpoint, an approval setting — would be a trusted key and is not read.
     - **Not in this slice:** `agent` and `model` in the frontmatter (a command on another
       agent is a branch, which only the terminal client has), `$1` and `@file`, a
       bundle's commands for every session of a team, and the terminal client reading the
       table again while a session is open (it reads it when the session opens). Also
       still owed to #124: `troupe --help` and the docs' command reference generated from
       the table.
     - **Proof:** `Troupe.CommandsTest` (a workspace's `review.md` listed with its fields
       in its section, which failed on the tip; a file without frontmatter; the
       workspace's over the user's; built-in, alias and agent names and bad names
       skipped; the expansion), `Troupe.Gateway.CommandsListTest` over a socket (listed,
       `commands.run` sending the prompt as a `user_input` with the `command_id`, and
       refusing a built-in, an agent, an unknown name and non-text arguments),
       `Troupe.Worker.AuthTest` (a session's token may run its commands), the TUI's
       `Troupe.CommandPaletteTest` (listed under Custom with its description, run from
       the line with an argument) and the desktop app's `command-palette.test.tsx` (the
       row in its section, Enter calling `commands.run` and the prompt in the
       transcript).

764. **A client signed in to a plane hands the daemon its plane token when it links it, when
     it reaches it, when the token is renewed and when the daemon restarted; a link that
     carries one is when the daemon carries on sealing what it could not; and both clients
     ask for a private session where the daemon reads it.** Issue #365, following 745 and
     756. The daemon cannot obtain a plane token and holds the one it is handed in memory
     only, and neither client handed it one: the desktop app's `linkIdentity` had no
     `plane_token`, and the TUI never called `identity.link`. Nothing private was registered
     or sealed from either. Four more things stood between either client and a sealed
     private session, and are fixed here because the issue's done-when needs each.
     - **The desktop app.** `linkIdentity` takes `plane_token`. `useDaemon` is given the
       sign-in and hands the token over where the daemon is linked to the person signed in,
       at this plane: when it reaches the daemon or the person signs in, for every token
       the `AuthSession` takes after that (`onCredential`, new: a renewal comes from the
       list's poll, two minutes before expiry), and when the socket opens again, which after
       a restart is a daemon holding none (745 follows it there). *Use my account* links
       with it. A daemon linked to nobody or to somebody else is not touched: linking stays
       the person's choice, on *This computer*.
     - **The TUI.** Signed in (`troupe login`; the current plane in `credentials.json`),
       every new connection `Troupe.Client.Daemon.Link` makes hands the daemon the token,
       because a new connection may be to a daemon with none, one this VM just embedded or
       one that restarted; so does a timer a second after the store would renew the token,
       a minute before expiry (`Tokens.person/1`), and a minute after a hand-over the plane
       was not there for. The subject and name are the plane's, from `/auth/exchange`'s
       answer, now kept, or from `me` where it was asked. It links a daemon linked to nobody
       or to this person at this plane, and leaves one linked to somebody else. Unlike the
       desktop app it links an unlinked daemon: the TUI has no control to do it with, and
       signing in with `troupe login` is the person asking. Out of the link process, in a
       task, because a renewal is a round trip and the link is a call through it.
     - **Asking for a private session.** The desktop app sent `private` inside `config`, a
       setting no client may choose, so *Keep it private* made a local session; it goes
       beside `config` now, where the daemon reads it and PROTOCOL.md now says so. The TUI
       had no way to ask: `troupe --private` and `troupe run --private`.
     - **`private_sessions` on an installed daemon.** It asked for an object-store
       configuration, which a daemon never uses (it writes through the URLs its plane
       signs) and an installed one never has, so the desktop app offered no checkbox
       outside development. Somewhere to seal to is now the plane the link names. It is
       still computed at `initialize`, so a connection made before *Use my account* says
       false after it; the desktop app offers the checkbox where the daemon knows the
       capability and is linked now, rather than after the next launch.
     - **Carrying on.** A sealer was started at `session.create` and nowhere else, so a
       private session made while nobody had linked was never sealed, and none was sealed
       again after a restart, though PROTOCOL.md promised a daemon with no token seals
       later. A link that carries a token now runs `Private.resume/1` after the erasures:
       for each private session the daemon has with no sealer (`kind` is in the index now,
       read from `session_created`), `session.get` decides. One the plane has never heard
       of is registered and sealed from its first event. One this device sealed last
       carries on from the row's `last_seq` with its `object_bytes`, registered with the
       row's epoch, so a claim another device made meanwhile refuses it. One another device
       sealed last is left to it: taking it back is a claim, which a person asks for. One
       being erased is the erasures'. Keyed on the row's `device`, the name a daemon
       registers under, so a machine whose name changed carries on nothing until it claims.
     - **The sealer starts partway.** It takes what the log holds after its starting point
       (`:backfill`), asked after it subscribes, and drops an event it already holds. So a
       session that starts sealing as it is created now also seals the events its start
       wrote before the sealer subscribed, `session_created` among them, which no sealed
       private session had until now. A pod passes no backfill and seals as before.
     - **Unchanged:** the token is in no file and no answer; `identity.json` holds the
       label. A link without one is the label alone. The daemon's `session.list` still does
       not say a session is private, so the desktop app lists one as local.
     - **Proof:** the client's `stage2` (a link carries the token and no answer does; its
       type refused it on the tip) and the desktop app's `private-link` test against the
       fake deployment with plane tokens of 125 seconds (handed over on reaching the
       daemon and again renewed, both honoured by the plane; handed to a restarted daemon;
       none to a daemon linked to somebody else; *Use my account* with it, the checkbox on
       a connection that said no private sessions, and `private` beside `config`), three
       of four failing on the tip. The TUI's `private_link_test`
       against `FakeRemote` on the POST transport, whose `/rpc` honours only the tokens it
       minted (linked with the token on attach and a private session registered with it;
       a renewed token handed over; a restarted daemon linked again; one linked to
       somebody else left), three failing on the tip, and `cli_test` for `--private`. The
       gateway's `private_test` against MinIO (a session sealed before a restart carried on
       once linked, from `last_seq` at its epoch, its later events in a second segment; one
       another device took left to it; one made while unlinked registered and sealed from
       its first event, an event delivered twice sealed once; a renewed token sealing what
       waited for it; through the daemon, a link registering a session made while unlinked,
       the token in no file) and `daemon_test` (`private_sessions` with no object store),
       all failing on the tip but the renewal, which the daemon already took and is kept
       as a pin. And the installed daemon and `troupe`, with scratch homes, against a plane
       stand-in that signs real assertions through the development OpenBao and presigns
       real MinIO URLs: the desktop app's client library linked the daemon with its token
       and a private session was registered and sealed; `troupe login` and `troupe run
       --headless --private` likewise; after the daemon was killed and started again, the
       TUI's next attach handed it a token, and the daemon registered the two sessions from
       before the restart again at epoch 1 and sealed the one the run had just made, while
       it had no token, from its first event; and a turn added to the first session then
       was sealed from the next sequence number on.

768. **A build after `VERSION` changes writes the new version into every app's `.app`:
     each project that reads `VERSION` lists `troupe_protocol`'s `:troupe_version` compiler
     after `:app`.** Issue #380 (D60), following 668. Every `mix.exs` reads `VERSION` when
     Mix loads it, but Mix's `:app` compiler writes an `.app` again only when `mix.exs`, the
     config or the compile directory is newer than it, and a new `VERSION` is none of those.
     So an incremental build after a bump kept the previous `vsn` in every `.app` but
     `troupe_protocol`'s (its `Troupe.Version` recompiles on `VERSION`, which touches the
     compile directory): `scripts/install-local.ps1` in a checkout that had built the
     previous release installed binaries that said it, and `Troupe.VersionTest` failed in a
     test build. CI builds from clean and never saw it.
     - **A compiler, not the script.** Mix has no way for a project to say its `mix.exs`
       reads a file: `@external_resource` is a module's, and the config files Mix watches
       are the ones the config imports. That left a compiler that checks, or a script that
       removes the `.app` files before it builds. The script would mend `install-local.ps1`
       alone; the compiler mends every incremental build, `mix test` in a checkout and a TUI
       built by hand among them, and needs no record of the version a `_build` last saw,
       because the `.app` is that record.
     - **What it does.** After `:app` it reads the `.app`, and when its `vsn` is not the
       project's version has `:app` write it again (`compile.app --force`). Otherwise it
       reads one small file and does nothing.
     - **Where it lives.** In `troupe_protocol` (`Mix.Tasks.Compile.TroupeVersion`), because
       every other project here, the umbrella's apps and the TUI, depends on that app, so it
       is compiled and on the code path before them; `troupe_protocol` reaches its own after
       `:elixir`, as `troupe_core` does `:reaper`. The alternative was a file every
       `mix.exs` required, one more thing each would load before Mix knows its project.
     - **A new project that reads `VERSION` lists it too** (`docs/developer/build.md`).
       Nothing checks that one does.
     - **Proof:** `Mix.Tasks.Compile.TroupeVersionTest` builds a project that reads its
       version from a file twice, each time in a `mix` of its own, the file changed between:
       with `:troupe_version` the second `.app` says the new version, and without it, kept
       as the reason, the first. On the tip, a test build, `VERSION` at 0.8.1-beta and a
       second build left seven of the eight `.app` files at 0.8.0-beta and
       `Troupe.VersionTest` failing ("troupe_core is 0.8.0-beta and VERSION is
       0.8.1-beta"); with this all eight said 0.8.1-beta and that test passed. And
       `install-local.ps1`, run in this checkout at 0.8.0-beta, then with `VERSION` at
       0.8.1-beta, then put back, installed a `troupe-daemon` and a `troupe` that said
       0.8.1-beta and then 0.8.0-beta, each time the version the checkout had not built.

767. **`troupe --help` and the command reference are written from two tables, the command
     lines beside `troupe`'s parser and the harness's slash commands, and the TUI's suite
     fails when either drifts.** Issue #124, its last done-when item, left by 698 and 763.
     The help was the parser module's hand-written moduledoc and listed no slash command
     at all; the TUI's README carried a second hand-written list of both, which had lost
     `/memory` and `/context` and still offered `/code` for the agent called `build`; and
     no page said what every command does.
     - **What "one table" covers.** The slash commands are `Troupe.Commands`, the table
       `commands.list` serves both clients (698): the help prints its built-ins by section
       with each one's usage, summary and aliases, and the page adds the detail, an
       example and what each needs. The command lines are a table of their own,
       `Troupe.CLI.commands/0`, beside the parser in the TUI rather than in the harness:
       they are this client's command line, which neither the daemon nor the desktop app
       has, and nothing in the umbrella may depend on a client (666). A row is how the
       line is typed, what it does, and command lines that are it.
     - **Held to the parser, not only to the page.** A table nothing checks against the
       parser is the hand-written text with more punctuation. The suite parses every
       row's command lines, holds the modes they reach equal to `Troupe.CLI.mode()`, and
       every switch the parser takes to one the help names; a subcommand added without a
       row, or a row the parser no longer takes, fails it.
     - **The page.** `docs/user/cli-reference.md`, in the users' track and the site's nav:
       two parts between markers, written by `mix troupe.cli.reference` in `clients/tui`,
       the one project that sees both tables, and the rest by hand, as `configuration.md`
       holds the key reference. `--check` runs in the TUI's `mix check` and in
       `dev-check`'s TUI job, and both workflows run that job when the page alone changes.
       The TUI's README points at it and keeps what no table holds: the agents a session
       has and the commands people write, which are a session's own (its config, bundle
       and workspace), so the help and the page name them in a sentence and the palette
       lists them.
     - **`troupe --help` needs no daemon.** It reads the table compiled into the binary,
       the one the daemon serves, so `Troupe.Commands` joins the harness modules the TUI
       may call (`mix troupe.xref`), as `Troupe.Config.Schema` did (761); TUI Decision
       138. A command line that does not parse is still answered with the command lines
       alone.
     - **Not here:** `/todo`, which a branch window's input box takes and the table does
       not list, and `troupe-daemon`'s own command line.
     - **Proof:** the TUI's `cli_reference_test.exs` (the help lists every built-in with
       its summary, and the committed page is what the tables render, both failing on the
       chunk's tip; every row parses and the rows reach every mode; every switch is
       named), and the installed `troupe --help`, on the pull request.
