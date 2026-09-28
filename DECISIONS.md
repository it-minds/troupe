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
    still holds no key for what it signs for.)

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

669. **A release is a merged change to `VERSION`, and it deploys itself.** Four
     repositories delivered four ways, nothing had ever been tagged, and the plane was
     deployed by hand from one laptop. Issue #37 asked whether deploying should stay
     manual, and the team's answer is no (Martin, 2026-09-21: "I want a deployment on
     releases too").

     *Cutting one.* `scripts/release <version>` opens a pull request whose only change is
     `VERSION` and its copies (`scripts/version.exs set`), and merging it is the release;
     674 says exactly when a push cuts one. A tag pushed by hand is not a release.
     `.github/CI.md` has what a release runs and publishes.

     *Deploying it.* `scripts/deploy` against the `production` environment: the chart's
     CRDs server-side (Helm never upgrades them), `helm upgrade --wait` rolling back on
     failure, `rollout status`, and then `/.well-known/troupe` must report the release's
     version and commit. Pushing an image and changing production are still two
     decisions; the second is a reviewed merge instead of a laptop session. A release
     candidate (`-rc.N`) runs everything and deploys as a server-side dry run.
     `deploy.yml` is for what the automatic path does not do: roll an earlier release
     back, or render one, through the same script. The environment's deployments are the
     record of what ran where and when, from which merge.

     *Credentials.* `production` holds `KUBECONFIG` and `DEPLOY_VALUES` and the variable
     `PLANE_URL`, and should allow `main` alone. The kubeconfig is the `troupe-deployer`
     service account's (`deploy/ci-deployer.yaml`, `scripts/ci-kubeconfig`), not a
     person's `scw` login. It is not a one-namespace Role: the chart creates CRDs,
     ClusterRoles and an admission policy, and granting a ClusterRole takes `escalate`
     and `bind`, which is cluster-admin in principle. That is said in the manifest
     rather than hidden, and the rules list what the chart touches so the account's
     everyday reach is a deploy's. A required reviewer on the environment is left to the
     team: the bump pull request's review is the approval this design assumes.

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
     `values.small.yaml` and `values.scaleway.yaml` name the worker and GUI images in
     the same registry as the rest, so the policy they carry admits `release`. Proof:
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
     `.github/CI.md` has the picture.

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
     the root's own conversation, with the goal already in its prompt (680). A subagent
     per iteration was the other way, and it is worse at what a loop is for: it starts
     from nothing and reports only a summary, when what the earlier iterations tried and
     what failed is exactly what the next one needs; it carries no goal (680 gives it to
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
       still stops at the question (Decision 681). A cap of the loop's own that the same
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
       event, but only for a toast the shell shows itself rather than the plugin; that
       waits for a machine where a toast can be clicked and the result seen.
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
       and the CLI to 2.12 together.
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
