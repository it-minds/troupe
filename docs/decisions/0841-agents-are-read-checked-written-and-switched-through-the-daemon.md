---
number: 841
title: An agent is read whole, checked as it is saved and written into the user or project scope through the daemon's agents.* methods and onboarding's confined writer, and a session's or branch's agent changes with profile.switch, read from its file at the switch, keeping the conversation
date: 2026-10-10
status: accepted
issue: 503
paths:
  - apps/troupe_core/lib/troupe/agent/validate.ex
  - apps/troupe_core/lib/troupe/agent/local.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_gateway/lib/troupe/gateway/agents.ex
symbols:
  - Troupe.Agent.Validate.check/2
  - Troupe.Agent.Local.put/5
  - Troupe.Agent.Local.delete/4
  - Troupe.Agent.Definitions.reload/1
  - Troupe.Agent.Server.switch_profile/3
  - Troupe.Onboard.put_file/5
  - Troupe.Onboard.remove_file/4
gist: Agents written only via agents.put (checked, user|project, onboarding's writer); built-ins/bundle read-only; profile.switch rereads the file, keeps the conversation
---

- **Four methods, daemon-written, like `mcp.*`** (Decision 700, #60's layer pattern).
  `agents.validate` answers `{ok, errors, warnings}` and writes nothing. `agents.put
  {name, scope, source}` writes `<config>/agents/<name>.md` (`user`) or
  `.troupe/agents/<name>.md` (`project`; `workspace` taken as the same, `mcp.*`'s word).
  Reading and checking answer on a worker too; writing does not: on a pod the agents are
  the bundle's, and both writes are `forbidden` with a sentence pointing at the console
  (#56), not `method_not_found`, so a client says why. `get` and `validate` are `observe`;
  `put` and `delete` are `admin`, as `mcp.add` is: a definition decides what runs.
- **One writer, onboarding's.** `Troupe.Onboard.put_file/5` and `remove_file/4` are the
  writer Decision 823 made, opened to a file that came from nobody else's: the same
  whitelist of paths (`agents/<name>.md`), the same judgement by real path (a project file
  under the workspace's real `.troupe/`, so a `.troupe`, `.troupe/agents` or file that is
  a link out is refused: Decision 829's edge for the reader, held by the writer), the same
  temporary file renamed over it in the same VM-wide transaction, and no provenance. Not
  chosen: a writer of its own in the gateway (a second edge to keep), and `write_file` (a
  free path).
- **Checked on save, loudly; loaded leniently.** The loader stays lenient, as it must (one
  broken file should not stop a session), but a file it cannot read or parse is now in
  `skipped` with the reason in words (`not read: mode must be primary or subagent, not
  "main"`), so it reaches `agents.list` and the session's `files_skipped`, which clients
  already show, as well as the log.
- **What is not a person's to change here.** A built-in is changed by a copy: a `put` of
  its text into either scope, under its name (which then hides it) or another; deleting a
  built-in is refused, and deleting the copy brings it back (`agents.delete` answers the
  layer that answers now). A bundle's agent is the profile's (`editable_reason`: change it
  in the console).
- **A branch's agent changes; extended `profile.switch`, not a new method.** A branch is a
  session with a `parent` (Decision 646), so its agent is its root's, and the method that
  switches a root already names the session: a new `agent.switch {session, path, agent}`
  would have been the same thing with a second name, and an agent path below the root is a
  delegated task, not a window. The rule is the issue's honest one, which the root switch
  already followed: the conversation stays and the definition applies from the next turn;
  tools it no longer holds are neither offered nor callable (the gate is
  `Tools.authorize/3`, which reads the definition at each call), its permissions are the
  new definition's at each call, and a standing `allow_session` the person gave stays
  theirs (a `deny` in the new definition still refuses first). A workspace's `auto` still
  waits for trust (Decision 825): the switch reads with the trust the session was stamped
  with.
