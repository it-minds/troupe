---
number: 146
title: The session picker says a private session is private and how its sealing stands, and `c` claims one another device sealed last; a plane's `erasure_pending` is a state
date: 2026-10-05
status: accepted
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/remote/capability.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/support/fake_remote.ex
  - clients/tui/test/troupe/private_sessions_test.exs
gist: The session picker says a private session is private and how its sealing stands, and `c` claims one another device sealed last
---

Root Decision 785, D61, D59. A summary carries `kind`, `sync` and `device`
(a daemon's `session.list`, or a plane's row, which says only `erasure_pending`). A
private row's title starts `[private · synced]`, in `@troupe/client`'s words in
lower case (`View.kept/1`, `sync_words/2`), HQ's rows too; the detail pane says the
sentence, and for one another device holds, as its title does, that `c` claims it.
`c` calls `Troupe.Client.claim_session/2`, a fleet call the daemon answers with
`session.claim` and a plane with `:unsupported`, says a refusal in the desktop app's
words, and takes the list again. A key rather than a slash command: a claim is about
the row the person is looking at, and needs no `Troupe.Commands` entry.
`Remote.Worker.session_state/1` reads `erasure_pending`, which it read as none, so a
plane's row said dormant; `Capability` refuses input to it; HQ's state column says
`erasing`, in its ten cells. Proof: `test/troupe/private_sessions_test.exs` against
`FakeRemote`, which now keeps a claim fenced on its epoch and answers `session.get`
for a registered row: the picker says `[private · on ada-laptop]` and `c` makes the row
this machine's; `[private · waiting to be erased]`, and `c` has nothing to claim; a
plane's private row `erasure_pending` with no input; all three failing on the tip.
