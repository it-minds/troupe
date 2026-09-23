> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).
> The GUI now lives at `clients/gui` in the Troupe repository, and CI is the root's `gui` and `gui-e2e` jobs (root Decision 666; Decision 45).

# Testing

Thirty-three tests, all in `packages/client/test/`, all on Node's built-in runner, all
against an in-process fake deployment. Nothing renders a screen. `pnpm test` and
`pnpm typecheck` passed on the working tree at audit time (AUDIT §0).

Discrepancy: `README.md:85` and `REPORT.md:40-41` say 20 tests. Counting `it(` gives 7 +
13 + 7 + 6 = 33 (AUDIT §2); the difference is `pkce.test.ts`, written after those lines.

## Running

All of it:

```bash
pnpm test
```

One package (identical, since only the client has a `test` script):

```bash
pnpm --filter @troupe/client test
```

One file — the script is `node --test --import tsx "test/**/*.test.ts"`
(`packages/client/package.json:20`), so pass a narrower glob or a path:

```bash
cd packages/client && node --test --import tsx test/pkce.test.ts
```

One test by name, with Node's filter:

```bash
cd packages/client && node --test --import tsx --test-name-pattern="done item 5" test/stage1.test.ts
```

## Typechecking the tests

`pnpm --filter @troupe/client typecheck` runs `tsc -p tsconfig.json --noEmit && tsc -p
tsconfig.test.json` (`packages/client/package.json:19`). `tsconfig.test.json` extends
the base, sets `noEmit`, `lib: ["ES2022", "DOM"]`, `types: ["node"]`, and includes both
`src` and `test` (`tsconfig.test.json:1-10`). The split exists because the shipped
package is built with `types: []` (`tsconfig.json:7`) — no Node ambient types leak into
browser code — while the tests and fakes need `node:http`, `node:crypto` and `ws`.

## The files

### `stage1.test.ts` — the spec's done items

One `describe` per done item in `spec.md:64-70`, run against a fresh harness each
(`stage1.test.ts:1-7`).

| `describe` (line) | Spec done item | What the block proves |
|---|---|---|
| "done item 1: sign in, list, create, prompt, and stay signed in" (`:68-139`) | `spec.md:65` | From an empty store: the device grant with a `slow_down` on the first poll (`:80`); the rotated refresh token is the one persisted (`:85-87`); `sessions.list` shows a seeded row; `profiles.list` answers `agents` and `skills` before anything is created (`:95-101`); `session.create` with `agent: "plan"` (`:104-108`); the answer arrives in deltas and folds to `"You said: hello"` (`:120-127`); a second `AuthSession` over the same store restores with no interaction (`:132-137`) — had it fallen back to the device grant it would hang |
| "done item 2: a plane that does not know this origin says so" (`:141-169`) | `spec.md:66` | Through `browserFetch`, a plane whose allowlist omits the origin yields `PlaneUnreachableError` whose message matches `/Add https:\/\/gui\.example\.com to TROUPE_CORS_ORIGINS/` and names the plane URL (`:159-161`); adding the origin makes the same client work (`:164-167`) |
| "done item 3: two clients on one session agree" (`:171-226`) | `spec.md:67` | Two people, two sockets, 50 sends each with optimistic `addPending`; both transcripts end with 100 user entries in identical `seq:author:text` order (`:209-218`), both authors present (`:220-221`), and no pending entry left on either side (`:212-213`) |
| "done item 4: the approvals inbox" (`:228-304`) | `spec.md:68` | Three sessions stopped on approvals, then closed — the test waits for the worker's connection count to reach 0 (`:251`); `FleetStore` + `PlaneSource` list all three with `pendingApprovals === 1` from one `sessions.list` (`:254-259`); answering from an attachment continues the turn (`:264-271`); a second answer from another person sees `approval_resolved` naming the first, runs no second turn and does not change the decision (`:274-299`) |
| "done item 5: a pod token running out" — first `it` (`:306-340`) | `spec.md:69`, first half | With a 20 s pod token and a warning 18 s early, a long turn sees `auth.refresh` on the open socket; the pod saw exactly one `initialize`; the token in hand changed; status is `live` (`:326-335`) |
| "done item 5" — second `it` (`:342-382`) | `spec.md:69`, second half | With the warning suppressed and a 3 s token, the socket closes, the attachment reconnects (a second `initialize`), and the durable seqs seen across the boundary are exactly `1..n` in order with no duplicate (`:349-377`) |
| "done item 6: a large tool result" (`:385-424`) | `spec.md:70` | `big: lorem` produces a `tool` entry whose content `isBlobRef` with `size > 16 KiB` and a preview ≤ 4096 bytes (`:401-405`); `blob.get` was called zero times on load (`:408`); `blobText` makes more than one ranged `blob.get` because the fake caps answers at 64 KiB, and the bytes match `size` (`:412-417`) |

