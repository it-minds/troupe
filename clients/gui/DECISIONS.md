# Decisions

Every judgment call this repository made that a reader could reasonably have made
differently, with the reason. Numbered, append-only. The remote's own decisions live in
`../troupe-remote/DECISIONS.md`; these are the client's.

## Stage 1 — the shell, team sessions, and sign-in

1. **The transcript fold lives in `@troupe/client`, not in the React app.** It began in
   `apps/desktop/src/useSession.ts`, where it could only be exercised by rendering
   something. It is a pure function of the event stream — the single most important
   thing in the client, because two clients agreeing is a property of this function —
   so it is now `packages/client/src/transcript.ts` and is tested without a DOM, a
   socket, or a server. The React layer is an adapter over it and holds nothing.

2. **`SessionView` owns the cursor; the connection is swapped underneath it.** The
   constructor gained a form that takes a session id with no connection, plus
   `bind`/`unbind`. A reconnection must not lose the last `seq` the client actually
   processed, and tying the cursor to the socket would have meant rebuilding the
   transcript from zero every time a pod token ran out. The old
   `new SessionView(conn, id)` form still works, because the bench uses it and a script
   with one socket has nothing to gain from the split.

3. **The fleet store takes *sources*, not a plane.** Stage 1 has exactly one source and
   every row says `team`. Modelling it as "the plane's list" would have made stage 2's
   daemon and stage 3's private sessions a branch through every view instead of an
   entry in a list. `FleetStore` merges by id with the daemon's copy winning on
   everything it knows, which is the join stage 3 needs, and there is a test for that
   shape now so the store does not have to change when it arrives.

4. **The plane is polled, because the plane does not push.** The spec asks for "the
   plane's `sessions.list` plus a summary subscription fed from its index". There is no
   such subscription and there should not be: `ARCHITECTURE.md` §8.2 is explicit that
   `/rpc` is request and answer and the `fleet` topic belongs to the worker, which is
   what keeps the plane out of a live session's data path. So the fleet is a poll of
   `sessions.list` every four seconds, and liveness for a session that is *open* comes
   from the worker socket that session view already holds. `FleetStore.patch` is where
   that lands. If the plane ever grows a push, it becomes another `FleetSource` and no
   view changes.

5. **A source that fails keeps its last rows.** A list that empties because a token
   expired is worse than one that is briefly stale and says so. The error is recorded
   against the source and shown as a banner saying that sessions already open keep
   running — which is true, because they are on a different connection.

6. **`PlaneClient` binds `fetch` to `globalThis`.** Held as a field and called as
   `this.fetchImpl(…)`, a browser's `fetch` throws `Illegal invocation` — and it throws
   a `TypeError`, which is indistinguishable from a blocked cross-origin request. Node's
   `fetch` does not care about its receiver, so every test passed while the browser
   build could not reach a plane at all. Found by running it, not by reading it.

7. **`PlaneUnreachableError` names both causes, not just CORS.** A browser tells the
   *page* nothing about why a cross-origin request failed; the reason goes to a console
   the page cannot read. The message therefore cannot assert that it was the allowlist.
   It says the plane may be unreachable *or* may not allow this origin, and it names the
   origin and the variable to add it to, because that is the half a person can act on.
   Stage 1's done item asks for "the exact message naming the origin", and it does.

8. **The origin is told to the client, not only read from `location`.** `AuthSession`
   takes an `origin`, defaulting to the browser's own. A caller that supplies its own
   `fetch` — the test harness, and a shell that proxies — is the one that knows which
   origin is on the wire, and naming the wrong origin in that message is worse than
   naming none.

9. **CORS is tested in Node with a fetch that enforces the same-origin policy.** Node's
   `fetch` has no origin to protect, so a test using it would pass against a plane that
   refuses every browser. `browserFetch(origin)` in the test support sends the `Origin`
   header and refuses to hand back a response that does not name that origin — which is
   what a browser does. It tests the plane's allowlist logic *and* the client's error in
   one place, deterministically, with no browser to install.

