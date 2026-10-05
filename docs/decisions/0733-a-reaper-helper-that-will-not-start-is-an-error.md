---
number: 733
title: "A reaper helper that will not start is an error its caller gets back, never a raise: the session answers, runs no command, and `troupe doctor` says why"
date: 2026-09-29
status: accepted
issue: 270
paths:
  - apps/troupe_core/lib/troupe/doctor.ex
  - apps/troupe_core/lib/troupe/reaper.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/lib/troupe/tools/shell.ex
  - apps/troupe_core/test/troupe/doctor_test.exs
  - apps/troupe_core/test/troupe/reaper_test.exs
gist: "A reaper helper that will not start is an error its caller gets back, never a raise: the session answers, runs no command, and `troupe doctor` says…"
---

Issue
#270. `Troupe.Reaper.open/3` called `Port.open/2` directly, and that raises when the
program is there and will not start: no execute bit or a mount that forbids running
it on Linux, a file that is not a program on Windows (`eacces` on both). Every model
call asks `git` where the repository is, in the agent's own process
(`Instructions.load`, then `Session.Memory.path/1`), so such a helper crashed the
root agent on every turn and the session never answered; the loop that followed is
what Decision 727 bounds. `open/3` and `open_stdio/3` now return
`{:reaper_unstartable, reason}` with the OS's reason, and log it once for each helper
and reason, not at every call. On Windows a working directory that has gone raises
the same way; that is `{:no_directory, cwd}`, and not blamed on the helper. The
callers: the brief's `git` calls read the workspace as no repository, as a missing
`git` already did, so a session at the repository's root still reads its brief and
one in a subdirectory or a worktree reads none that turn; `shell` answers the model
with the helper's path, the reason and that nothing runs until it does; `grep` scans
in the VM, as it does without a helper; `git_read` and an MCP server say they could
not run, and why. `troupe doctor` gains a `reaper` line, `reaper --version` started
in the workspace: `ok` with what it printed, `warn` for a build without a helper (a
source checkout without Zig, where `shell` never ran), and `FAIL` for one that will
not start, since that is an install a person has to put right and a session shows it
only through the model's words. A harness note in the session was the other place to
say it, and would say in every session what the doctor's one line says once.
`config :troupe_core, :reaper` names a helper elsewhere, as `:bwrap` does for
bubblewrap; the suite points it at one that will not start. Proof: `reaper_test.exs`
(a turn answered, a shell call that is a tool error and a turn that goes on, the
brief read as no repository with one warning over three loads, `grep`, `git_read`,
an MCP server, a directory that has gone), nine of whose eleven tests fail on the
chunk's tip with the config key alone; `doctor_test.exs`; and the installed build
with its helper swapped for a file that is not a program.
