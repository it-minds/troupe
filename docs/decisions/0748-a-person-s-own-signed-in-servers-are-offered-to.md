---
number: 748
title: A person's own signed-in servers are offered to a pod session they open in the desktop app, as tools the app hosts, and the daemon makes every call with their sign-in
date: 2026-10-01
status: accepted
issue: 308
paths:
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_core/lib/troupe/session/mcp.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - clients/gui/packages/client/src/offer.ts
  - clients/gui/apps/desktop/src/views/Offer.tsx
gist: A person's own signed-in servers are offered to a pod session they open in the desktop app, as tools the app hosts, and the daemon makes every call…
---

- **The daemon lists and calls a server outside any session.** `mcp.tools {name}` answers
  the server's tools with their descriptions and schemas, asked as a local session asks
  (`Troupe.Session.MCP.discover/1`), with `state` and `error` as `mcp.check` reports them.
  `mcp.call {name, tool, arguments}` makes the call through `Troupe.MCP.Tool.invoke/4`,
  the path a local session's tool takes, so a refresh and one more try on a `401`, and the
  `sign_in_required` note once the sign-in has run out, are the same, and `content` is
  what a local session's model would read. A server with a `url` only: one that runs a
  command is a process a local session keeps, and starting one per call for somebody
  else's session is a question of its own. A refused, disabled or unapproved workspace
  server is refused, as for a sign-in. `mcp.call` carries a `command_id`, which the app
  makes from the session and the pod's `call_id`, so a call the pod sends again after a
  drop is answered from the ledger rather than made twice.
- **The desktop app offers them** (`ServerOffer` in `@troupe/client`). On a team
  session opened on its own screen, with a daemon to make the calls and a token with
  `control`, it lists the person's servers whose sign-in stands `signed_in`, asks the
  daemon for each one's tools, and registers them with `tools.register`. The session's
  challenge is shown in a panel where the approval and question panels sit, in the
  session's words and naming the servers, and **Offer them** sends it back with the
  person's subject as `confirmed_by`. Every signed-in server rather than a choice
  among them: the prompt names every tool, the person can say no to the lot, and a
  choice per server is a refinement the first slice does without. Names are
  `<server>.<tool>`, so the pod sees `client.<server>.<tool>`, under the prefix no
  built-in and no profile's `mcp.<server>.<tool>` carries, and two servers' tools
  never meet. Their permission is the default `ask`: the consent is to offering the
  tools, not to every call, and the entry's own `permission: auto` is about the
  person's own sessions.
- **A `tool.invoke` goes to `mcp.call`**, and only `{content}` goes back to the pod. An
  error from the daemon goes back as an error.
- **Again on every socket.** `SessionAttachment` takes `onToolInvoke`, and says `tools` at
  `initialize` when given one, and `onLive`, called on each socket it opens. A
  registration goes with its socket, so each new one is offered the tools again; the
  session issues a fresh challenge per socket, and the app answers it with the consent the
  person gave for the same tools in this attachment rather than asking again, since a
  parked call has the call grace, a minute, and asking again for what was just allowed
  teaches people to say yes without reading. A different set of tools is asked about
  again, and **Not now** holds for the attachment.
- **No token reaches the pod or the plane.** The pod is sent the tools' names,
  descriptions and schemas, the consent, and each answer's text. The daemon uses the
  token on its call to the server, and no answer of `mcp.tools` or `mcp.call` has it.
