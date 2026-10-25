---
number: 951
title: "Local only is a promise the daemon keeps for that client's sessions, no plane call while it is on: a client says it in initialize's client_info.local_only and again with client.mode, a session is under it from when such a client creates it or gives it work until a client not in it does, and for it remember level me is refused, an offer is refused, its turns leave the memory report and it says once in instructions_loaded what it reads; while every client attached is in it the daemon's polls wait; the terminal's switch is local_only in the person's own config; and who wrote each line of a memory document is derived from its versions and audit rows, never stored"
date: 2026-10-25
status: accepted
issue: 55
paths:
  - apps/troupe_gateway/lib/troupe/gateway/local_only.ex
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/policy.ex
  - apps/troupe_gateway/lib/troupe/gateway/plane.ex
  - apps/troupe_gateway/lib/troupe/gateway/daemon.ex
  - apps/troupe_core/lib/troupe/local_only.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/doctor.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_worker/lib/troupe/worker/user_memory.ex
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/console/src/views/Memory.tsx
  - clients/tui/lib/troupe/cli/local_only.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/cli/doctor.ex
  - clients/tui/lib/troupe/cli/memory.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
  - PROTOCOL.md
  - docs/user/README.md
  - docs/user/configuration-settings.md
  - docs/user/memory.md
symbols:
  - Troupe.Gateway.LocalOnly
  - Troupe.LocalOnly
  - Troupe.CLI.LocalOnly
  - Troupe.Plane.Memory.blame/2
gist: "A Local-only client's sessions get no plane call from the daemon (remember me, offer, memory report); polls wait while all are; blame is derived, not stored"
---

#765, as the maintainer decided it on 2026-10-25: "Local only reaches the daemon." Decision
926 made the desktop app's own requests go through one gate that Local only shuts. The
daemon had no notion of it: a session the desktop app started while Local only was on could
still `remember` with `level: "me"` through the daemon's plane token (D136), the daemon kept
offering and polling, and the memory poll told the plane what that session's turns read.
The promise "nothing of what I do here reaches a plane" was the window's, not the
machine's. This records how the daemon keeps it, and, in the same slice, how #55's
provenance per line is answered.

## How a client says it

**At `initialize`, additive:** `client_info.local_only: true`. A client from before it sends
nothing and is in no Local only, so an older daemon or client is unchanged. **When the
switch moves:** `client.mode {local_only}`, answered by the connection itself, as
`auth.refresh` is, and taken from any seat: it only ever narrows what the daemon does for
the client that says it. A re-`initialize` was the other choice; a connection is initialised
once (a second is `invalid_request`), and a reconnect would cost the subscriptions, so the
small call was cheaper. The desktop app asks the setting at every dial (`localOnly` on
`DaemonClient`) and sends `client.mode` from the switch; the terminal reads `local_only` from
the person's own config as the command starts.

## Which sessions are the client's

**A session is under Local only from when a Local-only client creates it or gives it work
(`input.send`, `commands.run`, `session.goal.set`, `session.loop.start`) until a client not in
Local only gives it work, or the client that put it there turns Local only off.** The last
client to give a session work is whose promise its next turn keeps. The mark is set before
the work, so a turn the input starts is already under it, and after a create, whose id there
was none of before. Turning Local only on puts the sessions the connection has open
(subscribed) under it, which is what a person switching it on looking at a session expects.

**It stays when the client disconnects.** A goal loop running after the window closed is
still the work of somebody who asked for nothing to leave the machine; a promise that lapsed
with the window would be one the desktop app's restart could break. The marks are held in
memory (`Troupe.Gateway.LocalOnly`): a restarted daemon has none, and the next client to give
a session work says again what it is.

Not chosen: a mark only while the client is attached (the loop case above); a session's
config key (a session's config does not change after it starts, and the switch must reach
running ones); marking on subscribe alone (watching a terminal's session from the desktop app
would take the terminal's person's `remember` away from them).

## What the daemon does not do for such a session

- **`remember` with `level: "me"`** is refused by the host the daemon installs
  (`Troupe.Gateway.Memory.append/2`), with a sentence naming Local only and offering the
  repository's memory. Nothing is sent.
- **An offer** (`remote.offer`) is `forbidden` for a session under it, and for a client in
  it. A client in Local only gives an offered session no work either: an offered session's
  events go to the plane for whoever steers it, so the person withdraws the offer first.
- **The memory report.** Its turns are left out of the `sessions` every `me.memory` ask
  carries (Decision 947). It reads the copy the machine already holds, given to every
  session as before; nothing is fetched for it. Its first `instructions_loaded` under Local
  only carries `local_only`, a sentence saying so, written once (and again only after it left
  and came back), through the harness's `Troupe.LocalOnly` hook, since which client said what
  is the daemon's to know.
