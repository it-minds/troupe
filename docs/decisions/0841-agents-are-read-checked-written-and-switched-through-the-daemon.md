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
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/onboard.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_gateway/lib/troupe/gateway/agents.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/worktrees.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_core/test/troupe/agent/switch_test.exs
  - apps/troupe_core/test/troupe/agent/validate_test.exs
  - apps/troupe_core/test/troupe/agent/local_test.exs
  - apps/troupe_gateway/test/troupe/gateway/agents_api_test.exs
  - PROTOCOL.md
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

Issue #503, its daemon side (sections 1 and 2; the TUI's `/agents` and palette are the
TUI's slot, the desktop app's manager its own, both built on this). Agents were the
least manageable thing in Troupe: `agents.list` gave a name and a description; changing
one meant editing Markdown in a directory a person had to know about, with nothing
checked; a file that did not parse was a `Logger.warning`; and `profile.switch`, the only
way to change a running agent, accepted any name and did nothing with one it did not
have, read only the definitions the session was started with, so an agent saved since
could not be switched to, and dropped a switch sent to an agent that had finished. On the
chunk's tip `agents.get`, `agents.put`, `agents.delete` and `agents.validate` were
`method_not_found`, a `.troupe/agents/broken.md` with `mode: main` was in no listing, and
a branch switched to an agent written after it started stayed on `build` with no event.

