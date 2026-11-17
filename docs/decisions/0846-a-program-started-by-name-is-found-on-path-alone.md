---
number: 846
title: Every program the daemon, the worker and the TUI start by name is found on PATH alone, through Troupe.Executable, never in the current directory or a relative PATH entry, and a command given as a relative path is taken from the workspace
date: 2026-10-10
status: accepted
issue: 555
paths:
  - apps/troupe_protocol/lib/troupe/executable.ex
  - apps/troupe_protocol/credo/path_only_lookup.ex
symbols:
  - Troupe.Executable.find/2
  - Troupe.Executable.resolve/3
  - Troupe.Executable.comspec/1
  - Troupe.Reaper.open/3
  - Troupe.OS.Process.executable/2
  - Troupe.Protocol.Daemon.detach_line/3
gist: "A name is looked up by Troupe.Executable on PATH alone (no cwd, no relative entry), the TUI's too; no bare name to the reaper or to start; relative = workspace's"
---

On Windows `System.find_executable/1`, and `:os.find_executable/1,2` under it, look in the
current directory before `PATH` (#555). On Linux and macOS a relative entry of `PATH`, `.`
or an empty one, is the same hole, opened by the person's own `PATH`.

**One lookup.** `Troupe.Executable.find/2` is how a program is found by name. On Windows
it looks in `PATH`'s absolute entries, in order, never in the current directory and never
in a relative entry, which is the current directory by another name. It tries the
extensions of `PATHEXT` a process can be started from (`.com`, `.exe`, `.bat`, `.cmd`, in
`PATHEXT`'s order) unless the name already has one, and answers an absolute path with
backslashes, which cmd.exe needs in its own name (Decision 845). Elsewhere it answers what
`System.find_executable/1` would, an executable regular file, skipping relative and empty
entries.

**The reaper gets no bare name.** `Troupe.Reaper.open/3` and `open_stdio/3` look up a
first argument that is a name, on the `PATH` the command is given (the caller's, else
`child_env/0`'s, else the VM's), before anything starts. So `git`, the shell's `cmd.exe`
and any later caller are covered without each remembering. A name on no `PATH` is
`{:error, {:not_on_path, name}}`, said as "`git` is not on the PATH", never a bare name
left for the launcher to find somewhere.

**A path is taken as written.** A command with a directory in it is not looked up. An
absolute one is used as it is. A relative one (an MCP server's `bin/server`, an ACP
agent's `./agent`) is taken from the directory the caller names: an MCP server's `cd`,
else the workspace, for an ACP agent the workspace, for the reaper the directory the
command starts in.

**It stays that way.** `Troupe.Credo.PathOnlyLookup`, loaded by `.credo.exs`, fails on
`System.find_executable` or `:os.find_executable` anywhere in `apps/*/lib`, in every form
(a call, `&System.find_executable/1`).

**The TUI is the same lookup.** `Troupe.OS.Process.executable/2` answers what
`Troupe.Executable.resolve/3` answers, through a door of its own in `mix troupe.xref`, and
so tries only the extensions of `PATHEXT` a process starts from, where it used to try
`.js` and `.vbs` too. `Troupe.OS.Process.run/3` starts nothing for a program on no `PATH`:
it answers `<name> is not on the PATH` with status 127, as a shell's "command not found"
does, rather than hand the name to Windows' launcher.

**No bare `cmd` inside a command line.** A client that starts the daemon on Windows runs
`start "troupe-daemon" /min cmd /c ...` (Decision 802), and `start` looks for a bare `cmd`
in the current directory first. That `cmd` is now cmd.exe by its absolute path
(`Troupe.Executable.comspec/1`: `%ComSpec%` when it is absolute, else `cmd.exe` on `PATH`,
else the Windows directory's).

**Not covered.** `System.cmd/3` given a bare name looks it up with `:os.find_executable`
too. In `apps/*/lib` that is the worker's `df` (Linux, no current directory in its lookup)
and the mix tasks' `zig` and `kubectl`, run in a developer's own checkout.
