---
number: 982
title: The status lines of every loading and starting state are one file, `docs/design/lines.json`, read by the terminal client, the desktop app and the console through generated, committed readers that take a kind's lines in an order shuffled from a seed
date: 2026-11-15
status: accepted
issue: 911
paths:
  - docs/design/lines.json
  - docs/design/frames.md
  - clients/gui/scripts/lines.ts
  - clients/gui/scripts/lines-rule.ts
  - clients/gui/packages/client/src/lines.ts
  - clients/gui/docs/design/lines.order.json
  - clients/gui/packages/client/test/lines.test.ts
  - clients/gui/apps/desktop/src/frames.ts
  - clients/gui/apps/desktop/src/views/StartSession.tsx
  - clients/gui/apps/console/src/views/bits.tsx
  - clients/tui/lib/mix/tasks/troupe.lines.ex
  - clients/tui/lib/troupe/ui/lines.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/new_session_page.ex
  - clients/tui/test/troupe/lines_test.exs
symbols:
  - Troupe.UI.Lines.order/2
  - Troupe.UI.Lines.pick/3
gist: "One lines.json for every thematic status line; pnpm lines and mix troupe.lines write the readers (checked in CI) and one picking rule, held by a shared order fixture; none in headless, bench, CI or --json"
---

The curtain line's words were written twice, in `frames.ts` and in `model.ex`, three or
so lines a kind and the same first line every turn; the start screen's quips and the
casting steps' asides were written a third and a fourth time; and the console's
`Loading`, `troupe login`'s wait and the setup's busy line said nothing of the kind at
all (#911). A line added to one client was a line the other did not have, and a turn
opened on "the actors are powdering their nose" every time it started.

## Decision

**One source.** `docs/design/lines.json` holds the status lines, keyed by what each is
said over: `starting`, `thinking`, `reading`, `acting`, `compacting`, `casting`,
`waiting_for_a_place`, `daemon_starting`, `signing_in`, `checking_for_an_update`,
`first_run`, `long_turn`, `loading`, and the two that stand alone as sentences,
`start_screen` (the start screen's quip) and `curtain_up` (the casting screen's last
word). Every line that was in a client is in it. A line is lower-case, with no full
stop, an exclamation mark or an emoji, and follows `◐` and precedes ` — the facts`;
the two sentence lists are the exception. Theatre, dry, never sorry, never pretending
to be a person; the vocabulary of a working theatre (the prompt book, the flies, the
green room, the half, the interval, the understudy, the ghost light), not of a
performance. `frames.md` section 7 keeps the register and the rules and links to the
file; its table is gone.

**Generated readers, committed, checked.** `pnpm lines` in `clients/gui` writes
`packages/client/src/lines.ts` (the desktop app's and the console's, through
`@troupe/client`); `mix troupe.lines` in `clients/tui` writes `lib/troupe/ui/lines.ex`.
Both have `--check`, run in CI beside the design tokens' (`pnpm lines:check`, and
`mix check`), as the palette and the stylesheet are. A hand edit of either reader fails
CI.

**One picking rule.** Per turn (or per wait), a kind's lines are taken in an order
shuffled from a seed (the turn's id, else the session's, else a counter), so within a
turn nothing repeats, two turns do not open the same way, and past the end of the list
there is no line, which is the facts alone, as before. The shuffle is FNV-1a over
`kind/seed` into a mulberry32 stream driving a Fisher-Yates, all on unsigned 32 bits;
it is written once in `scripts/lines-rule.ts`, which is copied into the TypeScript
reader, and again in the Elixir generator. `clients/gui/docs/design/lines.order.json`,
written by `pnpm lines` from the TypeScript reader, holds the order for a few seeds, one
with non-ASCII bytes, and both test suites read it, so the two cannot drift. The desktop
seeds a turn with the session's id and the turn's number (counted in the transcript, from
the user's own lines and loop iterations, not the harness's notes); the terminal with the
session's id, else the window's path, and the turn's number; a screen that opens (the
start screen, the casting footer) with the time it opened.

**Where a line goes, and where none does.** A turn past five minutes says a `long_turn`
line in place of the phase's, the same one to its end. The curtain line in both clients;
the desktop's casting screen (an aside a step, from `casting`, and the wait from
`waiting_for_a_place`) and start screen; the terminal's `/new` quip and the `casting —`
footer, which keeps its keys (and says them shorter so a line of 26 characters leaves it
within 80 columns); the console's `Loading` on its slow, whole-page loads only (the
audit, and the check of its whole chain), not on every panel; `troupe login`'s wait,
`troupe update`'s on the error stream and only at a terminal, the first run's busy
lines in the terminal and the desktop, the desktop's search for the daemon. None where
`frames.md` section 7 says none: what waits on a person, a model error, a subagent's own
pane, a failed start; and none in a headless run, `troupe bench`, CI logs or anything
with `--json`, which print the facts.

## Consequences

A line is a pull request to one JSON file, and both clients have it at the next build.
Translating one is translating the file; the facts beside it are localisable the same
way. Changing the rule is changing both places and regenerating the fixture, which fails
a suite until it is done. The lists stay small enough to read in one sitting (twenty to
thirty for the three phases of a turn, ten to fifteen for the others, five to ten for
what is read once), and a line is kept once it ships, since a person may remember it.