10. **The identity provider needs the GUI's origin too.** Not in the spec, and found by
    running the browser build: the device grant is spoken to the provider directly, so a
    deployment that adds the GUI to the plane's `TROUPE_CORS_ORIGINS` and stops there
    fails at the second step. The fake provider now models this, and it is written down
    in the README as a deployment requirement.

11. **Queued, not optimistic — the design's call, and it is the right one.** The spec
    asks that "every optimistic send reconciles on its `input_accepted`", and
    `DESIGN.md` forbids inserting a message into the stream optimistically. Both are
    satisfied: the send is tracked by command id and reconciled exactly when the server
    names it, but it renders *outside* the stream, below it, labelled "Sending" and then
    "Queued". The stream's order is the server's, and a reconnect must not reshuffle
    what somebody has already read.

12. **Approvals are a sticky panel, not an inline block.** `DESIGN.md` §6. An open
    approval is lifted out of the transcript into a panel at the bottom of the
    conversation with the footlight shadow and the only amber on the screen; once
    answered it becomes a decision record inline in the stream and is never deleted. The
    same panel component serves the session screen and the approvals inbox.

13. **The inbox opens each waiting session in `read` mode.** Listing what is waiting
    costs one `sessions.list`, because the plane's index carries `pending_approvals`. But
    *answering* needs the worker, so a row attaches while it is on screen and lets go
    again. `read` is deliberate: looking at what is waiting must not be the thing that
    wakes a sleeping session. Answering is an activating command and wakes it, which is
    the person's choice.

14. **Design tokens are generated, not copied.** `docs/design/themes/*.tokens.json` are
    the source of truth; `scripts/tokens.ts` emits `apps/desktop/src/tokens.css` and
    `apps/desktop/src/mark.ts` with the variable names `docs/design/example.dc.html`
    already uses, so a screen prototyped there keeps its colours when it is built.
    `pnpm tokens:check` fails if the committed files are stale. Copying a palette into a
    stylesheet by hand is how a design system stops being one.


15. **Theme and mode are two attributes, and two questions.** `data-theme` says which
    palette and `data-mode` says light or dark — and `data-mode` is *absent* when the
    answer is "follow my system", because an attribute that says `dark` would out-specify
    the `prefers-color-scheme` block that is meant to answer instead. Three themes times
    two modes is six combinations, but nobody is choosing between "Signal light" and
    "Footlight dark": presenting six cards would make people compare things that are not
    alternatives.

16. **`fs.list`, `fs.read` and `fs.upload` were documented in `PROTOCOL.md`.** They exist
    in the gateway and in the schema and were in neither the method list nor the scope
    table. PROTOCOL.md is supposed to be writable-against without a checkout of the
    server, and a client author would have had to read Elixir to find the file API. The
    scope table was also missing `presence.set` and `tools.unregister`; both now match
    `dispatch.ex`.

17. **The desktop build resolves `@troupe/client` to its source.** Vite was resolving the
    package's `dist`, so a change to the client only reached the running app after a
    separate build — and what you were looking at was silently one build behind. The
    alias is dev-time honesty; the published build still compiles the package properly.

18. **The fakes are the harness, and the demo runs on them.** `pnpm fake` starts the same
    identity provider, plane and worker the tests use. A second set of mocks for the demo
    would agree with nothing; this way what a person sees by hand is exactly what the
    suite asserts.

19. **Stage 1's done items are proven against those fakes, not against a cluster.**
    `scripts/remote-up` needs kind, which is not on this machine, and the suite has to
    run somewhere a change can be checked in seconds. The fakes implement the protocol —
    a real WebSocket, a hash-chained log, replay from a cursor with a closed boundary,
    token expiry and refresh, blob caps, first-answer-wins approvals — rather than
    imitating a screen. What they cannot prove is the *server's* half: that a real worker
    replays without a gap, that a real plane's allowlist is spelled the way this assumes.
    That is a kind run, and it is listed in REPORT.md as not done.

## Against the live plane (troupe.itmindsinternal.dk)

20. **The browser build signs in with authorization code + PKCE, not the device grant.**
    Not a preference — a measurement. Microsoft Entra sends no cross-origin headers on
    its `devicecode` endpoint, so a page asking it for a code is refused before the
    request leaves and `fetch` rejects with a bare `TypeError`. Entra *does* answer its
    token endpoint cross-origin, which is exactly what the code flow needs. Both were
    checked from a real page against the real tenant before any of this was written.

