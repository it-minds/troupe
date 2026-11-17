---
number: 920
title: agents.list is the one list every agent picker reads, for a workspace or a session (a pod session's its bundle's), each row saying where it comes from in four words, what it stands in for and whether it may be changed; the desktop picker starts, switches and opens a file; and the plane checks a draft's agents with the daemon's rules, which the console's agent builder asks one at a time
date: 2026-10-18
status: accepted
issue: 594
paths:
  - apps/troupe_protocol/lib/troupe/protocol/agent_check.ex
  - apps/troupe_core/lib/troupe/agent/validate.ex
  - apps/troupe_core/lib/troupe/agent/local.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_gateway/lib/troupe/gateway/agents.ex
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
symbols:
  - Troupe.Protocol.AgentCheck.check/2
  - Troupe.Agent.Local.origin/1
  - Troupe.Agent.Definitions.pin/1
  - Troupe.Plane.Bundles.check/1
  - Troupe.Plane.Admin.agent_check/3
gist: "agents.list by workspace or session (pod: its token may, naming no path); rows say origin (4 words), overrides, editable; plane holds drafts to AgentCheck"
---

- **One list, for a workspace or a session.** `agents.list` takes `workspace` or
  `session_id`. Named by a session, the rows are the session's own definitions read again
  from their files (`Definitions.reload/1`, as `profile.switch` reads them), so on a pod
  they are the bundle's, the built-ins and the working copy's in Decision 826's order, and
  on this computer what a switch would switch to. Each row gains `origin`, the four words
  of the issue (`Shipped`, `Your organisation's`, `Yours`, `This repository's`,
  `Troupe.Agent.Local.origin/1`), `profile` (the plane's profile a bundle's agent came
  with: the pin now carries the `profile` the plane activates the session for, and a
  composed channel `profile:<name>` names it otherwise), `path`, `editable` with
  `editable_reason` (`agents.get`'s), and `overrides`, the lower layers' files of its name
  (`agents.get`'s `also`, which stays). "Yours" and "This repository's" stay two words, as
  the issue asks: Decision 825's trust is the difference. All additive; a client reading an
  older daemon falls back on `layer`.
- **A pod session's token may read its own agents.** The worker's guard admits
  `agents.list`, `agents.get` and `agents.validate` from a session-confined token when the
  request names the token's session and no `workspace`; with a `workspace` they are about a
  path on the pod and stay refused, as before. Not chosen: a new method (`session.agents`),
  which would be the same answer under a second name.
- **One validator, three writers.** The daemon's rules move from `Troupe.Agent.Validate`
  into `Troupe.Protocol.AgentCheck`, which the plane can call (it never depends on core);
  `Validate.check/2` is that check given the harness's own knowledge (its tools, an MCP
  server's, the provider's model list), so its words are unchanged. Without the harness the
  check knows the harness's built-in tools by name, a list core's test holds to
  `Troupe.Tools.builtins/0`, and says a model is not checked. The plane holds a **draft** to
  it (`Bundles.check/1`: `admin.bundle.validate`, `.preview` and `.publish`), one sentence
  per error, `agent <name>: <the daemon's message>`; a published version read again (a
  composition, a baseline) is checked by the document's rules alone, so one an older plane
  published still runs. `admin.agent.check {name, definition}` answers `{ok, errors,
  warnings}` for one agent, a platform admin's like publishing. Not chosen: putting the
  rules into `Troupe.Protocol.Bundle.validate/2`, which the worker re-runs on every bundle
  it fetches and would have refused a published bundle on the pods.
- **The desktop app's picker** (`AgentPicker`) is the same rows and three actions on the
  start screen and in a session's head: rows grouped by origin, each with its model,
  read-only and tool count, greyed with the reason when it cannot run; the chosen one's
  description, origin, profile and what it stands in for. **Start** makes a session on it
  (the start screen's own, with its fields; from a head, beside the session: in its
  workspace here, on its plane profile on the platform); **Switch** is `profile.switch`
  (refused on the start screen, where there is no session yet, and for the agent running
  now); **Edit** opens a person's or a repository's agent file in the editor their system
  opens Markdown with and is refused, with `editable_reason`, for a built-in and a bundle's
  agent. The head reads the session's own listing (`SessionView.agents`), falling back for
  an older daemon or pod on what it answered before. The team start screen has no session
  to ask yet: its rows are the profile's offering, each the organisation's, from that
  profile, edited in the console.
- **Opening a file is a command of the shell's, not a widened capability.**
  `agent_file_open` takes a path and opens it only when it really is a `.md` in an `agents`
  directory under `.troupe` or `troupe` (links followed), through the opener plugin's Rust
  API; the page is granted no `opener:allow-open-path`, which would open any file. The
  daemon reads what the person saves the next time it reads the agents, and checks it then,
  as it checks any edit made by hand.
- **The console's agent builder.** In the bundle editor the agents are a list with a form
  each (name, mode, description, model, tools, instruction), over the definition text the
  daemon reads: the fields are written into it with the client's `withFields`/`withBody`, so
  a key the form does not edit (`permissions`, `skills`, `override`) is kept as written, and
  the file it makes is shown. Each is checked with `admin.agent.check` before it is kept, its
  errors at their fields in the daemon's words. The rest of the document (skills, MCP
  servers) stays JSON, and a document that still carries `agents` there is refused, naming
  the builder. Publishing is the existing path: validate, preview with who loses what,
  confirm, audit.
