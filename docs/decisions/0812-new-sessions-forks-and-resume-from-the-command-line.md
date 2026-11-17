---
number: 812
title: "`/new` and `/back` are built-ins; the daemon forks a session with `session.fork`, its log the parent's after `session_forked`; `troupe resume` takes `latest`, `--private` and `--headless \"message\"`; what another device holds or what is erased is refused, saying why and offering `/new`"
date: 2026-10-08
status: accepted
issue: 484
paths:
  - apps/troupe_protocol/lib/troupe/sessions/fork.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/runner.ex
symbols:
  - Troupe.fork_session/2
  - Troupe.Sessions.Fork.chain/3
  - Troupe.Session.Log.write_new/2
  - Troupe.Client.resume_refusal/1
  - Troupe.Client.open_refusal/2
  - Troupe.CLI.Runner.one_turn/3
gist: A local fork is the plane's chain (Fork.chain) written as the child's log, not a branch; resume refuses only what can't go on here; archived is dormant
---

- **Two built-ins in the harness's table.** `new` (section `session`, `/new [--private |
  --remote PROFILE | --branch]`) and `back` (section `navigate`), so `troupe --help`, the
  reference and both palettes list them (Decisions 698, 767). The desktop app greys them
  with its default reason; the TUI runs them (TUI Decision 151). A file in
  `.troupe/commands/` named `new.md` or `back.md` is now shadowed by the built-in, as
  Decision 763 shadows every built-in's name.
- **`/new --branch` is a fork, and the daemon has one now.** The plane's `session.fork`
  copies a parent's history into a new session on a pod; the daemon had none, and a
  "branch" in its sense (`session.create` with `parent`, Decision 646) is a second agent
  in the parent's window, not the conversation carried on elsewhere. `session.fork
  {session_id, config?}` on the daemon answers `{session_id, workspace, forked_from}`. So
  the child's agent starts from the parent's conversation; the parent is neither changed
  nor woken.
- **A fork is not a branch.** No `parent` in its row: a branch is shown in its parent's
  window, and a fork is a session of its own, in the picker, with its own budget (a
  restart forgets the budget, State's own rule) and its own erasure.
- **Not a private session, yet.** Its child would be a copy no plane knows of, sealed
  nowhere, and erasing the parent would leave it. `invalid_params` with `reason:
  "private"`, and one being erased is `not_found` with `"erased"`, as `session.claim` says
  it. A pod refuses `session.fork` as it refuses archive, pin and erase: it is the plane's
  (`done through the plane`), a new row, key and placement.
- **`troupe resume` grows, rather than a second command.** `latest`: the newest session
  here, straight in; `--private`: the newest private one; neither: the picker, as before.
  "Newest" is not a branch, and is one that did something before an empty scratch session
  (which also mends `troupe resume` opening a branch or an empty session, a clause of D43
  in defects.md, trimmed there). An id is that session wherever its directory.
- **`--headless "message"`** runs one turn and exits with the codes `troupe run
  --headless` exits with. The session is named (an id, `latest`, or `--private` alone),
  since there is no picker, and a lone word after `resume` is refused rather than guessed
  at. Its client name is `troupe-headless` (Decision 787).
- **What is refused, and what is not.** Refused, in one sentence that says why and offers
  `/new`, from the CLI and from the TUI's picker, `/resume` and `/back` alike
  (`Client.resume_refusal/1`, `open_refusal/2`): a private session another device holds
  (`sync: "elsewhere"`, Decision 785: carrying it on here would make two histories, so it
  says to claim it first); one erased, or being erased; an id the daemon does not have
  (`not_found`: erased locally, or never here; the daemon forgets an erased local session,
  so the two read alike). **An archived session is not refused.** `session.archive` makes
  a session dormant, on the daemon and on the plane alike, and PROTOCOL.md says an
  activating command brings a dormant one back: refusing it would make archiving a door
  that only closes. `resume` opens it, and the next line wakes it.
