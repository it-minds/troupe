---
number: 849
title: "`troupe daemon open` runs outside the reaper so the daemon it starts outlives it, a stdio MCP server gone before a write is given a status, clip is given UTF-16LE, /upload weighs a file before reading it, and a protocol client answers its pending calls as it stops"
date: 2026-10-11
status: accepted
paths:
  - clients/tui/lib/troupe/cli/daemon.ex
  - apps/troupe_core/lib/troupe/mcp/stdio.ex
  - clients/tui/lib/troupe/clipboard.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - apps/troupe_protocol/lib/troupe/protocol/client.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
symbols:
  - Troupe.CLI.Daemon.run/2
  - Troupe.MCP.Stdio
  - Troupe.Clipboard.staged/3
  - Troupe.Clipboard.shell_line/3
  - Troupe.Client.upload_fits/2
  - Troupe.Remote.Worker.upload_fits/2
  - Troupe.Protocol.Client.closed?/1
gist: "`open` runs under no reaper; Stdio traps its port's exit; clip gets UTF-16LE+BOM; /upload stats first; Protocol.Client answers pending calls on stop"
---

**`troupe daemon open` runs under no reaper.** On Windows `troupe daemon` runs the daemon
binary under the reaper, in a job that ends with troupe (TUI Decision 130). The reaper
also closes that job once the command it ran has exited, and the job kills everything
still in it. `open` starts the daemon detached, with `start`, which gives it a console of
its own but not a job of its own, and then returns: the job took the daemon with it.

Two other ways out were weighed. Breakaway (`JOB_OBJECT_LIMIT_BREAKAWAY_OK`, and
`CREATE_BREAKAWAY_FROM_JOB` on the daemon) needs whatever starts the daemon to pass the
flag, and `start` cannot, so the daemon's start line (Decision 802) would have had to
become a mode of the Zig helper. Starting the daemon from the TUI before handing `open` on
would leave a daemon running when `open` refuses, which it does before it starts anything
(no linked plane, a `--url` that is not a web address). So `open` alone runs as a person
runs it, and TUI Decision 130's job stays for every other command, `run` included. What
that gives up: a Ctrl-C while `open` waits ends troupe and not `open`, which finishes on
its own within its timeouts (the daemon answering, its WebSocket, the plane's discovery
document).

**A stdio MCP server gone before a write is given a status.** On Windows the server runs
as a plain port (Decision 654). Either took `Troupe.MCP.Stdio`'s process down, and with it
whatever had linked to it: `mcp.check` on the installed daemon closed the caller's
WebSocket for a server that ran `cmd.exe /c exit 3`. The process now traps exits: a port's
`epipe` is "closed its input", and after a write to a closed port the exit status that
came before the close says "exited with status N".

**`clip` is given UTF-16LE with a byte-order mark.** `clip.exe` reads a file with no mark
in the console's code page, so the UTF-8 the clipboard staged could arrive garbled outside
ASCII; a UTF-16LE mark is how it is told the text is Unicode, whatever the code page.
Every other command, `clipboard_command` included, still gets UTF-8.

**A `clipboard_command` in a shell without `<` is refused with a sentence.** It is given
the staged file with `<`, through the platform shell, which on Windows without Git Bash is
PowerShell: it failed with "ParserError". Running it through cmd.exe instead would read
the same setting in a third syntax, depending on the machine; it is a build and test
setting (`config :troupe`), which an installed build does not read, so a sentence saying
why is enough: install Git for Windows, or leave it unset to copy with `clip`.

**`/upload` asks a file's size before it reads it.** Decision 845 refused a frame larger
than the server takes, after the file had been read whole. `Troupe.Client.upload_fits/2`
asks the session's connection whether a file of that size can go in one message, before
the read, and answers with the same sentence.

**A protocol client answers its pending calls as it stops.** `Troupe.Protocol.Client`
stopped `:normal` with calls in flight, so every `call/4` exited with it, and a caller
that did not catch the exit went too. As it stops, for whatever reason, it answers each
one `unavailable` with the reason `closed`, which `closed?/1` tells from an `unavailable`
the server sent.