21. **The device grant stays, and the host picks.** `AuthSession.preferredFlow` is
    `redirect` where there is a `location` and Web Crypto, `device` otherwise. A terminal
    and a desktop shell have no redirect to come back from and the device grant is
    exactly right for them; a browser cannot use it against Entra at all. One code path
    would have meant breaking one of the two.

22. **The authorization endpoint comes from the provider, not the plane.** The plane
    already has `TROUPE_OIDC_AUTHORIZE_URL` configured but `/.well-known/troupe` never
    publishes it. Rather than wait on a plane change and a new image, the client reads
    the provider's own `/.well-known/openid-configuration` — standard OIDC discovery,
    which Entra answers cross-origin. If a plane ever does publish
    `authorization_endpoint`, that is used instead and the second request is skipped.
    Publishing it is still worth doing: one fewer round trip, and it would let a plane
    front a provider whose metadata is not reachable from a browser.

23. **A tenant-scoped Microsoft issuer gets `domain_hint=organizations`.** Found by
    Martin signing in and being asked for a personal account. An issuer naming one tenant
    admits that tenant's work accounts and nothing else, so a personal account fails
    *after* the password — the worst moment to learn it. The hint is inferred only for
    Microsoft hosts with a real tenant in the path (`common` and `consumers` are
    deliberately for everybody and are left alone), it is never invented for a provider
    that would ignore it, and a caller who knows the domain can pass it and skip the
    picker entirely.

24. **The verifier lives in `sessionStorage`, not `localStorage`.** It is scoped to the
    tab, so an abandoned sign-in leaves nothing behind, and it is spent on first use
    whether the exchange succeeds or fails. On its own it is worthless — it only matters
    with the authorization code, which arrives in a URL this same tab is about to read.

25. **The code and state come off the address bar either way.** A failed sign-in that
    left them there would retry itself on every reload and fail the same way, because a
    code is single-use and the verifier is already spent.

26. **The desktop app's `tsconfig` maps `@troupe/client` to source, matching Vite.**
    Without it `tsc` reads the package's built `.d.ts` while Vite reads its source; the
    two disagree silently until somebody rebuilds. This was found the honest way — a
    typecheck passing against stale types for four new methods that did exist.

27. **`groups` came out of the plane's default scopes.** It was hard-coded in
    `router.ex` and `:scopes` was settable by nothing, so every sign-in against a
    Microsoft tenant failed with `AADSTS650053` before a password was typed — the CLI's
    device grant as much as the GUI. A group claim is a property of the token the
    provider is configured to issue, named by `TROUPE_GROUPS_CLAIM`; it was never a
    scope. The default is now the four OIDC scopes every provider understands, and
    `TROUPE_OIDC_SCOPES` (chart: `plane.oidc.scopes`) exists for a provider that wants
    something else — Entra's own `api://…/.default`, for instance. Two tests cover it.

28. **Redeeming one authorization code is idempotent.** Found the hard way: a sign-in
    that had actually succeeded was shown to the person as "this sign-in did not start
    in this tab". React's StrictMode runs an effect twice in development — the first run
    took the verifier and waited on the provider, the second landed while that was still
    in the air, found nothing stored, and drew the only conclusion it could. Its error
    was the one on screen, because the first run's success belonged to a closure
    StrictMode had already torn down.

    The work is now keyed on the code and shared, so however many callers ask, the
    provider is asked once and everybody is told the same thing. A resolved sign-in
    stays resolved for a caller that asks a moment too late; a *failed* one is not
    remembered, because whatever went wrong, asking again should genuinely ask again.
    This is not a workaround for StrictMode — a remount, a fast refresh, or two
    components both trying to be helpful do the same thing, and one of those will happen
    in production.

## Shipping the GUI

29. **The GUI is served at `/app` on the plane's own host, not at its own hostname.**
    Same origin is the whole argument: the CORS allowlist stops mattering, there is no
    second DNS record to create or certificate to issue, and the redirect URI the
    identity provider needs is the address people already have. The plane's Ingress owns
    `/` and the GUI's owns `/app`; nginx routes the more specific path. Its own hostname
    is still available — `basePath: /` and a host of its own — and would be the right
    answer if the GUI ever needed to front more than one plane.

