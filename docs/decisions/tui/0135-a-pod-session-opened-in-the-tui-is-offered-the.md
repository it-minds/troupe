---
number: 135
title: A pod session opened in the TUI is offered the person's own signed-in MCP servers, as the desktop app does, and the session's question is an approval in its window
date: 2026-10-02
status: accepted
issue: 308
paths:
  - clients/tui/lib/troupe/remote/offer.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/remote/rpc.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/test/support/fake_remote.ex
  - clients/tui/test/troupe/remote_client_tools_test.exs
symbols:
  - Troupe.Remote.Offer
  - Troupe.Remote.Worker.asking/1
gist: "A pod session's own window offers the person's signed-in servers once per attachment, asks as an approval, re-registers on each socket without asking again"
---

Issue #308, the TUI's part of root Decision 748. What was there: the worker connection
answered every server-to-client request `method_not_found`, so a pod session reached
from HQ had none of the servers the person signed in to on this machine.
- **What is offered, and when.** As in the desktop app: every server whose sign-in
  stands `signed_in` (and is not off or refused), its tools named `<server>.<tool>`,
  on every socket that reaches a plane session active and with `control`
  (`Troupe.Remote.Offer`, from `Troupe.Remote.Worker`). A dormant session or a reader
  is offered nothing, since registering activates the session; nor is a branch shown
  inside another session's screen, which would ask the person a second time. The
  daemon is asked from a task (`mcp.list`, `mcp.tools`, `mcp.call` over
  `Troupe.Client.Daemon.Link`), never from the worker's own process, and what it says
  is tagged with the socket it was for. `initialize` says `tools` for a plane session.
- **The question.** The TUI has no panel of its own for it, and an approval already is
  what waits for a person in a window with `y` and `n`. So the session's challenge is
  drawn as a transient `approval_requested` in the session's window, in its words and
  naming the tools; `y` (or `a`) registers them with the person's subject as
  `confirmed_by`, `n` turns them down for the attachment. The answer goes to the
  worker, which owns the call id, not to the pod. It is never written to the journal,
  where it would outlive the worker that can answer it; a window rebuilt while it
  waits reads it from the worker (`Worker.asking/1`, added to `events/1`). A line in
  the transcript says what was offered, once per attachment.
- **Again on every socket.** A new socket lists the tools again; the session's fresh
  challenge is answered with the consent given for the same tools in this attachment,
  twice more if one runs out on the way, and a different set is asked about again.
  A `tool.invoke` is answered `{content}` from `mcp.call`, whose `command_id` names
  the session and the pod's call id; an answer whose socket has gone is dropped, since
  the pod sends the call again to the next registration. A failure goes back as an
  error whose message is the daemon's words, which is what the pod's model reads.
- **Leaving takes them away.** Closing the session's window stops its worker and closes
  the socket, and the registration goes with it (PROTOCOL.md section 8); the TUI sends
  no `tools.unregister` of its own, so a deliberate leave and a drop are the same thing
  to the session (root Decision 861).
- **Proof:** `remote_client_tools_test.exs`, against the suite's `FakeRemote` (which
  now issues challenges, keeps registrations per connection and sends `tool.invoke`)
  and the core suite's fake OAuth and MCP server through the daemon this VM embeds:
  an offer allowed, called and offered again after a drop without asking; the tools
  gone once the window is closed; a refusal that holds across a drop; and the question
  in a rebuilt window. All fail on the chunk's tip.
