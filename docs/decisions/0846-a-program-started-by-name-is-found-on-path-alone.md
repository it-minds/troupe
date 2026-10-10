---
number: 846
title: Every program the daemon and the worker start by name is found on PATH alone, through Troupe.Executable, never in the current directory or a relative PATH entry, and a command given as a relative path is taken from the workspace
date: 2026-10-10
status: accepted
issue: 555
paths:
  - apps/troupe_protocol/lib/troupe/executable.ex
  - apps/troupe_protocol/credo/path_only_lookup.ex
  - .credo.exs
  - apps/troupe_core/lib/troupe/reaper.ex
  - apps/troupe_core/lib/troupe/tools/grep.ex
  - apps/troupe_core/lib/troupe/tools/shell.ex
  - apps/troupe_core/lib/troupe/mcp/stdio.ex
  - apps/troupe_core/lib/troupe/agent/acp_agent.ex
  - apps/troupe_core/lib/troupe/watch/file_system_backend.ex
  - apps/troupe_protocol/test/troupe/executable_test.exs
  - apps/troupe_core/test/troupe/path_only_lookup_test.exs
symbols:
  - Troupe.Executable.find/2
  - Troupe.Executable.resolve/3
  - Troupe.Reaper.open/3
gist: "A name is looked up by Troupe.Executable on PATH alone (no cwd, no relative entry); the reaper gets no bare name; a relative command is the workspace's"
---

On Windows `System.find_executable/1`, and `:os.find_executable/1,2` under it, look in the
current directory before `PATH` (#555). The daemon's current directory is where it was
started, and a daemon the TUI starts inside a repository has that repository, so a
repository carrying `rg.bat` or `pwsh.bat` had it run in place of ripgrep or PowerShell,
on the machine, outside any sandbox: `grep` answered "No matches." from the planted
`rg.bat`, and an MCP server named `pwsh` ran the planted `pwsh.bat`. The issue also noted
that a bare name handed to the launcher did not pick up a planted `git.exe`. That holds
only on a machine that sets `NoDefaultCurrentDirectoryInExePath`, as the one it was tried
on does. Without it, `CreateProcess` looks for a bare name in the directory the command
starts in, after the launcher's own and before the system's, and for Troupe's own git
(Decision 833) that directory is the workspace. A repository's `git.exe` ran in place of
git, before every model call, and so did a `cmd.exe` the shell tool falls back to. On
Linux and macOS a relative entry of `PATH`, `.` or an empty one, is the same hole, opened
by the person's own `PATH`.

**One lookup.** `Troupe.Executable.find/2` is how a program is found by name. On Windows
it looks in `PATH`'s absolute entries, in order, never in the current directory and never
in a relative entry, which is the current directory by another name. It tries the
extensions of `PATHEXT` a process can be started from (`.com`, `.exe`, `.bat`, `.cmd`, in
`PATHEXT`'s order) unless the name already has one, and answers an absolute path with
backslashes, which cmd.exe needs in its own name (Decision 845). Elsewhere it answers what
`System.find_executable/1` would, an executable regular file, skipping relative and empty
entries. It lives in `troupe_protocol`, which every app depends on, so the daemon, the
worker, a client looking for `troupe-daemon` and the apps' mix tasks share it. It mirrors
the TUI's `Troupe.OS.Process.executable/2` (Decision 845), which stays the TUI's own.

**Who uses it.** `grep`'s ripgrep; the shell (`bash`, `pwsh`, `powershell.exe`, and the
`PATH` entries Decision 776's Git Bash search reads); an MCP server's and an ACP agent's
command; `troupe doctor`'s programs; the bench's outcome commands; `troupe instructions
check`'s programs (against the `PATH` a session's commands get); bubblewrap; the login
entry's and a client's `troupe-daemon`; the native watcher's listener, which `file_system`
is now told by its `executable_file` setting because it would otherwise look it up itself;
and the mix tasks' `zig`, `kubectl` and `kubeconform`.

**The reaper gets no bare name.** `Troupe.Reaper.open/3` and `open_stdio/3` look up a
first argument that is a name, on the `PATH` the command is given (the caller's, else
`child_env/0`'s, else the VM's), before anything starts. So `git`, the shell's `cmd.exe`
and any later caller are covered without each remembering. A name on no `PATH` is
`{:error, {:not_on_path, name}}`, said as "`git` is not on the PATH", never a bare name
left for the launcher to find somewhere. A first argument that is an option is the
helper's own (`--version`, which `troupe doctor` asks).

**A path is taken as written.** A command with a directory in it is not looked up. An
absolute one is used as it is. A relative one (an MCP server's `bin/server`, an ACP
agent's `./agent`) is taken from the directory the caller names: an MCP server's `cd`,
else the workspace, for an ACP agent the workspace, for the reaper the directory the
command starts in. Before, `System.find_executable/1` took it from wherever the daemon was
started (on Linux it looked for it along `PATH`), so a workspace's `bin/server` was not
found unless the daemon happened to be started there. An MCP server checked with no
workspace and no `cd` is refused: "`bin/server` is a relative path, and there is no
workspace to take it from".

**It stays that way.** `Troupe.Credo.PathOnlyLookup`, loaded by `.credo.exs`, fails on
`System.find_executable` or `:os.find_executable` anywhere in `apps/*/lib`, in every form
(a call, `&System.find_executable/1`). Tests may still use them.

**Not covered.** `System.cmd/3` given a bare name looks it up with `:os.find_executable`
too. In `apps/*/lib` that is the worker's `df` (Linux, no current directory in its
lookup), the daemon CLI's `open` and `xdg-open`, and the mix tasks' `zig` and `kubectl`,
run in a developer's own checkout. A client starting the daemon on Windows runs `start ...
cmd /c`, whose `cmd` cmd.exe finds as it finds every name. The TUI's own lookups
(`Troupe.CLI.Daemon`, the terminal and the browser) are the TUI's. Each is a follow-up.

**Proof.** `Troupe.PathOnlyLookupTest` runs the daemon's code in a repository that holds
a planted `rg`, `git`, `bash`, MCP server and `AGENTS.md` tool, each writing a marker,
with `.` and a relative `rel` first on `PATH`: `grep` finds the needle, the reaper's `git
--version` is git's, the shell runs `echo`, the MCP server is refused with the sentence,
`instructions check` says the tool is not on the `PATH`, and no marker is written; an MCP
server given as `bin/server` starts from the workspace with the VM elsewhere. All seven
failed on the chunk's tip, as did `ShellTest`'s relative entry, which made a repository's
`bin/bash.exe` the shell. `Troupe.ExecutableTest` plays the lookup with Windows as the OS
on every host. On Windows, with Windows Elixir, the installed build and
`NoDefaultCurrentDirectoryInExePath` unset, the tip ran a planted `rg.bat`, `pwsh.bat` and
`git.exe`, and this change ran none of them.
