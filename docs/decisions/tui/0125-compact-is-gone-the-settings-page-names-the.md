---
number: 125
title: "`/compact` is gone, the settings page names the commands the table has, and headless mode answers the budget question as the question it is"
date: 2026-09-27
status: accepted
issue: 124
supersedes: [86]
paths:
  - clients/tui/lib/troupe/client.ex
  - clients/tui/test/troupe/cli_test.exs
  - clients/tui/test/troupe/command_palette_test.exs
  - clients/tui/test/troupe/settings_test.exs
gist: "`/compact` is gone, the settings page names the commands the table has, and headless mode answers the budget question as the question it is"
---

Paper cuts
after 0.6.0 (defects D32), part of #124. `/compact` asked a session to shrink its
context, and since the TUI became a client of the daemon no request carries that:
both clients answered with a sentence saying the other side compacts by itself,
at `compact_at` on this machine and on its plane remotely. The entry leaves the
harness's table (root Decision 698), and the TUI's clause, the `Troupe.Client`
callback and its two implementations go with it. This supersedes the sentence of
Decision 86 that made `/compact` the hand escape hatch: the wedge it was for, a
prompt too big to send, is the context overflow the harness compacts and retries
by itself. The help beside the settings lists the table's setup commands, `/help`
among them, in place of prose that could drift from the table, and `/help`'s
summary no longer says "this list", since it is read outside the palette now.
Headless mode answered the budget question with `approval.respond` on the
question's id, which no approval has, so a run that reached a limit waited for
ever rather than stopping as Decision 120 says it did; it now answers `stop`
through `question.answer`, and the run ends `1`. Proof:
`test/troupe/command_palette_test.exs` (the built-ins still the table's),
`test/troupe/settings_test.exs` ("the help's commands are the setup section of
the command table") and `test/troupe/cli_test.exs` ("headless printer stops at
the budget question and exits 1"), which waited out its 15 seconds before.
