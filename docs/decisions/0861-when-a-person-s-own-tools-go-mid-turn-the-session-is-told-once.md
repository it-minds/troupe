---
number: 861
title: When a person's own tools go mid-turn, a call in flight waits the grace for them to come back and is otherwise told once that they went and that it may have run; later calls find no such tool
date: 2026-10-11
status: accepted
issue: 308
paths:
  - PROTOCOL.md
  - apps/troupe_gateway/lib/troupe/gateway/client_tool.ex
  - apps/troupe_core/lib/troupe/session/client_tools.ex
  - apps/troupe_gateway/test/troupe/gateway/client_tools_test.exs
  - clients/tui/lib/troupe/remote/offer.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/test/troupe/remote_client_tools_test.exs
symbols:
  - Troupe.Gateway.ClientTool.run/4
  - Troupe.Session.ClientTools.await/4
gist: "A person's tools that go mid-turn: the call waits the grace, else fails once saying it may have run; a leave is a drop; nothing of theirs stays on the pod"
---

Issue #308, under the identity model decided in #331: a person's own MCP servers run on
the person's machine and a pod session calls them over the client-tool path
(PROTOCOL.md section 8, root Decision 748 for the desktop app, TUI Decision 135 for the
TUI). The session holds no grant and no credential, so when the person's client goes,
the tools go with it. #331 left one thing to record: what the session sees when that
happens in the middle of a turn. Most of it the client-tool path already did; this
writes it down as the contract and changes one sentence of what the model is told.

- **A call in flight waits, then fails once.** The connection that offered the tool
  closes (the window shut, the TUI or app quit, the laptop asleep, the network gone):
  the call it was serving is parked for the grace (`TROUPE_CLIENT_TOOL_GRACE_SECONDS`,
  60 s), taken out of the call's own timeout, so a drop is never a hung turn. A client
  of the person's that offers the same tool again inside it is sent the same
  `tool.invoke` with the same `call_id`; the TUI and the desktop app answer the fresh
  challenge with the consent already given in this attachment, and both make the
  daemon's `mcp.call` under a `command_id` built from the session and that `call_id`,
  so a call the daemon already made is answered from its ledger rather than made
  twice. Nobody back inside the grace, and the agent gets one error result naming the
  tool and saying its client left, and the turn goes on.
- **The model is told the call may have run.** The call is made on the person's
  machine, and the daemon may well have made it before the answer was lost with the
  socket. A tool of somebody's own servers can write (a ticket, a note, a message), so
  "do the work another way" alone invites doing it twice. The error now says the call
  may have run on their machine and to check before doing it again. This is the one
  change this decision makes (`Troupe.Gateway.ClientTool`).
- **The tool is off the list before the next lookup.** The registration goes with its
  connection: `tools_unregistered` with reason `disconnected` is logged before the
  agent's next lookup, so the next model request does not offer it. A model that names
  it anyway (a request already streaming when it went) gets the ordinary "There is no
  tool named client.<server>.<tool>." A parked call is the only thing that waits.
- **A leave is a drop.** Neither client sends `tools.unregister` when the person closes
  the session's window; the socket closing is what takes the tools away. One path, so
  a restart and a deliberate leave look the same to the session, and a client that
  quits has nothing it must remember to send. The cost is that a call in flight when
  the person leaves on purpose waits the grace before it fails, which the grace
  already bounds.
- **Nothing of the person's stays.** No grant, no token and no consent outlives the
  connection: coming back is a fresh `tools.register` through a fresh challenge. The
  taint (`session_tainted`) does stay, as it always has: the others in the session
  were entitled to know a tool ran on somebody's machine, and that remains true after
  it is gone.
- **Out of this decision.** Whether a team may forbid offering personal tools to its
  pods (#331's other open question): today only the platform's
  `managed_mcp_servers_only` refuses them, for every team. Showing the people in the
  session a line when somebody's tools go: the log has `tools_unregistered`, and
  neither client draws it yet.
- **Proof:** `Troupe.Gateway.ClientToolsTest` ("a registrant that goes away mid-call":
  the error after the grace naming the tool, saying its client left and that the call
  may have run, the turn carrying on, the tools unregistered as `disconnected`; and the
  same call sent to a client that comes back inside the grace), and the TUI's
  `remote_client_tools_test.exs` (offered again on a new socket without asking, and
  gone from the session once the window is closed).
