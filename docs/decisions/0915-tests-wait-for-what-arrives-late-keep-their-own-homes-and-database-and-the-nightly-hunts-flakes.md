---
number: 915
title: "A test waits for what arrives after an async step rather than asserting it at once, sets no environment variable another test can read, runs against a plane test database of its checkout's own, and the GUI's client tests read nothing from outside `clients/gui` that the image is not given; the nightly runs every suite again and names each test that failed in any run"
date: 2026-10-16
status: accepted
paths:
  - clients/gui/apps/desktop/test/support.ts
  - clients/gui/apps/console/test/support.ts
  - clients/gui/apps/desktop/test/waits.test.tsx
  - clients/gui/apps/console/test/waits.test.tsx
  - clients/gui/packages/client/test/support/waits.ts
  - clients/gui/packages/client/test/support/image-reads.ts
  - clients/gui/packages/client/test/image-reads.test.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/gui/packages/client/test/fakes.test.ts
  - clients/gui/apps/desktop/vitest.config.ts
  - clients/gui/apps/console/vitest.config.ts
  - apps/troupe_protocol/credo/async_env.ex
  - .credo.exs
  - clients/tui/.credo.exs
  - config/config.exs
  - apps/troupe_plane/test/support/test_database.exs
  - apps/troupe_plane/test/test_helper.exs
  - apps/troupe_worker/test/test_helper.exs
  - scripts/flake-hunt
  - .github/workflows/ci.yml
  - .github/workflows/nightly.yml
symbols:
  - Troupe.Credo.AsyncEnv
  - Troupe.Plane.TestDatabase.ensure/0
gist: "GUI tests await sees(); async ExUnit sets only TROUPE_TEST_ vars; one plane test DB per checkout; client tests read only what the GUI image copies; nightly names every flake"
---

# Tests wait, keep their own homes and database, and the nightly hunts flakes

## Context

Rerunning a red job had become routine. A census of the `ci`, `nightly` and `release`
runs from 2026-09-25 to 2026-10-16, the coordinator's notes and `defects.md` (D8,
D125-D129) found about thirty tests that failed and then passed with no change. Most had
been fixed one at a time; the same few shapes kept coming back:

- **A GUI assertion made at once on what a later render draws.** `await waitFor(…)` on one
  thing, then `expect(says(…)).toBe(true)` on another: true on a fast machine, false on a
  busy one (`teams.test.tsx` twice, `onboarding.test.tsx`, `palette-agents-watch`,
  `start-onboarding`, `daemon-restart`, `servers-panel`, the console's `policy`). Three were app
  bugs the same timing exposed: an update restarted before this computer's daemon had said
  what was at work, a theme picked before the daemon's settings came was never written to
  it, and a Ctrl-K pressed as a session's screen appeared was lost to a listener a passive
  effect had not yet attached.
- **Shared homes.** A test that sets the process environment changes it for every test
  running beside it (`DoctorCLITest`'s shared homes, D8's "order or shared state").
- **One plane test database for every checkout.** Two worktrees' plane suites, or a plane
  suite beside another worktree's worker suite, lock the same rows from two sandboxes and
  deadlock (`40P01`), and the failure lands in whichever test lost.
- **A GUI test reading a file the image is not given.** The image runs the client's tests
  with `clients/gui` as its context; #728's test read a file from the repository's root that
  the image never had, and only a later pull request's cluster job found it (#732).
- **Found late.** A flake was seen in somebody's pull request, often a week after the change
  that made it, and the soak stopped at its first failure, naming one test.

## Decision

1. **GUI: wait for anything that arrives after an async step.** Both apps' test supports
   have `await sees(text)` (the console's also `await seesLink(label)`), a `waitFor` on the
   page's words; given a function for where to look, it asks it again on each look, since a
   row can be drawn anew meanwhile. `waitFor` treats a look that throws (a row gone for a
   render) as not yet, and says what it last threw at its deadline. Each app's
   `waits.test.tsx` fails on a bare `expect(says(…)).toBe(true)`
   or `expect(link(…)).not.toBeNull()` (`packages/client/test/support/waits.ts`). A line
   meant at once says why, on itself or the line above: `// at once: <why>`. Waiting for
   what is already there costs nothing, so the waiting form is the default and the
   synchronous one needs a reason. Negative assertions are not covered: they cannot flake
   this way, only pass early.
2. **ExUnit: no shared homes.** An `async: true` module calls `System.put_env/2` or
   `System.delete_env/1` only for a variable named `TROUPE_TEST_...`, which by its name is
   that test's own: given as a literal, or as a name the module binds to one. Anything else
   (`HOME`, a `TROUPE_*_HOME`, `PATH`) makes the module `async: false`, or the code under
   test takes the home as an option. `Troupe.Credo.AsyncEnv` checks it in both credo
   configurations, on test files; `# credo:disable-for-next-line` with a reason is the way
   past it.
3. **A plane test database per checkout.** Outside CI the test database is
   `troupe_plane_test_<hash of the checkout's path>`; CI (`CI` set) keeps
   `troupe_plane_test`, and `TROUPE_PLANE_TEST_DB` names one outright. The plane's and the
   worker's test helpers create and migrate it before the suite starts
   (`Troupe.Plane.TestDatabase.ensure/0`), so a new checkout or a branch with a new
   migration needs no step by hand. One checkout running its plane and worker suites at
   once still shares one database; that is one person's choice, not two people's.
4. **The GUI's client tests read only what the image is given.** Every client test file
   runs with `support/image-reads.ts` loaded first: a read of a file inside the repository
   and outside `clients/gui` fails the file unless `clients/gui/Dockerfile` copies it
   (`COPY --from=licences`) and the root's `.dockerignore` keeps it. A file the test probed
   for with `existsSync` first is one it does without when it is missing, as in the image,
   and passes. In the image, which has no `.dockerignore`, the guard does nothing.
5. **The fakes stop what their clients left open.** A fake server's `stop` ends every
   connection still open to it, since a page unmounted mid-request leaves one and
   `server.close` waits for it; the fake daemon's `delayMs` makes any method slow, to
   reproduce "a busy machine" on purpose rather than by luck.
6. **The nightly hunts flakes.** `scripts/flake-hunt <runs> <command>` runs a suite that
   many times, carrying on past a failed run, and names every test that failed in any run
   with how many runs it failed in (in the job summary and as error annotations). The
   soak (9 more runs of each umbrella app's suite in the nightly and a release) uses it and
   also runs after a failed first pass; with `hunt: true` the nightly also runs the TUI's
   suite 3 more times and the GUI's 5 more, the apps' files and tests in a random order
   (`TROUPE_TEST_SHUFFLE=1`). ExUnit draws a seed of its own each run.

## What a fix is

A flaky test is fixed at its cause: no retry, no `--max-failures`, no `@tag :skip` and no
longer timeout. A longer wait is right only where what is waited on is genuinely long, and
its comment says why. Where the cause cannot be found, the test stays as it is and the
finding goes to `docs/developer/defects.md` with what was tried.

## Consequences

- A GUI test reads `await sees("…")` where it read `expect(says("…")).toBe(true)`; 335
  were converted. A failing `sees` takes its ten seconds to say so, where the bare form
  failed at once.
- A new checkout's first plane run creates a database; old `troupe_plane_test_*`
  databases of removed worktrees stay in the dev Postgres until `scripts/dev-down --purge`
  removes its volume.
- The nightly takes about fifteen minutes longer, and a new flake is in its summary the
  next morning rather than in somebody's pull request.
