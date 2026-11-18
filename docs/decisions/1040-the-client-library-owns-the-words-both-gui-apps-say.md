---
number: 1040
title: The client library owns the words both GUI apps say, one helper per thing, and the apps keep no copy of their own
date: 2026-11-17
status: accepted
issue: 1028
paths:
  - clients/gui/packages/client/src/words.ts
  - clients/gui/packages/client/src/calls.ts
  - clients/gui/packages/client/src/auth.ts
  - clients/gui/apps/desktop/src/views/bits.tsx
  - clients/gui/apps/console/src/views/bits.tsx
  - clients/gui/apps/desktop/src/views/SignIn.tsx
  - clients/gui/apps/console/src/views/SignIn.tsx
symbols:
  - errorText
  - bytes
  - moneyWords
  - durationWords
  - ago
  - sessionStateWords
  - decisionWords
  - unregisteredRedirect
gist: "errorText, bytes (KiB), moneyWords (under a cent), durationWords, ago, sessionStateWords, decisionWords live in @troupe/client; no app formats these itself"
---

The desktop app and the console each turned an error, a size, money, a length of time and
a session's state into words their own way: 1536 bytes read `2 KB`, `1.5 KB` or `1.5 KiB`,
4000 micros `$0.0040`, `under a cent` or `$0.00`, and one session `asleep` in the console and
`Asleep` in the desktop.

**One helper each, in `@troupe/client`** (`words.ts`, and `decisionWords` beside the call's
other words in `calls.ts`), and both apps call it:

- `errorText(e, fallback?)`: the server refusal's `reason`, else the `Error`'s message,
  else the value. A helper with words of its own (`describeError`, `loopError`) adds them
  first and falls back to it.
- `bytes`: binary units, `KiB`/`MiB`, one decimal place left out when nought, `1 byte`. The
  plane's limits and the harness's messages already say KiB and MiB; the decimal units lost.
- `moneyWords`: the terminal's rule, to the cent rounded half up and `under a cent` below
  one, so the turn line reads the same in both clients; thousands separated for budgets.
- `durationWords` and `ago`: `Troupe.Protocol.Words.duration/2` (`:words`, `:adjective`) and
  `ago/2`, the same output for the same input.
- `sessionStateWords`: one table, sentence case as DESIGN.md writes status words (Working,
  Waiting for you, Idle, Failed, Asleep, Read only, Active, Erasure pending). The desktop's
  words won: they are the design's, and the console's lower-case ones were its own.
- `decisionWords`: an answered approval's Allowed, Allowed for this session, Always allowed,
  Denied, which both transcripts start with.

**Sign-in.** Both apps show a failed sign-in as `role="alert"` with Try again where the
plane did not answer, and ask `unregisteredRedirect` whether the provider refused the
address; the wording around it stays each app's.

Not chosen: a formatter per app kept in step by tests, which is what drifted. Left as they
are: the console's `when` (UTC like the audit) and the library's clock-time `when`, which
say a moment rather than how long ago; a price per million tokens (`describeOffer`), which
is dollars to the tenth of a cent on purpose.

Undoing it puts back two vocabularies for one session and three readings of one spend.
