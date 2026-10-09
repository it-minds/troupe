---
number: 817
title: "`troupe setup` walks the daemon's own first-run questions as one screen and writes nothing before its summary, and the daemon writes only what a person chose, so the same answers leave the same config.yaml as `troupe config`'s questions"
date: 2026-10-09
status: accepted
issue: 76
supersedes:
  - 705
paths:
  - apps/troupe_core/lib/troupe/setup.ex
  - apps/troupe_core/test/troupe/setup_test.exs
  - clients/tui/lib/troupe/ui/setup.ex
  - clients/tui/test/troupe/setup_screen_daemon_test.exs
symbols:
  - Troupe.Setup
  - Troupe.UI.Setup
gist: "Setup writes auth and auto_approve only where they change the file: same answers, same config.yaml as troupe config; the TUI holds writing steps to the summary"
---

Issue #76's terminal half, after Decisions 705 and 762: `troupe setup`, and plain `troupe`
on a machine with no provider, open a full-screen setup in the TUI over `setup.get` and
`setup.answer` (TUI Decision 153 has the screen). Two things had to hold for it to be the
same setup as the line-by-line `troupe config` questions, and neither did on the tip.

- **The daemon writes only what was chosen.** For the same answers the daemon's flow left
  a `config.yaml` with two lines `troupe config`'s questions never write, `auth:
  "api_key"` and `auto_approve: false`, and a `config.yaml.previous` beside a file it had
  just created, because the `workspace` step wrote the default over it. Both are the
  defaults, so the files meant the same and read differently, and a person comparing
  them, or a client reading `config.changed`, saw a change that was none. Now `auth` is
  written where it changes what the file means (`bearer`, or `api_key` over a file that
  meant bearer, its `auth_token` included) and `auto_approve` where the setting in force
  runs everything or the answer is `auto`. That is part of Decision 705 ("`auto_approve`
  at `workspace`") replaced: asking first is still written over a file that runs
  everything, and a re-run still turns either off. The desktop app's first run writes
  the smaller file too, which it shows nowhere.
- **The terminal holds what writes until its summary.** The desktop app sends each
  answer as it is given, so its settings are written at `models`, before its last
  screen. The terminal's screen sends `where`, `provider` and `key` at once, since they
  write nothing and the daemon's answer to the key (checked, and the models listed) is
  what the next question needs; `models`, `workspace`, `daemon`, `finish`, and copying
  opencode's providers in, are held on the screen and sent in the flow's order when the
  summary is confirmed. So Esc anywhere before that writes nothing, and the summary is
  true when it says what Enter will write. A refusal after the summary (the daemon is
  the judge of every answer) puts the screen back on that step with the reason, and
  leaving then says that what was saved stays.
- **Choices not taken.** Changing the line-by-line flow to send `auth` and `auto_approve`
  too: it would make the two files agree by making both say more than was chosen. A
  `keep` answer on the `daemon` step: an entry that is there already is answered `true`,
  which the daemon writes again as it is (Decision 762), and the screen says so.

**Proof:** `apps/troupe_core/test/troupe/setup_test.exs` ("the file is the one troupe
config's questions write for the same answers": a typed key, an `{env:VAR}` reference and
a gateway, byte for byte and no `.previous`, failing on the chunk's tip with `auth:
"api_key"`, `auto_approve: false` and a `.previous`; "asking first turns off a file that
ran everything"; "bearer is written"), and the terminal client's
`setup_screen_daemon_test.exs`, which runs the screen against the daemon it embeds: the
fake provider, back once, the first session working in the project; a gateway on a local
stand-in with a typed key, whose file equals the one `troupe config`'s questions write
against the same daemon; and Esc on a fresh machine, which leaves no file at all.
