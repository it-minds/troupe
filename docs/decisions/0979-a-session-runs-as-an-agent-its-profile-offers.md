---
number: 979
title: A session runs as an agent its profile offers - the plane resolves the default (build where offered, else the first offered) at create time and keeps it on the row, refuses a create naming an agent the profile lacks or on a profile that offers none, sends the row's agent on every activation including a wake, and parks a session whose pod will not run it as its agent instead of trying again; the clients send the default they show
date: 2026-11-13
status: accepted
issue: 882
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/test/troupe/plane/session_agent_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/test/troupe/worker/unrestorable_test.exs
  - clients/gui/packages/client/src/newSession.ts
  - clients/gui/packages/client/test/new-session.test.ts
  - clients/gui/packages/client/test/support/plane.ts
  - clients/gui/apps/desktop/src/views/StartSession.tsx
  - clients/gui/apps/desktop/test/new-session.test.tsx
  - clients/tui/lib/troupe/ui/new_session.ex
  - clients/tui/lib/troupe/ui/tui/new_session_page.ex
  - clients/tui/test/troupe/new_session_screen_test.exs
  - PROTOCOL.md
gist: "No agent is ever left to the pod's own default: create resolves build-if-offered-else-first onto the row, every activation sends it, agent_not_here parks the session; a profile with no pod is idle, not full"
---

A profile whose `spec.agents.allow` named only its bundle's own agent could not start a
session from the start screen, nor wake one (#882). The plane's offering was right:
`profiles.list`'s `agents` is the bundle's primaries and the built-ins, the profile's rule
applied, then the grant (Decision 968), which is what the pod judges by. What went wrong
is that nobody sent that agent. The start screens showed the profile's first agent and
sent none unless one was named; the plane stored none and pushed none; and a pod given
none runs its own `default_agent`, `build`, which the rule had taken away. The pod refused
the activation, the plane put the waiting session back in the queue, and the scaler tried
it again every fifteen seconds for good. A wake (`restore_on_pod`) never sent an agent at
all, whatever the row held, so a session started with `#agent` was woken as `build`,
refused, and left dormant with its epoch a step higher at every message.

## Decision

**The plane resolves the agent at create time.** A create naming none gets the profile's
default, `build` where the offering has it, as it always had, and else the offering's
first, the bundle's own first primary. It is kept on the row like a named one, so the row
holds what the session runs as from the start. A profile that offers no primary at all is
refused at create time with `invalid_params`, `field: "agent"`, as a create naming an
agent the profile lacks already was; that refusal now carries `field` and `agent` beside
the `agents` there are.

**Every activation sends the row's agent.** The first one, a waiting session's admission
and a wake alike. A row from before this, with no agent, is sent the profile's default by
the same rule, never left to the pod. The root replays a `profile_switched` from its log
over it, and the row follows a switch from the pod's status reports, so the two agree.

**A pod that will not run the session as its agent is final, not a blip.** The worker
answers `{:not_on_profile, name}` and `{:unknown_agent, name}` as `invalid_params` with
`reason: "agent_not_here"` and the agent. The plane parks such a session read-only as it
parks one whose workspace is gone (Decision 661), with `failed_reason: "agent_not_here"` on
the row: a create answers `invalid_params` and keeps no row, a waiting session is parked
rather than queued again, and a wake answers `forbidden` naming the agent, after which the
next open is refused before any pod is asked and the epoch stays put. `token.mint` for a
session that waited and was parked before it ever ran answers the same `forbidden`, so the
casting screen that polls it says why instead of waiting for ever.

**The clients send the default they show.** Desktop and terminal pick `build` where the
profile offers it, else its first agent (`defaultProfileAgent`, `NewSession.default_agent/1`),
and send it; where `profiles.list` offers none they send none, show "its default", and the
plane says why it cannot start one.

**A profile scaled to zero is idle, not full.** With no pod and nothing running a profile
has capacity 0, which the screens read as a full house ("dev has 0 of 0 running"), and the
auto-pick passed it over. `profileRoom` / `NewSession.room/1` now say `idle` there, not
`full`; the auto-pick counts it as having room, since a create starts a pod for it, and the
profile picker tags it IDLE.

Not done here: the console listing a pod retired weeks ago as draining. A scale-down
leaves the pod's row (draining, retiring, then not retiring) on purpose, and which of the
row's lifecycle or the console's reading of it should change is a question of its own
(#883).

## Proof

`apps/troupe_plane/test/troupe/plane/session_agent_test.exs` (create with no agent runs as
the profile's own or `build`; refusals naming the agent; a profile offering none; a wake
sends the row's agent, or the default for a row with none; a refusal parks a wake, a
waiting session and a create, and `token.mint` says why), the worker's
`unrestorable_test.exs`, the shared rules in `packages/client/test/new-session.test.ts`,
the desktop screen in `apps/desktop/test/new-session.test.tsx` against a fake plane whose
profiles offer other agents, and the terminal's `new_session_screen_test.exs`. Each failed
before the change.