- **Four methods, daemon-written, like `mcp.*`** (Decision 700, #60's layer pattern).
  `agents.get` answers a definition whole (every frontmatter key, the instruction, the file
  and its text, its layer, `editable` with the reason when not, the lower files it hides,
  and with a session the windows of its family running it). `agents.validate` answers
  `{ok, errors, warnings}` and writes nothing. `agents.put {name, scope, source}` writes
  `<config>/agents/<name>.md` (`user`) or `.troupe/agents/<name>.md` (`project`;
  `workspace` taken as the same, `mcp.*`'s word). `agents.delete {name, scope}` takes the
  file away. Reading and checking answer on a worker too; writing does not: on a pod the
  agents are the bundle's, and both writes are `forbidden` with a sentence pointing at the
  console (#56), not `method_not_found`, so a client says why. `agents.changed` tells every
  client attached, as `config.changed` does (#57), so the two clients' lists agree.
  `get` and `validate` are `observe`; `put` and `delete` are `admin`, as `mcp.add` is: a
  definition decides what runs.
- **One writer, onboarding's.** `Troupe.Onboard.put_file/5` and `remove_file/4` are the
  writer Decision 823 made, opened to a file that came from nobody else's: the same
  whitelist of paths (`agents/<name>.md`), the same judgement by real path (a project file
  under the workspace's real `.troupe/`, so a `.troupe`, `.troupe/agents` or file that is a
  link out is refused: Decision 829's edge for the reader, held by the writer), the same
  temporary file renamed over it in the same VM-wide transaction, and no provenance.
  Not chosen: a writer of its own in the gateway (a second edge to keep), and `write_file`
  (a free path). Removing a file that is a link takes the link, never what it points at.
  The writer's refusal now says "Troupe writes only there", not "onboarding".
- **Checked on save, loudly; loaded leniently.** `Troupe.Agent.Validate` finds everything
  the loader forgives, each with its field: a key no agent has (onboarding's `imported_*`
  are allowed), `mode` missing or wrong (a file with no frontmatter still loads as a
  subagent, but is not saved as one by accident), `tools` or `skills` of the wrong kind, a
  tool that does not exist (with the nearest names), a permission value that is not
  `auto`/`ask`/`deny`, a permission that grants a tool `tools` leaves out (it could never
  apply; a `deny` of one is allowed, since the built-ins write `plan`'s and `explore`'s
  denials that way and the copy of a built-in must pass), a model the provider does not
  serve by the list the daemon keeps (Decision 778: nothing is asked of a provider on a
  save, and a list never fetched is a warning), `max_turns`, `budget_share` and `override`
  of the wrong kind, and a bad name. An MCP server's or a client's tool is a warning,
  known only once it runs. Every built-in passes (the test reads them all), because
  copying one is the common way to make an agent. The loader stays lenient, as it must
  (one broken file should not stop a session), but a file it cannot read or parse is now
  in `skipped` with the reason in words (`not read: mode must be primary or subagent, not
  "main"`), so it reaches `agents.list` and the session's `files_skipped`, which clients
  already show, as well as the log.
- **What is not a person's to change here.** A built-in is changed by a copy: a `put` of
  its text into either scope, under its name (which then hides it) or another; deleting a
  built-in is refused, and deleting the copy brings it back (`agents.delete` answers the
  layer that answers now). A bundle's agent is the profile's (`editable_reason`: change it
  in the console). A user agent the repository has a file of the same name for is written
  with a warning that the repository's runs there.
- **`agents.list`'s rows** gain `layer` (`builtin`, `bundle`, `user`, `project`, the
  words `scope` uses; `source` keeps saying `global` for the person's, since changing it
  would break a client), `model`, `tool_count`, `read_only` (write_file, edit_file and
  shell all denied, by `Definition.permission/3`, so a tools list that leaves them out
  counts), `max_turns`, `worktree` and `available` with `reason`. `worktree` is what
  `session.create`'s `"auto"` would do in the workspace now, the same for every row: a
  per-agent rule (a read-only agent sharing the checkout) would change `session.create`,
  which is not this decision. `available` is false only for a model the provider does not
  serve, the one reason the daemon can know without starting anything.
- **A branch's agent changes; extended `profile.switch`, not a new method.** A branch is a
  session with a `parent` (Decision 646), so its agent is its root's, and the method that
  switches a root already names the session: a new `agent.switch {session, path, agent}`
  would have been the same thing with a second name, and an agent path below the root is
  a delegated task, not a window. The rule is the issue's honest one, which the root
  switch already followed: the conversation stays and the definition applies from the
  next turn; tools it no longer holds are neither offered nor callable (the gate is
  `Tools.authorize/3`, which reads the definition at each call), its permissions are the
  new definition's at each call, and a standing `allow_session` the person gave stays theirs
  (a `deny` in the new definition still refuses first). A workspace's `auto` still waits
  for trust (Decision 825): the switch reads with the trust the session was stamped with.
  What changed:
  - The definitions are read again from their files at the switch
    (`Definitions.reload/1`, which repeats the snapshot's own `load/2` and `trust/3`), so an
    agent saved since the session started, or edited, is the one switched to; the agent
    keeps the fresh snapshot. A restarted agent replaying `profile_switched` reads them
    again the same way, so it comes back on that agent, not the one it was started with
    (the snapshot's own definition when nothing loads it any more). "Definitions cannot
    change while a session runs" now reads: except when a person switches the agent.
  - A name nothing defines is refused (`not_found`), and a subagent's too (`invalid_params`):
    a person runs a primary agent, `Definitions.primaries/1`, which `agents.list` and the
    palette offer; the issue's example (`explore` to `implementer`) names two subagents,
    and a branch is started on a primary.
  - An agent that has finished takes the switch at once rather than dropping it; its next
    input runs on the new agent. One whose budget ran out stays done.
  - `profile_switched` gains `layer`, `tools_added`, `tools_removed` and `command_id`, and is
    written under the actor who switched it, for the transcript frame (#474).
  - The session's listing says what it runs now: the root updates the index on a switch,
    and a dormant session's row, and one being resumed, take the last root
    `profile_switched` from the log (`Index.switched_to/1`).
  - `commands.list` reads the session's agents again from their files too, so a saved
    agent is a palette row at once.
- **Not here.** The TUI's `/agents` manager and palette rows, the desktop app's form, and
  each window's header are the clients' (built against this). A conflict between two
  clients editing one agent is the last write's (no `if_hash`); a per-agent worktree rule;
  a palette `availability` for an agent's model.
- **Proof:** `Troupe.Agent.SwitchTest` (a branch switched to an agent written after it
  started, the event's fields, the next request's tools, prompt and kept conversation, the
  listing's profile; a denied tool refused when called anyway; an unknown name and a
  subagent refused with nothing written; a finished branch switched; a killed agent coming
  back on the agent written later; a workspace's `auto` still asking): all six failed on
  the tip, where the switch answered `:ok` to anything, stayed on `build` and dropped a
  switch sent to a finished branch. `Troupe.Agent.ValidateTest` (every built-in passes;
  each error and warning; the model against a stand-in gateway's list, unchecked before
  it is fetched). `Troupe.Agent.LocalTest` (both scopes; nothing written with an error;
  links out refused; a built-in not deleted; a link deleted, not its target; the loader's
  `skipped`; `reload/1`). `Troupe.Gateway.AgentsApiTest` over the daemon's socket (a
  built-in whole; `plan` copied into the project under a new name, listed with its badges,
  refused with an unknown tool and nothing changed, fixed; a user copy hiding the built-in
  and deleted; every error at once; bad name and scope; a linked-out `.troupe/agents`
  refused; a broken file listed; `running` across a session and its branch, a switch over
  the wire to a saved agent, its event, the listing, and the refusals; on a pod every
  write refused): all nine failed on the tip with `method_not_found` or an empty
  `skipped`.
