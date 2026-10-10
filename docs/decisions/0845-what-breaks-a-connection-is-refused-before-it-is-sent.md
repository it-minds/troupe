---
number: 845
title: A WebSocket says at initialize the largest message its socket takes and reads a frame as one message, the TUI sends nothing larger and outlives a dropped call, and on Windows it finds a program on PATH alone
date: 2026-10-10
status: accepted
issue: 502
paths:
  - apps/troupe_gateway/lib/troupe/gateway/web.ex
  - apps/troupe_gateway/lib/troupe/gateway/web/socket.ex
  - apps/troupe_gateway/lib/troupe/gateway/connection.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
  - clients/tui/lib/troupe/os/process.ex
  - clients/tui/lib/troupe/clipboard.ex
symbols:
  - Troupe.Gateway.Web.child_spec/1
  - Troupe.OS.Process.executable/2
  - Troupe.Clipboard.windows_argv/3
gist: WS initialize advertises the socket's ceiling; a frame is one message; TUI refuses larger, survives a dropped call; Windows lookups on PATH alone
---

Three things the #502 audit found broke a connection or a command outright (D108, D109),
and one the agents work found beside them.

**What a connection says it takes is what it takes.** `initialize` advertised
`max_message_bytes` as 64 MiB, the connection's own limit, while a WebSocket's socket
closed any frame over 16 MiB (`max_frame_bytes`, `TROUPE_MAX_FRAME_BYTES`) before the
connection saw it. The TUI read the whole of a 20 MiB file into one `fs.upload`, the
daemon closed the connection, and the upload said "the daemon is not reachable", taking
every call waiting on that connection with it. The ceiling stays: before `initialize`
nobody has shown a token, and a socket that assembled 64 MiB for anyone who asked would
be the easier thing to knock over. So a connection behind a WebSocket says the ceiling
(the smaller of it and the connection's own 64 MiB), and Bandit is given the one number
twice: as the frame limit, plus the 14 bytes of a client's frame header it counts, and as
the limit on a message sent in fragments, which was 8 MB by Bandit's default. The socket
and TCP transports still say 64 MiB. Raising the frame limit to 64 MiB was the other
choice, and it is the one the ceiling exists to refuse.

`Troupe.Remote.Worker` remembers the limit from `initialize` and refuses a request whose
frame is larger, with a sentence: how large it is as sent, what the daemon (or worker)
takes, and that nothing was sent. The connection stays up. `/upload` puts the file's path
before it. Uploading in chunks would need a protocol change (`fs.upload` with an offset)
nobody has asked for yet; a refusal that says why is the honest answer until then.

**A frame is one message.** The WebSocket relay handed each frame to the connection as a
line, and the connection, which frames by lines, cut a frame holding newlines into pieces
and answered none of them: pretty-printed JSON waited for ever. JSON never has a raw
newline inside a string, so outside one every newline is whitespace; the relay replaces
each with a space, which reads the same at the same length, and the socket and TCP
transports keep their framing.

**A dropped call is an error for the caller.** `Troupe.Client.Daemon.Link` caught only a
timeout from its protocol client. When the daemon closed the connection with a call in it,
the client stopped, the link's call exited, the link exited, and the terminal UI that had
asked went with it. The link now answers "the daemon is not reachable: the connection
closed during <method>" and forgets the client, so the next call connects again as it
does after a restart; and `Link.call/2`, `websocket/0` and `ensure/0` answer an error
rather than exit when the link itself is gone or late.

**On Windows a program is found on `PATH` alone, and spelled with backslashes.**
`System.find_executable/1` answers `c:/WINDOWS/system32/cmd.exe`, and the reaper hands the
command line on as Erlang built it, so cmd.exe read the slashes in its own name as
switches and answered "The syntax of the command is incorrect." to everything: `/copy`
and Ctrl-Y copied nothing. It also looks in the current directory before `PATH`, which
for the TUI is the repository it was started in, so a repository's `clip.bat` or
`cmd.exe` would have been what ran. `Troupe.OS.Process.executable/2` looks on `PATH`
alone, with `PATHEXT`'s extensions, skipping relative entries, and answers backslashes;
elsewhere it is `System.find_executable/1`. The clipboard gives cmd.exe `clip` by that
path and the staged file by its name, in arguments of their own, running in the file's
directory: `clip < "<path>"` as one argument reached cmd.exe with its quotes escaped the
way Erlang escapes them, which cmd.exe does not read.

Proof: `loopback_test.exs` (the advertised ceiling, a message exactly that long answered,
the socket transport's 64 MiB, a frame with newlines answered), `worker_commands_test.exs`
(a 17 MiB `fs.upload` and a 20 MiB `/upload` refused with the sentence, the connection up
after), `daemon_client_test.exs` (the link's connection killed with a call in it, from the
link and from the screen), `os_process_test.exs` and `clipboard_test.exs` (the argument
building with Windows as the OS, on every OS, and the platform's own interpreter run).
