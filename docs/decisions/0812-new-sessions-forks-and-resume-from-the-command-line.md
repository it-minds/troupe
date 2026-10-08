---
number: 812
title: "`/new` and `/back` are built-ins; the daemon forks a session with `session.fork`, its log the parent's after `session_forked`; `troupe resume` takes `latest`, `--private` and `--headless \"message\"`; what another device holds or what is erased is refused, saying why and offering `/new`"
date: 2026-10-08
status: accepted
issue: 484
paths:
  - PROTOCOL.md
  - apps/troupe_protocol/lib/troupe/sessions/fork.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/session/log.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - apps/troupe_core/test/troupe/session/fork_session_test.exs
  - apps/troupe_gateway/test/troupe/gateway/fork_test.exs
  - clients/tui/test/troupe/resume_cli_test.exs
symbols:
  - Troupe.fork_session/2
  - Troupe.Sessions.Fork.chain/3
  - Troupe.Session.Log.write_new/2
  - Troupe.Client.resume_refusal/1
  - Troupe.Client.open_refusal/2
  - Troupe.CLI.Runner.one_turn/3
gist: A local fork is the plane's chain (Fork.chain) written as the child's log, not a branch; resume refuses only what can't go on here; archived is dormant
---

Issue #484. Starting a fresh session meant leaving the TUI, and carrying a session on from
the command line meant entering it.

- **Two built-ins in the harness's table.** `new` (section `session`, `/new [--private |
  --remote PROFILE | --branch]`) and `back` (section `navigate`), so `troupe --help`, the
  reference and both palettes list them (Decisions 698, 767). The desktop app greys them
  with its default reason; the TUI runs them (TUI Decision 151). A file in
  `.troupe/commands/` named `new.md` or `back.md` is now shadowed by the built-in, as
  Decision 763 shadows every built-in's name.
- **`/new --branch` is a fork, and the daemon has one now.** The plane's `session.fork`
  copies a parent's history into a new session on a pod; the daemon had none, and a
  "branch" in its sense (`session.create` with `parent`, Decision 646) is a second agent in
  the parent's window, not the conversation carried on elsewhere. `session.fork
  {session_id, config?}` on the daemon answers `{session_id, workspace, forked_from}`. The
  rule is the pod's: `Troupe.Sessions.Fork.chain/3`, the opening `session_forked` and the
  reseal `copy/3` already did, given the parent's events instead of read from segments,
  which `copy/3` now calls too. `Troupe.fork_session/2` reads the parent's log off disk,
  running or not, writes the chain as the child's `events.jsonl` (`Log.write_new/2`,
  exclusive: never over a log that is there), and opens the child as a resume of that log,
  in the parent's workspace under its profile. So the child's agent starts from the
  parent's conversation; the parent is neither changed nor woken.
- **A fork is not a branch.** No `parent` in its row: a branch is shown in its parent's
  window, and a fork is a session of its own, in the picker, with its own budget (a
  restart forgets the budget, State's own rule) and its own erasure. Its `reason` is
  `branch`, the plane's word for one.
- **Not a private session, yet.** Its child would be a copy no plane knows of, sealed
  nowhere, and erasing the parent would leave it. `invalid_params` with `reason:
  "private"`, and one being erased is `not_found` with `"erased"`, as `session.claim` says
  it. A pod refuses `session.fork` as it refuses archive, pin and erase: it is the plane's
  (`done through the plane`), a new row, key and placement.
- **`troupe resume` grows, rather than a second command.** `latest`: the newest session
  here, straight in; `--private`: the newest private one; neither: the picker, as before.
  "Newest" is not a branch, and is one that did something before an empty scratch session
  (which also mends `troupe resume` opening a branch or an empty session, a clause of
  D43 in defects.md, trimmed there). An id is that session wherever its
  directory. `troupe --resume …` is accepted as the same command line, the spelling the
  issue used.
- **`--headless "message"`** runs one turn and exits with the codes `troupe run
  --headless` exits with. The session is named (an id, `latest`, or `--private` alone),
  since there is no picker, and a lone word after `resume` is refused rather than guessed
  at. The printer is the same, with `:since`: a durable event stamped before the run is
  the session's history, neither printed nor taken for the turn's end (TUI Decision 110
  reads the journal back so a quick run's rest is not missed; this keeps that and does not
  end on the last turn's rest). Its client name is `troupe-headless` (Decision 787).
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
- **Proof:** `cli_test.exs` ("troupe resume takes latest, …") failed on the tip with
  `session_id: "latest"`; `new_session_test.exs`'s first test failed there with `/new`
  doing nothing. `fork_session_test.exs` (the child's log is `session_forked` then the
  parent's events numbered on from 2, its chain verifies, the parent is byte-for-byte as
  it was, no `parent` in the child's row, and the child's first model request carries the
  parent's reply), `fork_test.exs` over the protocol (the answer, the row, the refusals),
  the worker's `auth_test.exs` (`session.fork` is the plane's), and `resume_cli_test.exs`
  (one turn printed alone with its turn line; `ID --headless` and `--resume latest
  --headless` exit 0 on the right session past a newer empty one; `--private`; a session
  not here, one another device holds and one being erased refused, against the
  `FakeRemote` stand-in as `private_sessions_test.exs` uses it). Not tried against a
  plane: a held session there, and the plane's own `session.fork` beyond its stand-in.
