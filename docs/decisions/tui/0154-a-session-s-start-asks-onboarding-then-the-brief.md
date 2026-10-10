---
number: 154
title: A new session asks about onboarding, then the brief, as one-key questions in its root window, answered from the command line or the window while nothing is typed; the librarian starts only once onboarding is answered
date: 2026-10-10
status: accepted
issue: 516
paths:
  - clients/tui/lib/troupe/client/daemon/start.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/cli/onboard.ex
  - clients/tui/test/troupe/start_onboarding_test.exs
symbols:
  - Troupe.Client.Daemon.Start
  - Troupe.Client.answer_local/3
  - Troupe.Remote.Worker.post/3
  - Troupe.UI.TUI.Model.local_question/1
  - Troupe.CLI.Onboard.describe/1
gist: "Start questions are :local_question events in the root window; y/n/r and Enter answer them while nothing is typed; librarian after onboarding"
---

Root Decision 835, issue #516's third wave. Amends 127 and 131 only in when the librarian
starts: after onboarding is answered, and an outdated brief asked first; their rules (the
daemon's `refresh_due`, saying why none starts) are unchanged and moved with the code into
`Troupe.Client.Daemon.Start`. On the chunk's tip a first session over a `CLAUDE.md` with no
brief started the librarian at once and asked nothing.

- **The questions.** At a new session's start (`create_session`, unless the caller passes
  `refresh_brief: false`, as a headless run does), in a git repository, the client asks
  the daemon `onboard.plan`. Onboarding `first`: "Onboard 5 files from Claude Code and
  Cursor into Troupe's own? [Y/n/r]", the files listed above it, one a line, with what was
  skipped. `y` (or Enter) writes every ordinary file (`onboard.apply` with `all`), then asks
  for each new `AGENTS.md` on its own, in `troupe onboard`'s words, `[y/N]`; `r` shows each
  file as `troupe onboard` shows it (its heading, notes and diff, `Troupe.CLI.Onboard`'s
  `describe/1`, the diff coloured as an edit's) and asks for it, `[y/N]`; `n` says no to all
  of them (`onboard.decline` with `all`), remembered for this version. `outdated`:
  "Onboarding rules changed since this repository was onboarded (v1 to v2). Re-run now?
  [Y/n]", Yes writing as `y` does. Then, and only then, the brief: an outdated one is
  "The librarian's survey changed (v1 to v2): rewrite the brief now? [Y/n]" (`n` is
  `memory.decline`), and otherwise the librarian starts as 127 and 131 have it. Each answer
  says what it did as a line (`onboarded .troupe/rules/style.md`, `left out 2 files; …`).
- **A question box like an approval's, not the setup's screen.** The question is the
  client's own `:local_question` event in the root window's journal, written by the
  session's worker once the session's first event has opened the window
  (`Troupe.Remote.Worker.post/3`, `note/2`'s way, so a rebuilt screen has a window to draw
  it in), and its answer a `:local_question_answered`: a screen rebuilt from the journal
  draws exactly what is still asked, and a question left open when the person quit is
  still there, and answerable, when the session is opened again. The model holds it as a
  pending item of kind `:local`, so the window says it needs you as it does for an
  approval, and draws it in the pane and at the foot of its tile, since a new session's
  screen is the command line over the tile. Not the setup's full screen (TUI Decision
  153): that runs before any session, and these questions belong to one, between its first
  event and the person's first line. Not `ask_user`'s question: that is the model's,
  answered over the protocol, and a typed `y` there is an answer, where here it would be a
  first message to the agent.
- **One key, from where the person is.** While nothing is typed, the question's keys
  answer it, and Enter is its default (the capital in `[Y/n/r]`), from the command line
  (where a new session opens) as from its window; with anything typed, keys are text, as
  always. `Troupe.Client.answer_local/3` takes the answer and does what follows before it
  returns: the write, the no, the next question, the librarian. Each question's data
  carries what the next step needs (the plan's items with their ids, the brief's due), so
  the client keeps no state but the journal. A pod's session asks nothing
  (`Troupe.Client.Remote` refuses an answer).
- **Order and gating.** The librarian waits for the last onboarding answer, so it reads
  the `AGENTS.md` onboarding wrote. Onboarding is asked in a git repository only, as the
  librarian starts in one only (105): `troupe` opened in a home directory asks nothing.
  The brief's question follows 127's gates (memory on, `memory_auto_refresh`, a
  repository, a model to ask). A daemon from before `onboard.plan` starts the librarian as
  before. Headless prints the daemon's `onboarding_suggested` line and asks nothing.
- **Proof.** `test/troupe/start_onboarding_test.exs`: a first session over a `CLAUDE.md`
  and a Cursor rule asks the one question with the two files listed and no librarian; `y`
  writes the rule and asks for the new `AGENTS.md` on its own, still no librarian; its `y`
  writes it and the librarian starts on the missing brief; the next session asks nothing
  (failed on the chunk's tip: no question came, and the librarian started at once). `r`
  driven through the terminal UI's keys: the `AGENTS.md`'s diff on screen with `[y/N]`,
  Enter leaving it, then the rule's question and `y` writing it, and `y` typed into the
  box once nothing is asked. `n` leaving every file and the next session asking nothing; an
  outdated onboarding asked with `[Y/n]` and Enter re-running it; an outdated brief asked,
  `n` remembered and the next session asking nothing; its `y` starting the librarian on
  the refresh prompt; headless asking nothing. `memory_client_test.exs` unchanged and
  passing (127 and 131). `mix check` in `clients/tui`, and the installed TUI driven
  headlessly against the installed daemon on a scratch repository (the pull request has
  it).