30. **The base path is baked into the image, not substituted at runtime.** Vite writes it
    into every asset URL, so an image built for `/app/` is a different artefact from one
    built for `/`. The alternative — a runtime regex over minified output — works until
    the one asset it missed, and then fails as a blank page with a 404 in the console.

31. **The Ingress strips the prefix; the container does not know where it is mounted.**
    `rewrite-target: /$2` turns `/app/assets/x.js` into `/assets/x.js`, so nginx serves
    from its root and the image would work unchanged at any mount point that matches what
    it was built with. The alternative was templating the nginx config and moving files
    around at build time, for no gain.

32. **`TROUPE_GUI_BASE` is normalised, and documented without slashes.** A POSIX shell on
    Windows rewrites a leading `/` in `--build-arg` into a drive path: the first image
    built here had every asset URL beginning `/Program Files/Git/app/`. It built
    perfectly and served nothing. `app`, `/app` and `/app/` now all mean the same thing,
    which is cheaper than remembering `MSYS_NO_PATHCONV=1`.

33. **The image runs its own tests on the way through.** Eight seconds, and it makes an
    image that builds from code that does not pass a meaningless artefact. It earned its
    place immediately: a test that passes on Windows failed in the container, because the
    second client counted messages before its subscription's replay had been folded —
    a race in the test that different timing exposed.

34. **CI builds; a person deploys.** Pushing an image and rolling a cluster are different
    decisions with different blast radii. A workflow that did both would make every merge
    a production change. `scripts/deploy` is the second half, and it prints the running
    digest rather than the tag, because a reused tag with `imagePullPolicy: IfNotPresent`
    lets `helm upgrade` report success over code that never changed.

35. **The plane's URL is prefilled from the serving origin.** A GUI mounted at a sub-path
    is same-origin with its plane, so asking somebody to type an address they are looking
    at is a question with one answer. A build served at its own root still asks.

36. **An error message carries the server's reason, not just its category.** A session
    refused to start and the whole of what the GUI could say was
    `session.create: unavailable (-32010)`. The plane had said considerably more — which
    component and what it answered, in `data.reason` and `data.detail` — and
    `TroupeRpcError` was building its message from the code and the word alone. The cause
    turned out to be a plane bug, but the twenty minutes spent finding it were the
    client's fault: a code names a category, and the category is never the thing that
    needs fixing. Building the reason into the message rather than into eleven call sites
    means every screen that already shows `e.message` improved without being touched.

37. **Three themes, one contract, and no component knows which one is on.** Every theme
    file exposes exactly the same token names; a theme swaps values and nothing else.
    `scripts/tokens.ts` checks this and fails the build on a theme that has grown or
    lost a token, because a colour that resolves to nothing is invisible until it is on
    somebody's screen. The consequence worth having is that there is no conditional
    styling anywhere in the product: one component library, one set of rules, one
    accessibility audit per theme.

38. **Signal ships as the default, against the design file's own recommendation.**
    `THEMES.md` nominates Footlight as the safest — least opinionated, closest to the
    drawn identity the platform's documentation already uses. This build ships Signal:
    the screen is full of other people's colour all day, pasted screenshots, diffs,
    charts and terminal output, and true-neutral graphite with no blue cast is the only
    one of the three that never argues with any of it. `THEMES.md` #4 records the
    reasoning where the next person will look for it rather than only here.

39. **Theme and mode live in the browser, not on the user record.** The protocol has
    nowhere to put a reading preference yet, and waiting for one would have meant
    shipping no themes. `apps/desktop/src/theme.ts` is the only module that knows where
    the answer is kept, so the day the plane learns to hold it that is the file that
    changes and no screen does. The browser would keep a copy regardless: it is what
    makes the first paint after sign-in already correct instead of a flash of the wrong
    ground.