`REPORT.md:46-75` narrates the same seven assertions. Two of them are timing-shaped
(`REPORT.md:309-314`).

### `pkce.test.ts` — the authorization code flow (13)

`sessionStorage` is faked per test (`pkce.test.ts:13-27`, `:70-76`); the provider is a
fake `fetch` (`:43-65`).

| `describe` / `it` (line) | Proves |
|---|---|
| PKCE: challenge is SHA-256 of the verifier (`:79`); two pairs differ (`:89`) | `pkcePair` is S256 over a 43–128 char unreserved-set verifier |
| the authorization endpoint: from provider metadata when the plane publishes none (`:97`); from the plane with no second request when it does (`:104`) | `idpMetadata` (`DECISIONS.md` #22) |
| the redirect: sends everything the provider needs and keeps the verifier at home (`:114`) | `client_id`, `response_type=code`, `redirect_uri`, `S256`, `state`, `prompt`, `scope`; the verifier is not in the URL |
| redeems the code with the verifier it kept, and only once (`:141`) | `grant_type=authorization_code`, `code_verifier`, no `client_secret`; a replay answers from memory; a different code is refused |
| tells a tenant-scoped Microsoft picker to stop offering personal accounts (`:176`) | `domain_hint=organizations` for a tenant issuer, none for `common`, none for other providers, explicit value passes through |
| redeems one code once, however many callers ask at once (`:207`) | The StrictMode case (`DECISIONS.md` #28) |
| lets a failed exchange be tried again (`:228`) | A failure is not memoised |
| refuses a state this tab did not send (`:239`) | And the verifier is spent anyway |
| turns the provider's refusal into an error naming what to register (`:250`) | `AADSTS50011` surfaces |
| is not confused by a URL that is not a sign-in coming back (`:257`) | `hasRedirectAnswer` needs both `code`/`error` and `state` |
| reports a token endpoint that refuses rather than returning nothing (`:263`) | `invalid_grant` surfaces |

### `transcript.test.ts` — the fold (7)

No sockets (`transcript.test.ts:1-3`).

| `it` (line) | Proves |
|---|---|
| turns a turn into user, tool and assistant entries in order (`:21`) | Entry kinds, tool `ok`/`content`, `profile`, `costMicros` |
| is the same list whether or not the ephemerals arrived (`:48`) | Deltas change `streaming` only; `rootState`/`isBusy` follow `agent_state` |
| does not paint a subagent's stream into the root's answer (`:72`) | `isRoot` guard |
| reconciles an optimistic send exactly when the server names its command id (`:78`) | Another person's `input_accepted` does not clear ours; `input_queued` marks `queued` |
| lets the first approval decision stand and names who resolved a later one (`:100`) | `decision` then `resolvedBy`; `openApprovals` empties |
| keeps a blob reference as a reference (`:113`) | `BlobRef` survives `contentOf` |
| records the cursor and ignores an event it has already folded (`:124`) | `lastSeq` never moves backwards; deduplication is `SessionView`'s job |

### `fleet.test.ts` — the merge (6)

| `it` (line) | Proves |
|---|---|
| puts every source in one list, pinned first and newest next (`:60`) | Sort order across a team and a local stub |
| keeps a failing source's last rows and records why (`:81`) | The plane going away does not empty the list |
| joins a private session's two rows, with the daemon's copy winning (`:99`) | Stage 3's merge shape, proven now (`DECISIONS.md` #3) |
| applies live news onto a row without a round trip (`:116`) | `patch` does not call the source |
| filters, counts approvals and sums cost (`:128`) | `filterRows`, `awaitingApproval`, `totalCostMicros` |
| reads the plane's row without inventing anything (`:143`) | `null` cost stays `null`; team rows have no `sync` |

## The fake deployment (`test/support/`)

The fakes implement the protocol as this repository reads `PROTOCOL.md`; they do not
imitate screens (`stage1.test.ts:3-7`). `pnpm fake` runs the same three
(`scripts/fake-deployment.ts:10-12`).

| File | Implements | Assumes about the real server (AUDIT §4.2) |
|---|---|---|
| `harness.ts` | `startHarness(opts)` starts IdP, worker, plane; `signIn` runs the device grant and approves it on a 20 ms timer (`:34-49`); `attach` opens a `SessionAttachment` in `activate` mode with a short backoff list `[10, 20, 40, 80]` (`:51-60`) | — |
| `idp.ts` | `FakeIdp`: `POST /device/code` (`:105-127`, `interval: 0.1`, `expires_in: 30`), `POST /token` for `device_code` and `refresh_token` grants (`:129-148`); `slow_down` once when asked (`:144`); `authorization_pending` until approved (`:145`); refresh tokens rotate and the old one dies (`:132-139`); a CORS allowlist for browser clients (`:37`, `:88-94`); unsigned id tokens (`:157-161`). No authorize endpoint and no `openid-configuration` (`:150`) | That the provider rotates refresh tokens; that it answers the token endpoint cross-origin |
| `log.ts` | `SessionLog`: append-only, `prev_hash`/`hash` over the JSON body, synchronous fan-out to listeners (`:39-50`), `from(seq)` (`:52-54`), `verify()` (`:61-71`) | The hash-chain shape. Only the fake verifies it; `src/` never does (AUDIT §3.2) |
| `plane.ts` | `FakePlane`: `/.well-known/troupe` with `client_id: "troupe-gui"` and five scopes including `groups` (`:120-129`); `/auth/exchange` reading `sub`/`name` from the unsigned id token (`:133-148`); `/rpc` with `me`, `teams.list`, `profiles.list`, `sessions.list` (filters `profile`, `state`, `status`, `origin`, `needs_review`), `session.get`, `session.create` (validates profile and agent), `session.open` (`read`/`activate`), `token.mint`, `session.review`, `session.pin`/`unpin` (`:171-267`); CORS only on browser routes, exact match, never `*` (`:96-113`); `browserFetch(origin)` wraps Node's `fetch` with a same-origin check (`:327-338`) | The row shape of `sessions.list` (`SessionRow`), the `Attachment` shape, that `/auth/exchange` takes `{id_token}`. Discrepancy: the fake still advertises `groups` as a scope; the live plane no longer does (`REPORT.md:222-226`; `DECISIONS.md` #27) |
| `worker.ts` | `FakeWorker`: `initialize` checks `aud` and `exp` (`:178-199`); `auth.expiring` `expiringLeadMs` before `exp` (default 120 000 ms) and close with 4401 at `exp` (`:220-236`); `auth.refresh` re-arms (`:244-257`); `subscribe` replays from `from_seq` with the live boundary closed (`:259-282`); `unsubscribe`, `session.get`, `input.send` (needs `control`), `approval.respond` first-answer-wins with `approval_resolved` (`:315-337`), `turn.cancel`, `profile.switch`, `presence.set` (answers `ok`, emits nothing), `blob.get` capped at 64 KiB (`:357-375`), `fs.list`/`fs.read` refusing `..` (`:377-408`); the scripted agent (`:446-521`) | The closed replay boundary; `auth.expiring` two minutes ahead (`PROTOCOL.md:556-563` says so); the 64 KiB cap (PROTOCOL.md says "may cap", not a number); the `approval_resolved` shape; `session.get` answered over the worker socket; that `presence` ephemerals exist (`REPORT.md:296-298`: written but never exercised) |

## The app's tests (`apps/desktop/test/`)

Added with local-only mode (`DECISIONS.md` #46). `vitest run` renders `<App />` in jsdom
on the app's own Vite configuration (`apps/desktop/vitest.config.ts`), against the fake
daemon above on a real socket and, where a plane is wanted, the fake deployment's plane
and identity provider. `test/support.ts` records every `fetch`, WebSocket, XHR, beacon and
event source the page opens, and drives the app by what its buttons say. The page's
WebSocket is `ws`'s: jsdom's and Node's are both undici's, whose events are built from the
global `Event` — jsdom's, in that environment — and Node's EventTarget refuses them.

| `it` | Proves |
|---|---|
| makes no request to any plane, with a plane sign-in stored and every screen visited | Local-only from a stored choice: straight to the list, Review not offered, a local session started, sent to and answered; every request is the daemon's WebSocket, the markup loads nothing external, and the stored refresh token is untouched |
| is the third door on the sign-in screen, and the next launch remembers it | "Use this computer only" from a fresh start, remembered across a remount with no sign-in screen in between |
| keeps the stored plane sign-in, and goes back to it without asking | Signed in to the fake plane; the switch on *This computer* turns local-only on (no plane traffic for a poll interval, the token kept) and off (signed back in from the kept token, which rotates, with no device code) |
| offers this computer instead of a dead sign-in, and goes back when the plane does | A plane refusing every request: "Continue on this computer", the offline banner, nothing remembered; the plane back and *Try now* signs in with both halves of the list |

## What is not tested

- **No browser tests.** Apart from the app's tests above, which run in jsdom, nothing
  renders `apps/desktop` in a browser; the views were driven by hand
  (`REPORT.md:288-291`). Playwright in CI is in the spec (`spec.md:62`) and not present.
- **The server's half.** Every assumption in the right-hand column above; a kind or
  Kapsule run is what would check it (`REPORT.md:282-287`; `DECISIONS.md` #19). The
  plane's share of it is now `test/e2e.plane.test.ts`, which the root CI's `gui-e2e` job
  runs against a plane built from the same commit ([../e2e.md](../e2e.md)); a session on
  a real pod still wants a cluster.
- **Hash-chain verification.** `SessionLog.verify()` exists only in the fake; no code
  in `packages/client/src` checks `prev_hash` (AUDIT §3.2). The spec defers it to stage 3
  (`spec.md:80`).
- **`FleetStore.patch` in the app.** Tested in isolation (`fleet.test.ts:116`); nothing
  wires it (`REPORT.md:294-295`).
- **The bench and `first-token`** are measurements, not tests; nothing asserts on them.
- **`presence`, `todo.edit`, `session.grant`, `session.pin`, `session.review`,
  `session.erase`, `teams.list`, `me`** — in the client, called by no screen and, apart
  from `presence.set` being sent, by no test.
- **`tokens:check`** is a build guard, not a test; the root CI's `gui` job runs it
  before the typecheck.

## Related

- [architecture.md](architecture.md) §5–7 — the code under test.
- [ci-cd.md](ci-cd.md) — where the suite runs automatically.
- [build.md](build.md) — the image runs this suite too (`Dockerfile:44`).
