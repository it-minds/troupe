> Audited against troupe-gui commit 783e660 (branch master) plus the uncommitted working tree, 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Conventions

The rules the code follows, with where each is enforced (or only stated), and how to add
the two things most likely to be added next: a protocol method and a view.

## TypeScript

- **The base config is strict** with `noUncheckedIndexedAccess` and
  `exactOptionalPropertyTypes` (`tsconfig.base.json:6-8`). Consequences you will meet:
  index reads are `T | undefined`, so either narrow or use `!` where the index is
  provably valid (`packages/client/src/session.ts:102`, `fleet.ts:211`); an
  optional property cannot be assigned `undefined` explicitly, so build objects with
  conditional spreads (`packages/client/src/pkce.ts:172-174`,
  `apps/desktop/src/views/Sessions.tsx:190-194`) or declare the property as
  `x?: T | undefined` (`connection.ts:43-49`).
- **ESM only.** Every manifest is `"type": "module"`; relative imports inside
  `packages/client` carry a `.js` extension (`packages/client/src/index.ts:1-30`) so the
  compiled output resolves under Node.
- **No Node types in the client's build.** `types: []` in
  `packages/client/tsconfig.json:7`; anything platform-specific is reached through
  `globalThis` with a guard (`auth.ts:99-102`, `pkce.ts:107-113`, `session.ts:377-387`).
  The tests get Node types from `tsconfig.test.json:6`.