40. **The daemon's questions are answered in the client, the harness's notes are shown as
    the harness's, and the shell starts `troupe-daemon run`.** Phase 4 of the daemon plan
    is done when a local session renders from the same events as a remote one — and
    between stage 2 and now the daemon learned things a session says that the client had
    never heard: an `ask_user` question with options (`question_asked`, troupe-remote
    Decision 651), the budget question that rides on the same path under a `budget-<n>`
    id with `budget_ask_started` beside it (Decision 660), the model's reasoning streamed
    as `llm_delta` of kind `reasoning` (Decision 658), the note the harness gives a model
    whose reply was cut or empty as a `user_input` from source `harness`, the `truncated`
    event, and a root agent that reports `waiting` while a person is asked (Decision 659).
    A client that drops a question on the floor leaves the agent waiting for an answer
    that cannot come, which is worse than any rendering. So the fold has a `question`
    entry — one per `call_id`, made from whichever of the two budget events arrives first
    and filled in by the other — `openQuestions` beside `openApprovals`, and `needsYou`
    for the header; the screen has a `QuestionPanel` where the approval panel sits, with
    the harness's three answers in the reader's words ("spend one more slice", not
    `allow`), and `SessionView.answerQuestion` sends `question.answer`. Reasoning joins
    Anthropic's thinking in the same folded pane; the harness's notes are system lines,
    never a bubble in the person's colour. The shell's `daemon_start` spawns
    `troupe-daemon run` — the release the umbrella's installers put on the `PATH`, by
    its `.cmd` shim on Windows and by its install directories when the shell's `PATH` is
    older than the installer's change to it — and treats a published endpoint nothing
    answers on as the file a dead daemon left behind, starting one over it, where before
    it handed the stale port back and called that found. `troupe daemon`, the TUI's older
    spelling, is the last thing tried.

41. **A browser build in development can be told where the daemon is by the environment,
    and the recipe for a local session is the real daemon with its fake model.** The fake
    deployment has no daemon, and writing one would be a second scripted agent that agrees
    with the client by construction. The daemon already carries a scripted model
    (`provider: fake`, `fake_script:`) for its own smoke tests and the TUI's client tests,
    and against it the GUI exercises the real protocol — questions, the budget question,
    reasoning, the harness's notes, branches — with nothing invented here. What stood in
    the way was typing a port and a token into a form at every reload of `pnpm dev`, so
    `VITE_TROUPE_DAEMON=<port>:<token>` (or `#daemon=` on the URL) fills the form once,
    into memory for the tab and nowhere else, and only when no shell is present to find
    the daemon itself. The README carries the recipe; the desktop application needs none
    of it.

    Running the recipe found what the fake daemon could not: `DaemonClient` unsubscribed
    a session's view when the *first* of two openers closed it, and a second opener's
    hooks were never installed, so a component mounted twice — which React does in
    development, and which two panes on one session do everywhere — read a transcript
    that stopped at nothing. `open` now counts holders and `close` lets go on the last;
    the hook listens on the shared view instead of owning it, and pays exactly one
    `close`. Two small ones beside it: a reasoning block's text was concatenated into the
    answer (`textOf` knew `thinking` and not the daemon's `reasoning`), and a row whose
    time `Date.parse` could not read said `NaN d ago`.

42. **The Teams tab opens on a table, a team can be deleted from it, and the three team
    calls that never worked now name the team the way the plane does.** The plane grew
    `admin.team.disable.preview` and `admin.team.disable` (troupe-remote #31, its Decision
    662) — the first step of moving sign-in, SCIM and team mapping into the admin panel —
    and this is their rendering: one row per team with its groups, member count, profiles
    and administrators, *Delete* on the row, and the dialog's sentence built from the
    plane's preview rather than from a guess, so the numbers a person types a name against
    are the ones the deed will match. Sessions are named as *kept* in that sentence,
    because "delete" reads as taking everything and the sessions are the one thing it does
    not take. Found on the way: `updateTeam`, `grantTeam` and `revokeTeam` sent `team` and
    the changes flat, where every team method on the plane takes `name` and `attrs`; the
    plane answered `invalid_params` for a missing `name`, and nothing in the fake
    deployment exercised them. They send what the plane asks for now, and the admin client
    has a test that pins the wire shape of every team call, which is what would have caught
    it.
