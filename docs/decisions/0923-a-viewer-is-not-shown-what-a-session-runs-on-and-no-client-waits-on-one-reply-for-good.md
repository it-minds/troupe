---
number: 923
title: "Someone who may only watch a session is not shown what it runs on (the provider's address and the state directory read as set by the profile); no client call waits for its answer for good, and the terminal's first run goes by the daemon's record as the desktop's does"
date: 2026-10-18
status: accepted
issue: 739
paths:
  - apps/troupe_core/lib/troupe/config/explain.ex
  - clients/gui/packages/client/src/connection.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/tui/lib/troupe/ui/setup.ex
  - clients/tui/lib/troupe/client/daemon.ex
symbols:
  - Troupe.Config.Explain.withhold/2
  - Troupe.UI.Setup
gist: "config.get for a viewer withholds base_url and state_dir; every client call has a stated wait; TUI first run trusts the daemon's record; test helpers put the log level back"
---

## A viewer is not shown what a session runs on

Decision 918 made `config.get` naming a session an `observe` method, so anyone who may
watch a pod session saw the profile's `base_url` (the model gateway's address, usually one
inside the cluster) and the pod's state directory. The maintainer decided (2026-10-18):
with only `observe`, the layers and rules are shown, and those two read "set by the
profile"; with `control` they are shown as they are.

- **Where.** The gateway answers `config.get` naming a session withholding when the
  connection's scopes lack `control` (`Explain.withhold/2`), on a pod and on a laptop alike;
  a laptop session's read "set by the session's owner". The answer, the explanation's text,
  its ladder for one key and its JSON are all built from the withheld layers, so no form of
  the answer carries the values.
- **What.** Every key whose last part is `base_url` (the session's provider and each named
  provider's) and `state_dir`. Where they came from stays: the layer and the source (the
  worker profile and its variable). A pod's workspace and its repository's files live under
  the state directory, so in a withheld answer their paths name it `<state directory>`.
- **Marked.** A withheld key carries `"withheld": true`; the desktop's Settings pane draws its
  value muted, with what it is shown to. The TUI's `/settings` lists neither key and draws
  what it is given; `troupe config --explain --session` prints the pod's text.
- Not chosen: refusing `config.get` to viewers (they lose the rules, which are what they
  most need to read), and withholding the models and prices too (the maintainer named two
  values, and the models are on every event a viewer already sees).

## No client call waits for its answer for good

Decision 916 gave the desktop's first run a stated wait; every other button that waited on
one reply could still hang on a lost one (D131).

- **Every call has a stated wait.** `TroupeConnection.call` rejects with
  `TroupeCallTimedOut` past `callTimeout(method)`: 60 seconds, and longer for the methods
  known to take longer (`session.create`, `session.fork` and `session.claim` 3 minutes,
  `session.erase` 5, the provider and server checks, a merge and an upload 2), all in one
  exported table, `callTimeouts`. A caller names another for one call (`{ timeoutMs }`), as
  the `DaemonClient` methods behind busy buttons take. The sentence says which call, how
  long, and that it may still have been done.
- **A late answer is not taken**: the call is forgotten when it gives up.
- **The buttons come back** because each busy control already ends its wait in a `finally`;
  what changed is that the wait now ends. The setup screens keep their own, shorter,
  patience (Decision 916).

## The terminal's first run goes by the daemon's record

`troupe setup`'s screen sent the summary as one `setup.answer` after another and waited on
each for good, ignoring every key meanwhile, Ctrl-C included; a reply the link gave up on
after 30 seconds put the screen back on the summary with the error, though the daemon had
finished the run. As Decision 916 did for the desktop:

- **An answer late past `patience_ms` (20 s)** has the daemon asked where the run stands,
  over a connection of its own (`status`, `Link.call_apart`), since the daemon answers one
  connection's calls in turn. Finished, the screen ends as a finish would have; not, the
  keys come back with "The daemon has not answered in 20 seconds", and the answer is still
  taken if it comes.
- **A summary step that failed** without the daemon refusing it is judged by the flow that
  comes back with the failure: a record newer than the one the screen began with, or a
  first run the daemon no longer wants, is a finish.
- **A finish whose answer never came** ends at the sign-in for a plane, and for this
  computer as `:finished`: the session it started is unknown here, and the CLI says
  `troupe resume` opens it.
- **Ctrl-C leaves at any moment.** With a summary being sent, it counts as having written.

## The medium defects fixed at their cause

- **A daemon session follows a restarted daemon (D46).** After a failure, a TUI window's or a
  headless run's connection to a daemon session asks where the daemon is now (`relocate`,
  `Link.websocket/0`, which reads `daemon.json`) before it dials again.
- **A draining pod takes no new session (D40).** `session.activate` on a draining pod is
  refused as `unavailable` (`draining`) unless the session is already awake there; the plane
  gives the slot back and places the session again.
- **A cut result names `read_output` only to an agent that has it (D66).** `explore`,
  `answer`, `ask` and the librarian are told what was cut and to narrow the request.
- **The pods log in at the installation's OpenBao mount (D55).** The chart gives the operator
  `bao.authPath`, which it names to pods where it is not `kubernetes`; an empty
  `TROUPE_BAO_TOKEN` is no static token.
