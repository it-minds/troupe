---
number: 776
title: On Windows the shell is Git for Windows' bash, never WSL's launcher; no command Troupe starts has the release's own runtime on its `PATH`; `grep` searches a file its `path` names; and a glob that matched nothing says so
date: 2026-10-04
status: accepted
paths:
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/lib/troupe/reaper.ex
  - apps/troupe_core/lib/troupe/tools/grep.ex
  - apps/troupe_core/lib/troupe/tools/shell.ex
  - apps/troupe_core/test/support/fake_openai.exs
  - apps/troupe_core/test/troupe/tools/file_tools_test.exs
  - apps/troupe_core/test/troupe/tools/shell_test.exs
gist: On Windows the shell is Git for Windows' bash, never WSL's launcher; no command Troupe starts has the release's own runtime on its `PATH`
---

Found by the
first `troupe bench --live --suite standard --repeat 3` (Decision 775), against
`qwen3-235b` from the installed `troupe` on Windows: 20 of 30 runs succeeded, and nine
of the ten failures came from these three, not from the model.
- **The shell ran in Linux.** `windows_shell/0` took the first `bash` the VM found,
  and on a Windows `PATH` that is `C:\Windows\System32\bash.exe` wherever WSL is
  installed: the launcher of a Linux distribution. Every command ran there, in another
  operating system, while the tool's description told the model "the host is Windows";
  there the Windows `elixir` is a shell script that finds no `erl`, so no run could
  execute a test. `implement_spec` failed twice with code it could not try, and one
  `fix_test` run spent ten shell calls repairing Erlang, one of them a 60 kB
  `ls -R`. `Troupe.Tools.Shell.windows_bash/2` now looks for Git for Windows' bash
  beside the `git` on the `PATH`, then where its installer puts it (the program files
  directories, and `%LOCALAPPDATA%\Programs\Git` for a per-user install), then for any
  `bash.exe` on the `PATH` outside the Windows directory and the `WindowsApps`
  aliases; with none it is PowerShell, as before. A person who wants WSL runs Troupe in
  WSL, where the host and the shell agree.
- **And then `elixir` died at boot.** With Git's bash, the next layer showed: the VM
  puts its own runtime's `bin` first on the `PATH` its children inherit, and in a
  release (the installed `troupe` and `troupe-daemon`) that runtime's `erl` has no
  boot file, so the `elixir` or `mix` a command ran found it first and stopped with
  `cannot get bootfile ... start.boot`. Decision 773 found this for the bench's
  outcome commands and fixed it there alone. `Troupe.Reaper.child_env/0` now gives
  every command started through reaper (the shell tool, `grep`'s ripgrep, git, MCP
  servers) a `PATH` without the release's runtime, and the bench's outcome uses the
  same; a caller's own variables still win.
- **`grep` on one file.** Its `path` was taken for a directory: ripgrep ran in it and
  the built-in scan globbed under it, so a file found nothing, and the answer was "No
  matches." for a search of the very file that held them. Every `large_log` run asked
  exactly that (`ERROR.*E1042` in `logs/service.log`) and wrote 0. Now a file is
  searched alone: ripgrep beside it with `--with-filename`, the built-in scan on that
  file, both answering `path:line: text` relative to the workspace as before; the
  schema says a directory or one file.
- **A glob that matched nothing.** The tool's description gave `**/*.ex` as its
  example, and all three `rename_symbol` runs narrowed with exactly that in a project
  of `.exs` files, were told "No matches.", and concluded the function had no callers.
  The example is gone, the description says to check what the files are called before
  narrowing by extension, and an empty search with a glob answers `No matches in files
  matching **/*.ex.`, so a glob that missed is not taken for an absent name.
- **Not changed:** the `build` agent's "call `todo_write` first" for more than two
  steps, which took about a third of `qwen3-235b`'s calls on these small tasks and one
  `follow_steps` run's last call; a bench of real work should say whether that is too
  much before it moves.
- **Proof:** `Troupe.Tools.ShellTest`: WSL's launcher first on the `PATH` passed over
  for Git's bash, a Git found from its `git` wherever installed, another bash with no
  Git, neither WSL path ever, and a per-user Git; `ShellReleasePathTest`: with
  `RELEASE_ROOT` set and the runtime's `bin` first on the `PATH`, a shell command's
  `$PATH` is without it. `FileToolsTest`: a file as the path,
  with ripgrep and with the built-in scan; a glob that matched nothing named. On the
  chunk's `grep.ex` the same search of a file answered `No matches.` with the built-in
  scan and `ripgrep failed: ` with ripgrep on Linux, and `No matches.` in the bench's
  own log on Windows; the stand-in's `large_log` script now greps the file, as the
  model did. On this machine the installed daemon's `Shell.shell/0` answered
  `C:/WINDOWS/system32/bash.exe` before the change and Git's after, and a headless
  session of the installed `troupe` ran `uname -s; elixir -e ...` as `MINGW64_NT` with
  the boot failure above, then, with the `PATH` fixed, printing the answer, on the
  pull request.
