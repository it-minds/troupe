---
number: 699
title: "The budget question is answered with how much more and for how long: a typed amount raises the limit that asked, for this run, this session or this workspace; an answer that cannot be read is asked back; a pod's terms are a ceiling"
date: 2026-09-26
status: accepted
issue: 183
paths:
  - apps/troupe_core/lib/troupe/agent/budget_question.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/budget.ex
gist: "The budget question is answered with how much more and for how long: a typed amount raises the limit that asked, for this run, this session or this…"
---

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
