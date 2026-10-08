---
number: 813
title: "A person's own command (`shell.run`, the TUI's `!cmd`) runs where the session runs, through the agent's own runner, for the session's owner or an `admin` holding `control`; what forbids the agent's shell forbids it; its output starts no turn and is given to the agent before its next model call unless `!!` kept it out"
date: 2026-10-08
status: accepted
issue: 486
paths:
  - apps/troupe_core/lib/troupe/session/shell.ex
  - apps/troupe_core/lib/troupe/tools/shell.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
symbols:
  - Troupe.Session.Shell.run/3
  - Troupe.Session.Shell.refusal/2
  - Troupe.Session.Shell.note/1
  - Troupe.Tools.Shell.execute/3
gist: "shell.run: one runner with the agent's shell; control + owner/admin; policy forbids as for shell; note before next model call, never mid tool exchange; !! kept"
---

Issue #486. A person in the TUI who wants `git status` or the tests either left for
another terminal, and the agent never saw what they saw, or asked the agent, which cost a
model call, an approval and a wait. `shell.run` is the method a client runs a command the
person typed with, and the events it answers with; the TUI's `!cmd` is its first client
(TUI Decision 152). The maintainer settled the two open questions.

- **Where the session runs, in its workspace.** The local daemon's checkout or worktree, or
  the pod's working copy for a session on a plane: `!git diff` has to show the diff the
  agent is working on, not one on the machine the client happens to be. On a pod the
  method is one of the session's (`Troupe.Worker.Auth`), routed as every other method a
  session's token may call; nothing about it is the plane's.
- **One runner.** `Troupe.Tools.Shell.execute/3` is what the agent's `shell` tool runs
  with, factored out of it, and what a person's command runs with: the same shell (`bash
  -c`; Git bash, then `pwsh`, on Windows, Decision 776), the reaper, `Sandbox.check` and
  `Sandbox.wrap` over the mount table, the timeout and the kill, stdin at the null device.
  Its output is capped as the tool's is, the tail at `tool_output_limit` with the whole
  run kept as a blob and the `read_output` marker naming it (Decision 650). The runner
  gained what only a person's command needs, an `on_output` callback at most every 100 ms
  and a `kill/1` message, and the tool passes neither. No new sandbox rule: whatever
  confines the agent's shell confines this.
- **No approval prompt; the authority is the scope, and the owner's.** The person typed
  it, and asking them whether they meant it is noise. The method takes `control`, as input
  does, and on top of it the session's owner or an `admin` (`:admin` in the connection's
  scopes: a plane's owner holds it on their session, a collaborator holds `control`, every
  local connection to a daemon holds all three). A collaborator is refused `forbidden`
  with `required_scope: "admin"` and the sentence "only the session's owner can run
  commands on it". Chosen over letting `control` run it: a collaborator's `control` steers
  an agent whose shell asks before it runs, and this would run arbitrary commands on the
  owner's pod or machine at once.
- **What forbids the agent's shell forbids this** (`refusal/2`):
  `managed_permission_rules_only`, a platform that allows only its own permission rules,
  and agent definitions none of whose primary profiles may run `shell` (`deny`, or not in
  its `tools`). Every primary profile is asked rather than the one in use: a person who
  switched to `plan`, which reads and never runs, still has a shell of their own, and an
  organisation that took the shell away took it from every profile its bundle publishes.
  Each refusal is `forbidden` with `setting` and a sentence a client shows as it is.
- **What it says, and who writes it.** `shell_started` and `shell_output` are ephemeral,
  the first MiB of output streamed; the end is the durable `user_shell` (`command`, the
  capped `output`, `ended` — `exited` with `exit_status`, `timeout`, `killed`, `failed`
  with `reason` — and `agent`), written by the root agent under the actor who ran it, so
  the log and what the agent holds for its next call cannot disagree. A command runs in a
  task under a `Task.Supervisor` of the session placed right under its log, so an agent
  or an MCP server that restarts leaves it running, and the session going takes it with
  it. An agent restarting as it ends is waited for; one that never comes back leaves the
  record in the log, where the next replay finds it. A private session seals `user_shell`
  as it seals every event.
- **The output starts no turn; the next model call is given it.** A `user_shell` the agent
  may have is held as a note (`note/1`): that the person ran it themselves, the command,
  its capped output, how it ended. Before the root's next model call the notes since the
  last one become one `user_input` from `shell`: written before the input that starts a
  turn, so "the tests fail, fix them" after `!mix test` reads after the run it is about,
  or after a tool exchange's results when it ended mid-turn, never between a call and its
  result. A replay folds both events, so a restart gives a note it had not given yet, and
  only once; `Troupe.Log.Fold` witnesses both, a held note present only while one is, so
  every recorded fixture folds as it did. Clients draw the `user_shell` and not the note.
- **`!!cmd` keeps it from the agent** (`agent: false`): run, streamed and logged as the
  person's command, never given to a model call — for output that is noisy or private.
- **Not done here:** the GUI, which can call the same method later; a PTY, interactive
  programs or a persistent shell (every command is a fresh `bash -c`, so `cd` and `export`
  do not carry over).
- **Proof:** `Troupe.Gateway.ShellRunTest` (the method runs in the workspace and ends as
  the person's `user_shell`, streams first, `shell.cancel` and the timeout kill and say so,
  a collaborator and `managed_permission_rules_only` are refused with their sentences, a
  replayed `command_id` runs once; on the chunk's tip every one failed `method_not_found`),
  `Troupe.Session.ShellTest` (the next call's input has the command and output before the
  person's words and none before; `agent: false` never reaches it; a command that ends
  mid-turn comes after the tool exchange; a restart gives a held note once; the refusals),
  `Troupe.Worker.HarnessAuthTest` (on a pod with its real token, the owner runs one in the
  working copy and a collaborator is refused) and `Troupe.Worker.AuthTest` (the guard
  lets a session's token call both methods).
