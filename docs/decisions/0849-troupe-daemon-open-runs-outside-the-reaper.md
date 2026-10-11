---
number: 849
title: "`troupe daemon open` runs outside the reaper so the daemon it starts outlives it, a stdio MCP server gone before a write is given a status, clip is given UTF-16LE, /upload weighs a file before reading it, and a protocol client answers its pending calls as it stops"
date: 2026-10-11
status: accepted
paths:
  - clients/tui/lib/troupe/cli/daemon.ex
  - clients/tui/test/troupe/cli_daemon_test.exs
  - apps/troupe_core/lib/troupe/mcp/stdio.ex
  - apps/troupe_core/test/troupe/mcp/stdio_test.exs
  - clients/tui/lib/troupe/clipboard.ex
  - clients/tui/test/troupe/clipboard_test.exs
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/test/troupe/worker_commands_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/client.ex
  - apps/troupe_protocol/test/troupe/protocol/client_test.exs
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

Five of D115's Windows process and connection defects, found by the #502 and #555
fixers.

**`troupe daemon open` runs under no reaper.** On Windows `troupe daemon` runs the daemon
binary under the reaper, in a job that ends with troupe (TUI Decision 130). The reaper
also closes that job once the command it ran has exited, and the job kills everything
still in it. `open` starts the daemon detached, with `start`, which gives it a console of
its own but not a job of its own, and then returns: the job took the daemon with it.
Checked with the installed build on scratch homes: `troupe-daemon open` left a daemon
that `troupe-daemon status` saw; the installed `troupe.exe daemon open`, and the installed
TUI's own `Troupe.CLI.Daemon.run/2`, said "troupe-daemon is running at tcp:..." and three
seconds later there was none; the same code given `reaper: :none` left it running. The
Unix reaper sweeps the command's process group in the same way, which is how the test
shows it on every OS; the TUI runs no reaper there by default.

Two other ways out were weighed. Breakaway (`JOB_OBJECT_LIMIT_BREAKAWAY_OK`, and
`CREATE_BREAKAWAY_FROM_JOB` on the daemon) needs whatever starts the daemon to pass the
flag, and `start` cannot, so the daemon's start line (Decision 802) would have had to
become a mode of the Zig helper. Starting the daemon from the TUI before handing `open`
on would leave a daemon running when `open` refuses, which it does before it starts
anything (no linked plane, a `--url` that is not a web address). So `open` alone runs as
a person runs it, and TUI Decision 130's job stays for every other command, `run`
included. What that gives up: a Ctrl-C while `open` waits ends troupe and not `open`,
which finishes on its own within its timeouts (the daemon answering, its WebSocket, the
plane's discovery document).

**A stdio MCP server gone before a write is given a status.** On Windows the server runs
as a plain port (Decision 654). With Windows Elixir on OTP 28, a write to a program that
has already exited ends the port with `epipe`, and no exit status follows; a write to a
port that has already closed raises `badarg`, on every OS. Either took
`Troupe.MCP.Stdio`'s process down, and with it whatever had linked to it: `mcp.check`
on the installed daemon closed the caller's WebSocket for a server that ran
`cmd.exe /c exit 3`. The process now traps exits: a port's `epipe` is "closed its input",
and after a write to a closed port the exit status that came before the close says
"exited with status N". Pending tool calls are answered either way. A server on
Windows that closes its input and goes on running is still not stopped by Troupe, as
before; the reaper's stdio mode is Unix only.

**`clip` is given UTF-16LE with a byte-order mark.** `clip.exe` reads a file with no mark
in the console's code page, so the UTF-8 the clipboard staged could arrive garbled
outside ASCII; a UTF-16LE mark is how it is told the text is Unicode, whatever the code
page. A stand-in for `clip`, first on `PATH`, recorded the bytes: the tip's were the UTF-8
text, this change's are `FF FE` and the UTF-16LE text. The real clipboard was never
written, so what `clip.exe` itself makes of them was not checked here. Every other
command, `clipboard_command` included, still gets UTF-8.

**A `clipboard_command` in a shell without `<` is refused with a sentence.** It is given
the staged file with `<`, through the platform shell, which on Windows without Git Bash is
PowerShell: it failed with "ParserError". Running it through cmd.exe instead would read
the same setting in a third syntax, depending on the machine; it is a build and test
setting (`config :troupe`), which an installed build does not read, so a sentence saying
why is enough: install Git for Windows, or leave it unset to copy with `clip`.

**`/upload` asks a file's size before it reads it.** Decision 845 refused a frame larger
than the server takes, after the file had been read whole. `Troupe.Client.upload_fits/2`
asks the session's connection whether a file of that size can go in one message, before
the read, and answers with the same sentence. A file that passes may still be refused as
sent, since the frame is larger than the file.

**A protocol client answers its pending calls as it stops.** `Troupe.Protocol.Client`
stopped `:normal` with calls in flight, so every `call/4` exited with it, and a caller
that did not catch the exit went too. As it stops, for whatever reason, it answers each
one `unavailable` with the reason `closed`, which `closed?/1` tells from an `unavailable`
the server sent. The TUI's `Link` reads it as the exit it caught before: "the daemon is not
reachable: the connection closed during <method>", and the next call connects again
(Decision 845).

**Proof.** `cli_daemon_test.exs` (`open` under the Unix reaper leaves what it started
running; it was killed on the tip), `stdio_test.exs` (a server that exits at once, through
`mcp.check`'s probe and through a session's start, and one that answers `initialize` and
exits while its process is held, whose next write met a closed port and crashed it on the
tip), `clipboard_test.exs` (the bytes for `clip` with Windows as the OS, and the refusal
for PowerShell), `worker_commands_test.exs` (the size weighed against the daemon's 16 MiB,
and a 20 MiB file this user may not read refused as too large, where the tip said
"permission denied"), and `client_test.exs` in `troupe_protocol` (a server closing the
connection with one and with two calls in it, and `close/1` with one, each answered
`unavailable`; a server's own `unavailable` is not `closed?`). On Windows, with Windows
Elixir, the installed build on scratch homes and `NoDefaultCurrentDirectoryInExePath`
unset, before and after: `troupe.exe daemon open` (no daemon three seconds later, then
one `troupe-daemon status` sees); `mcp.check` of a server that exits at once, and a
session whose workspace names it (the caller's connection closed and the session listed
no server, then "closed its input" for both); and a non-ASCII `/copy` on a headless
screen into the stand-in (UTF-8, then `FF FE` and UTF-16LE).
