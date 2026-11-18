---
number: 832
title: "On a worker every command runs in the sandbox, whatever the session's mounts or bundle: the worker's own configuration sets it, the reaper wraps what it starts, and a worker that cannot start bubblewrap refuses the command with a sentence and says so once in its log; a local daemon is unchanged"
date: 2026-10-10
status: accepted
issue: 528
paths:
  - apps/troupe_core/lib/troupe/sandbox.ex
  - apps/troupe_core/lib/troupe/reaper.ex
  - apps/troupe_core/lib/troupe/tools/shell.ex
  - apps/troupe_core/lib/troupe/agent/acp_agent.ex
  - config/runtime.exs
  - apps/troupe_plane/lib/troupe/plane/fleet/size_class.ex
symbols:
  - Troupe.Sandbox.required?/0
  - Troupe.Sandbox.check/0
  - Troupe.Sandbox.command/3
  - Troupe.Reaper.open/3
gist: "Worker: sandbox :always from runtime.exs; Reaper wraps every command (cwd alone if no table); no bwrap or refused = sentence + one log line, never unconfined"
---

- **The worker sets it, in its own configuration.** `config/runtime.exs` sets `config
  :troupe_core, sandbox: :always` inside the block a worker's
  `TROUPE_WORKER_AUTOSTART=true` opens, beside `usage_sink`. It is not an environment
  variable or a profile field: a pod that could be told not to sandbox is one that someone
  will tell. The worker image already installs bubblewrap (`docker/Dockerfile`).
- **The reaper wraps what it starts.** Every process Troupe starts goes through
  `Troupe.Reaper` (Decision 733's premise), so that is where the rule lives: `open/3` and
  `open_stdio/3` ask `Troupe.Sandbox.command/3` before they start anything. A caller that
  passes `mounts:` (`shell`, and so `shell.run`, Decision 813) is sandboxed over that
  table as before, by `enabled?/1`; on a worker a caller that passes none (`git_read`'s
  git, `grep`'s ripgrep, the brief's and the worktree's git, a stdio MCP server) is
  sandboxed over its own directory alone, with the private `/tmp` as `$HOME` so a file the
  repository carries is never its configuration. Chosen over wrapping each tool: a tool
  added later is covered without anybody remembering, and `tools/git_read.ex`,
  `session/memory.ex` and `worktree.ex` did not change (another change was rewriting git's
  settings in them at the same time).
- **An ACP agent too.** Its program is started by a port of its own, not the reaper, so
  `Troupe.Agent.ACPAgent` asks `Sandbox.command/3` itself on a worker: over the session's
  mounts, `$HOME` the private `/tmp`. A program installed outside the system directories
  the sandbox binds (`/usr`, `/bin`, `/lib`...) does not start there.
- **Refused, never run outside.** `check/0` on a worker refuses when bubblewrap is not
  there, and when it is there and the kernel will not let it build a namespace
  (unprivileged user namespaces off, a seccomp or AppArmor profile that forbids them),
  found by starting one empty sandbox the first time a command asks and remembered for
  that bubblewrap. It is logged once for each bubblewrap and reason, at error, as a reaper
  that will not start is (Decision 733).
- **What the namespace has.** Besides the system roots, the files name resolution and user
  lookup read: `/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`, `/etc/passwd`,
  `/etc/group`, read-only, where they exist. Without them a command in the sandbox
  resolved no host name and had no user name, which every pod command would now have met.
- **A local daemon is unchanged.** `:auto` stays its default: `shell` is wrapped only for
  a session with a mount besides its workspace and only where bubblewrap is installed,
  which a laptop session never has, and nothing else the reaper starts is wrapped. A
  daemon that had `:always` set by hand now sandboxes git, ripgrep and MCP servers as
  well, as a worker does.
