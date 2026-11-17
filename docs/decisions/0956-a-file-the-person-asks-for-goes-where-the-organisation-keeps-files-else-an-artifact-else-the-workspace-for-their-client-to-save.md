---
number: 956
title: "A file the person asks for goes where the organisation keeps files, else it is published as an artifact, else it is made in the workspace for their client to save; what the person or an instruction says outright comes first, and when none of it is clear and more than one way is open the agent asks once: the harness says this to every root agent in a layer of its own, harness, before the organisation's memory, with what is open in that session; a tool that stores files is one its server's config marks stores: files, never one guessed from a name; and a deliverable is written with write_file's deliverable: true, said with file_ready, which both clients offer to save"
date: 2026-10-27
status: accepted
issue: 765
paths:
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/instructions/harness.ex
  - apps/troupe_core/lib/troupe/artifacts.ex
  - apps/troupe_core/lib/troupe/mcp/tool.ex
  - apps/troupe_protocol/lib/troupe/mcp/server.ex
symbols:
  - Troupe.Instructions.Harness
  - Troupe.Artifacts.ready/1
  - Troupe.MCP.Server.stores_files?/2
gist: "A root's first layer, harness, says where a file goes (store, artifact, workspace; asked when unclear) and what is open; stores: files is declared; deliverable gives file_ready"
---

#765, the chunk whose spine is "a person's things, in a person's apps". The maintainer's
rule for a file the person asks for: put it where the organisation keeps files, else
publish it as an artifact, else make it in the workspace for the client to save; what the
person or the agent's instructions say outright comes first; when none of it is clear,
ask.

## The harness's own layer

**Every root agent's instructions start with a fixed paragraph of the harness's
(`Troupe.Instructions.Harness`), then what is open in that session.** It is a layer of its
own, `scope: harness`, `path: harness`, listed first in `instructions_loaded` (with `open`,
what it said was open, so the log says which ways a turn was told of) and before the
organisation's memory in the prompt, outside the files' budget and never cut. Being first
is what lets every layer after it say otherwise: the paragraph says an instruction after
it decides outright, so an organisation's memory or an `AGENTS.md` that says "reports go to
the wiki" wins, as the person's own words do. It goes where the instruction files go, so
with the default `system_prompt: stable` it travels with the turn and the system prompt
itself does not change (Decision 863).

The paragraph is the same in every session and about 110 words, since every prompt
carries it. What follows it is per session, three lines, so the model is not guessing:

- **Where the organisation keeps files**: the tools this turn offers whose config marks
  them so, by name, or "no tool here does that". A marked server still starting (a stdio
  one answers a moment after the session starts) is said to be, in `open.starting` too,
  rather than waited for: waiting would hold the agent's process, and its cancel, for
  seconds on every first turn that has one, where a line costs a dozen words and only then.
- **An artifact**: `publish_artifact` where it can publish from here; "not from here" with
  why where the session is under Local only (Decision 951) or the daemon is not signed in
  to a plane; "no plane publishes one" where the host installed nowhere for one to go.
  `Troupe.Artifacts.ready/1` answers it: the host's install takes a `ready` function, the
  daemon's being whether it is linked to a plane, and a pod's always ready. Whether the
  plane has `artifacts_enabled` on is not known without asking it, and is left to the
  plane's refusal when one is sent.
- **The workspace, always**: on a session on the person's machine, that the file is
  already there; on a pod, that their client saves it from there.

The tools are read after the turn holds its tools (Decision 871), from what the profile is
offered (`Troupe.Tools.available/2`), so a profile that denies `publish_artifact` is told
there is no artifact. A subagent has no harness layer: the agent that delegated says in
the brief what the task delivers and where, and a child that asked the person where its
work goes would ask a question the parent already answered.

**The ask is the question tool there is.** When more than one way is open and the person
named none, the paragraph tells the agent to ask one question with `ask_user`, the open
ways as its options in the order above, and go on with the answer. A headless run answers
a question with its first option and prints the line (`Troupe.UI.Headless.Printer`), so
with the options in that order it takes the first open way and says so; nothing new was
needed for it. When only the workspace is open there is nothing to ask.

## A tool that stores files is declared

**An MCP server's entry says `stores: files`, and `files` names which of its tools save
one (all of them when left out); nothing is inferred from a tool's name.** A tool called
`upload` might put a file on a ticket, in a chat or in a bucket nobody reads; only the
person or administrator who configured the server knows it is the organisation's store.
The two keys are read in `mcp.json` and `config.yaml`'s `mcp:` (the config schema has
them), in a bundle's `mcp_servers` (refused at publish when `stores` is anything but
`files`, or `files` comes without it), and carried on each tool as `files` (`Troupe.MCP.Tool`,
the stdio server's tools, a turn's hold so a restarted agent names the same tools). A
person's server offered to a pod's session carries it too: `mcp.tools` answers `files:
true` on such a tool, and the TUI and the desktop app say it again in `tools.register`,
which keeps it on the registration. The `WorkerProfile` resource's own `mcpServers` do not
take it yet; a pod's servers come with its bundle, which does. Writing to the store is the
server's: Troupe calls the tool as any other, under the same permission.

## The workspace, and the client's Save

**A deliverable is written with `write_file` and `deliverable: true`, which is followed by
a `file_ready` event: `path` (as `fs.read` takes it), `size`, `hash`, and on a session on the
person's machine `local_path`.** The choice was between that argument and a `deliver_file`
tool. The argument is the cheaper in the prompt: one property of 80 bytes in a schema every
call already sends, against a tool's name, description and schema of some 300 bytes on
every call; a 31-call turn pays that difference 31 times. Its limit is that a file made
another way (a spreadsheet a shell command wrote) has no `file_ready`; the agent says
where it is, as the paragraph tells it to, and a client shows that answer.
