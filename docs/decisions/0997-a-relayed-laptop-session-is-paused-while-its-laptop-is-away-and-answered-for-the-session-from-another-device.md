---
number: 997
title: A relayed laptop session is paused while its laptop is away, and said so on its stream; its approvals say the folder the call acts in; and somebody the owner let steer may allow a tool for the rest of the session from another device
date: 2026-11-15
status: accepted
issue: 932
paths:
  - apps/troupe_protocol/lib/troupe/protocol/relay.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_plane/lib/troupe/plane/remote.ex
  - apps/troupe_plane/lib/troupe/plane/remote/laptop.ex
  - apps/troupe_plane/lib/troupe/plane/remote/viewer.ex
  - apps/troupe_plane/lib/troupe/plane/remote/offer.ex
  - apps/troupe_plane/priv/repo/migrations/20261115000997_remote_sessions_paused.exs
  - apps/troupe_gateway/lib/troupe/gateway/remote.ex
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/src/session.ts
  - clients/gui/packages/client/test/support/plane.ts
  - clients/gui/packages/client/test/support/worker.ts
  - clients/gui/apps/console/src/views/Remote.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/views/Approval.tsx
  - clients/tui/lib/troupe/remote/worker.ex
  - PROTOCOL.md
symbols:
  - Troupe.Protocol.Relay.paused_reasons/0
  - Troupe.Protocol.Relay.paused_refusal/0
  - RELAYED_ALLOW_SESSION
  - LaptopPresence
gist: "Laptop gone (daemon said stopped, socket closed, or 3 missed pings): views kept, offer_paused {reason}, sends refused unavailable, remote.list paused; back: offer_resumed then relay.closed for the client to reattach. approval_requested carries cwd. allow_session honoured over the relay (amends 945), gated on capabilities.relayed_allow_session"
---

#932: what #904 (for #899) left on the plane and the daemon for a laptop's session steered
from another device. This amends Decision 945 on one point, the answers a relayed approval
offers, and Decision 921's sentence that a remote person cannot loosen the laptop's rules
in the same way; the rest of both stands.

## A laptop that is away is paused, not lost