- **The desktop app and the client resolve the same source.** Add nothing that makes
  `tsc` and Vite disagree (`apps/desktop/tsconfig.json:14-19`; `DECISIONS.md` #26).
- No linter or formatter is configured. Two-space indentation and LF come from
  `.editorconfig:1-8`.

## Protocol types are open and additive

Every object type in `packages/client/src/types.ts` and `plane.ts` ends with
`[k: string]: unknown` (`types.ts:1-2`, `:62, 73, 79, 93, 102, 115, 124, 139, 145, 153,
173, 182, 190, 196, 205`; `plane.ts:16, 33, 43, 58, 67, 82, 110, 125, 145`). A new
field from the server is not a type error, and a client never rejects a message for
carrying more than it knows. When the server adds a field you need, add it to the
type; do not close the object.

## No framework in `@troupe/client`

The client has no runtime dependencies (`packages/client/package.json` has no
`dependencies` key) and imports nothing from React. State that the app needs lives in
the client as plain classes and pure functions (`FleetStore`, `SessionAttachment`,
`fold`), and `apps/desktop/src/hooks.ts` is "a thin adapter … Nothing in here knows the
protocol" (`hooks.ts:1-3`; `DECISIONS.md` #1). If something needs a socket or a
`fetch`, it goes in the client; if it needs a `useState`, it goes in the app.

## The generated stylesheet

`apps/desktop/src/tokens.css` and `apps/desktop/src/mark.ts` are generated from
`docs/design/themes/*.tokens.json` by `scripts/tokens.ts` and committed
(`tokens.css:1-3`; `DECISIONS.md` #14). Change a token in **all three** theme files, run
`pnpm tokens`, commit the lot. `pnpm tokens:check` (`package.json:14`) regenerates and
`git diff --exit-code`s them; CI's `check` job would run it first (`ci.yml:42-43`).

The generator refuses a theme whose token names do not match the others exactly
(`DECISIONS.md` #37), which is what "three themes, one contract" means in practice: a
component reads `--waiting-solid` and never a hex, and never branches on a theme. Never
add a colour directly in `styles.css`: "If a state needs one, it needs a semantic token
first" (`docs/design/DESIGN.md:289`) — and a token that only one theme can answer is not
a token.

## Design rules

From `README.md:155-160`, restated in `apps/desktop/src/styles.css:3-13` and enforced
in `views/bits.tsx:1-6`:

| Rule | Where it bites |
|---|---|
| **Amber is a job, not a mood.** `--waiting-*` marks work that has stopped and needs a person; nothing else may use it | `statusOf` is the only function that returns `waiting` (`bits.tsx:44-51`); `personColour` excludes amber (`bits.tsx:111-121`); `DESIGN.md:19`, `:290` |
| **Structure comes from hairlines and alignment**, not cards, shadows or gradients | `styles.css:7-9`; the one decorative shadow is the approval footlight (`styles.css:12-13`; `DESIGN.md:24`) |
| **A status is a dot and a word.** Colour is never the only carrier | `Pill` always renders a `.dot` and a word (`bits.tsx:28-35`); `DESIGN.md:146`, `:296` |

Other rules a change must not break (`DESIGN.md` §12, `:287-302`): no approval in a
modal; nothing held that a reconnect cannot rebuild; no optimistic insert into the
stream — render as Queued (`Session.tsx:246-255`; `DECISIONS.md` #11); do not move
focus when an event arrives (`Session.tsx:216-219`); remove, do not disable, the
composer on a read-only session (`Session.tsx:585-593`); markdown is rendered, not
`<pre>`-dumped (`Session.tsx:384-388`). Copy is plain and never says pod, namespace,
worker, ordinal, container or cluster (`DESIGN.md:269`).

## `DECISIONS.md` and `REPORT.md`

- **`DECISIONS.md`** is "every judgment call this repository made that a reader could
  reasonably have made differently, with the reason. Numbered, append-only"
  (`DECISIONS.md:3-5`). Thirty-five entries so far, grouped by phase. Add one whenever
  you choose between two defensible designs, name what you rejected, and never edit an
  old entry — append a new one that supersedes it.
- **`REPORT.md`** is the stage report the spec asks for (`spec.md:92-93`): what was
  built, the command output that proves each done item, what was found against the
  live plane, and known limitations. Update the limitations when you remove one.
- Both files are untracked at audit time; the practice is in the working tree, not in
  the history.

## Commit style

Three commits exist (`git log --oneline`):

```
783e660 spec.md: the GUI, in four stages
8fcd396 Plan: local sessions, and private sessions that follow you
68a132c Ground work: the protocol client, a throughput bench, and a first GUI shell
```

The pattern: a sentence-case subject that says what the change *is*, sometimes with a
`scope:` prefix, no conventional-commit type, no trailing period. The whole stage-1
change is uncommitted, so there is no example of a small fix commit to imitate.

## Line endings

`.gitattributes:1` sets `* text=auto eol=lf`; `.editorconfig:4` says `end_of_line =
lf`. Both matter on Windows: the generated `tokens.css` is compared with `git diff
--exit-code`, and a CRLF checkout would make `pnpm tokens:check` fail on every line.
Configure Git to honour `.gitattributes` (it does by default) and do not override with
`core.autocrlf=true`.

## Adding a protocol method

Decide which transport carries it:

| The method is | Put it in | Pattern to copy |
|---|---|---|
| Plane JSON-RPC over `POST /rpc` (listing, placing, minting, ACLs) | `packages/client/src/plane.ts`, a one-line typed wrapper over `rpc` | `reviewSession` (`plane.ts:365-367`), `pinSession` (`:379-381`) |
| A command or read on the worker socket, scoped to a session | `packages/client/src/session.ts`, a method on `SessionView` that calls `this.conn.call` with `command_id: this.conn.nextCommandId()` for commands and `session_id` | `switchProfile` (`session.ts:190-196`), `fsRead` (`:217-219`) |
| A new inbound notification | `packages/client/src/connection.ts` dispatch (`:271-291`) plus a hook in `ConnectionHooks` (`:52-61`) | `auth.expiring` (`:280-282`) |
| A new durable or ephemeral event the transcript should show | `packages/client/src/transcript.ts`: a `case` in `fold` (`:222-398`) or `foldEphemeral` (`:401-418`); add to `SYSTEM_TYPES` (`:179-197`) if it is lifecycle | `approval_resolved` (`:338-346`) |

Then: add the shape to `types.ts` or `plane.ts` as an open object; export anything new
from `index.ts` (`index.ts:1-30`); expose it to React through `hooks.ts` only if a view
needs it; add a case to `test/support/worker.ts` or `plane.ts` and a test. Before any of
this, the server's `PROTOCOL.md` should already name the method (`spec.md:61`).

## Adding a view

1. Create `apps/desktop/src/views/<Name>.tsx`. Import only from `react`,
   `@troupe/client`, `../hooks`, `../shell` and sibling views (`views/Session.tsx:13-21`).
2. Get data through a hook (`useFleet`, `useProfiles`, `useSessionView`) or `auth.rpc`
   for a one-off call (`views/Sessions.tsx:189`); never open a socket in a component.
3. Add a member to the `Where` union in `App.tsx:19`, a rail button if it is a
   top-level screen (`App.tsx:43-56`), and a branch under `<main>` (`App.tsx:71-93`).
   There is no router to register with.
4. Use `Pill`, `statusOf`, `Cost`, `When`, `Where`, `Loading` from `views/bits.tsx`
   rather than restating status logic.
5. Style with existing tokens in `styles.css`; if a new token is needed, it starts in
   all three files under `docs/design/themes/` (see above). Check the screen at 380 px
   wide (`DESIGN.md:262`), that every status is a glyph and a word, and that it reads in
   all three themes in both modes — Appearance is the fastest way to look.
6. Record any arguable choice in `DECISIONS.md`, and if the view closes a gap listed in
   `REPORT.md` "Known limitations", remove the line.

## Related

- [architecture.md](architecture.md) — the modules the rules above shape.
- [testing.md](testing.md) — where a test for the new method goes.
- [../user/features.md](../user/features.md) — what the views do for a person.
