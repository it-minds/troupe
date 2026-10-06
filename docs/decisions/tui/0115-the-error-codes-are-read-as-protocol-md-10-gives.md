---
number: 115
title: The error codes are read as PROTOCOL.md §10 gives them (this supersedes Decision 81)
date: 2026-09-25
status: accepted
supersedes: [81]
paths:
  - PROTOCOL.md
  - apps/troupe_protocol/lib/troupe/protocol/error.ex
  - clients/tui/lib/troupe/remote/rpc.ex
gist: The error codes are read as PROTOCOL.md §10 gives them (this supersedes Decision 81)
---

`Troupe.Remote.RPC` was written against the plane's first contract, in which
-32001 was unauthorized, -32003 forbidden, -32004 not found, -32009 a conflict,
-32010 no capacity and -32012 a session that had moved. The daemon, the plane and the
worker in this repository all answer with `Troupe.Protocol.Error`, which is §10, so
a missing scope (-32004) was reported as "not found", a real conflict (-32006) arrived
as the bare word, and the daemon's `payload_too_large` (-32012) had the worker re-open
the session and queue the command again without its parameters. `reason/1` is now
§10's table, token for token, and its test reads the table out of PROTOCOL.md; -32003
is a token problem whatever `data` says; and `describe/1` follows the word with the
cause `data` gives (`component`, `reason`, `detail`), since `message` is only the
token. Nothing in §10 says a session has moved, so the re-open and retry that -32012
set off is gone with it (defects.md D12).