- **The client's own memory calls.** `me.memory` and `me.memory.put` are refused to a client
  in Local only, and a private `session.create` (a private session is sealed to the plane);
  `me.memory.status` answers what the copy holds and says the plane was not asked.

**While every client attached is in Local only** the daemon's own polls wait: the memory
poll and the version policy's `initialize` every thirty seconds. With nobody attached they
run as they always did: an idle daemon is nobody's Local only. A link that brings a token
still asks at once; a Local-only client does not link.

**Untouched:** the daemon's own sign-in for sessions other clients offered (Decision 928),
which is theirs; a private session's sealing, which is that session's storage, for one made
elsewhere and later given work by a Local-only client (left, below).

## The terminal

`local_only: true` in the person's own `config.yaml`, scope `user`, so a repository's file can
neither set it nor, more to the point, set it false over theirs. A key rather than a
`--local-only` flag: the promise is a setting a person makes once, as the desktop app's is
remembered, and `troupe doctor` can say whether it is on only for a setting. On, every
connection `troupe` makes to the daemon says `client_info.local_only`, `troupe login`,
`whoami`, `config pull`, `--remote` and `--private` are refused with a sentence before they
call a plane, the update asks no plane for its policy, and `troupe doctor` prints a `local
only` line and asks no plane for its discovery document.

## Who wrote each line (#55's provenance)

`Troupe.Plane.Memory.blame/2` walks a document's versions in order, each version's lines
against the attributed lines before it by the plane's own line diff: a line that stays keeps
who wrote it, a line that comes is that version's, `by` who saved it. An agent's entry adds
the `session` and `agent` it came from, read off the version's `memory.put` audit row, which
now records the agent beside the session (the daemon's `me.memory.put {append}` names both;
the pod's `session.memory.put` names the agent, the plane the session). A rollback's lines
keep who wrote them in the version rolled back to. **No new storage:** the versions and the
audit hold everything, and a diff-walk of at most a document's versions of 8192 bytes is
cheap. Blame, not history: the versions list is the history. Answered by `admin.memory.get`
for the version shown (`lines`), by `me.memory` with `blame: true` for the person's own (the
poll does not ask it), printed by `troupe memory --blame`, and in the console under *Who wrote
each line*, a column beside each line.

## Also in this slice

The offline bench's tool-definition budget moves from 14800 to 16300 bytes, about a tenth
over the 14787 measured, as `docs/developer/bench.md` sets a budget; at 14800 any change to
one tool's description failed the bench. `budgets.json` says why in a top-level `$comment`,
which the bench does not read as a scenario.

## Left

A private session made elsewhere and later given work by a Local-only client goes on being
sealed. The desktop app's switch and the terminal's `local_only` are two settings, not one
shared one. Of #55: a change to a profile's `extends` reaching its sessions at their next
turn; soft delete of a document's lines; teams writing their own memory, or agents proposing
changes to it.

## Proof

- `apps/troupe_gateway/test/troupe/gateway/local_only_test.exs`: two clients on one daemon,
  one in Local only; that client's session refuses `remember` with `level: "me"` naming Local
  only and the repository, the other's writes with its session and agent, nothing of the
  first reaches the plane, and its `instructions_loaded` says so once; the poll's report
  leaving it out, an offer of it `forbidden`, the client's `me.memory` refused and
  `me.memory.status` saying the plane was not asked; the polls asking nothing while every
  client attached is in Local only and again after `client.mode` off; `client.mode` putting
  open sessions under it and taking them out; a session staying under it after its client
  went and leaving it when another gives it work; a private session refused.
- `apps/troupe_plane/test/troupe/plane/memory_blame_test.exs`: each line of the
  organisation's naming its version and who saved it, a version shown as it stood, a
  rollback's lines keeping their writer; `me.memory` with `blame` naming an agent's entry's
  session and agent, and no `lines` without it. `control_test.exs`: a pod's entry audited
  with its agent and blamed to its session.
- `clients/tui/test/troupe/local_only_cli_test.exs`, `memory_cli_test.exs`: the key telling
  the daemon, the plane commands refused, the doctor's line; `--blame` printed.
- `clients/gui/apps/desktop/test/local-mode.test.tsx`: every `initialize` in Local only
  carrying `local_only`, and the switch sending `client.mode` on and off.
  `apps/console/test/memory.test.tsx`: *Who wrote each line* beside each line.

The gateway test's first case failed on the chunk's tip (`bfb8eacc`): the Local-only client's
session answered "remembered in the person's own memory on the plane, version 1". The plane,
TUI and console tests failed there for want of `blame/2`, `--blame`, `local_only` and the
column.