Before, the steerer heard of a laptop gone only from their own connection: the plane
closed the view with `relay.closed` when the laptop's socket ended, the console's attachment
tried six times in about twenty seconds, and then said *Lost the laptop*. A laptop that went
to sleep kept its socket open as far as the plane could tell (the socket's timeout is a day),
so the view looked hung until something timed out.

- **The plane keeps a heartbeat.** It pings the laptop's connection every fifteen seconds
  (`relay_heartbeat_ms`) and closes one that has answered nothing for three, as `offline`.
  The daemon's client answers pings already, so no daemon change was needed for it.
- **The daemon says why it goes, where it can.** Stopping, it sends `relay.pause {reason:
  "stopped"}` and hangs up without closing the views at the plane. Sleep it cannot see
  coming, and a lost link cannot carry a word, so both are `offline`.
- **The view waits.** When the laptop's connection ends, each view stays open and is sent
  the ephemeral event `offer_paused {reason, since}` on the session's topic. A request
  meanwhile is `unavailable` with `paused` and a sentence (*The laptop is away: nothing sent
  now reaches it. Send it again once the laptop is back.*); nothing is held for the laptop,
  as before. The offer's row keeps the reason (`paused_reason`, a migration), and
  `remote.list` says it as `paused` beside `state: "offline"`; `state` keeps its two values
  so no client that compares it breaks.
- **Back, the view ends to be opened again.** The session's connection on the laptop went
  with the laptop, so the plane cannot carry on the old view; when the laptop holds the
  session again the view is sent `offer_resumed` and closed with `relay.closed {reason: "the
  laptop is back"}`, and the client's attachment opens it again and subscribes from its own
  cursor, which loses nothing. An offer withdrawn while away (the laptop came back offering
  less) ends the view with `withdrawn`.
- **The console says it.** The status line reads *The laptop is asleep or offline; waiting
  for it*, or *Troupe stopped on the laptop; waiting for it to start again*, from the event,
  then *The laptop is back*, which stays beside the usual words until the session next says
  anything. *Asleep or offline* rather than *asleep*, because the plane cannot tell the two
  apart. The attachment's own words stay for the page's own connection. The list says
  *Troupe stopped there since …* for a `stopped` laptop.

**Not chosen: replaying the view on the plane.** The plane could remember a view's
`initialize` and subscriptions and replay them to the laptop when it is back, keeping the
socket. It would mean the plane reading every frame the laptop sends to know the cursor,
which it never does (it keeps nothing of what a session says), and answering a client's
replayed requests twice. Ending the view at the moment it can be opened again uses the
client's reconnection, which already resumes from its cursor without a gap.

## The folder the call acts in

A relayed approval's arguments named a folder only where the model passed `cwd`, and the
console fell back to the offer's workspace label, the folder's last name. Now the request
itself carries `cwd` (`Troupe.Tools`): the call's own `cwd` against the workspace, else the
workspace's root, on every connection, local, pod and relay alike, so `approval_requested`
says it in the log and the schema (`cwd`, optional). The console and the desktop app show it
where the arguments name none; the label stays the last fallback, for a daemon from before.

## Allowing a tool for the rest of the session from another device

Decision 945 had the relay refuse `allow_session`: the laptop's rules are its person's to
loosen. Widened here, because the owner's consent already covers it: they let this person
steer (the offer's `control`; for a private session, Decision 952's yes and an invitation
with `control`), and steering is sending prompts that run tools under the laptop's rules.
`allow_session` ends with the session, so nothing of the laptop's configuration changes and
nothing is left behind; a call one of the laptop's own rules asks about (`ask`, or a tool
that always asks) is asked again whatever was allowed, as at the laptop. `allow_always`,
which writes a rule into the laptop's configuration, stays the laptop's person's.

- `Troupe.Protocol.Relay` lets `allow_session` through at both ends.
- The daemon says `capabilities.relayed_allow_session: true` on a relayed connection, and a
  client offers the session-wide answer only where it is named: a daemon from before refuses
  it, and the clients answer once there, with the sentence saying why, as before.
- The console offers it in the desktop app's words (`callScopedLabel`, and *Allow, and let
  it publish unasked for this session* for a publication that names whom it is for); the
  desktop app draws its own scoped button again for such a laptop; the terminal answers a
  laptop's approval once only where the laptop names `relayed` without
  `relayed_allow_session`.

## Proof

- `apps/troupe_plane/test/troupe/plane/remote_test.exs`: a laptop gone without a word pauses
  the view as `offline`, lists `paused`, and back sends `offer_resumed` and `relay.closed`
  *the laptop is back*; a daemon that says it is stopping pauses as `stopped`, a prompt
  meanwhile is refused with the sentence, and a laptop back offering nothing ends the view
  `withdrawn`; a laptop that stops answering pings is paused `offline`.
- `apps/troupe_gateway/test/troupe/gateway/remote_test.exs`: a relayed connection's
  `initialize` names `relayed_allow_session`, its `approval_requested` carries the
  workspace as `cwd`, and `allow_session` from a control share is honoured (the second call
  of the tool runs unasked); a daemon that stops sends `relay.pause` and closes no view at
  the plane.
- `apps/troupe_protocol/test/troupe/protocol/relay_test.exs`: the three answers pass at
  `control`, none at `observe`.
- `clients/gui/apps/console/test/remote.test.tsx`: the folder and the session-wide answer,
  a daemon from before answered once with the sentence, the status words, and a laptop
  paused and back walked against the fake relay.
- `clients/gui/apps/desktop/test/remote-sessions.test.tsx` and
  `clients/tui/test/troupe/relayed_answers_test.exs`: the session-wide answer where the
  laptop names it, once where it does not.
