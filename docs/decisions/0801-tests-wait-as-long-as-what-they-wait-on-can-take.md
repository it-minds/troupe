---
number: 801
title: A test waits for as long as what it waits on can honestly take, and a daemon a test starts in its own OS process loads the build through a cached code path, not a -pa for each directory
date: 2026-10-06
status: accepted
paths:
  - apps/troupe_worker/test/troupe/worker/reader_log_test.exs
  - apps/troupe_gateway/test/troupe/gateway/restart_test.exs
  - apps/troupe_gateway/test/troupe/gateway/autospawn_test.exs
  - clients/gui/packages/client/test/stage1.test.ts
gist: "Test daemons take the build by Code.prepend_paths(cache: true), never a -pa each; a wait behind :global.trans covers its 8 s backoff"
---

## The restore behind a reader's lock

The restore takes the session's log lock, `Restore.with_log/2`, which is `:global.trans/3`.
A taken lock is not handed over when it is let go: the waiter tries again after a random
pause, uniform up to 125 ms and doubling with each try to at most 8 seconds
(`global:random_sleep/1`). The test holds the lock 500 ms, so the restore is usually
asleep for a few hundred ms more after the release, and now and then for seconds; a test
process that is late to let go, as a busy runner makes it, lets the pauses grow. The
default 5-second `Task.await` was shorter than one pause can be.

So the await is 15 seconds: the longest pause, 8 s, and the restore's own work with room
for a loaded runner. Waiting for the log file to appear would be the same wait under
another name. The lock's backoff is shipped code and stays: production holds it for file
work of a few milliseconds, where the waiter's first or second try gets it, and nothing
here showed a session the worse for it.

## The refresh in flight when the turn ends

The test's token lives 20 seconds and the pod warns 18 before `exp`, so the warning comes
about two seconds into the turn. But it comes two seconds into every token, the refreshed
one too: a second warning can land as the 3.6-second turn ends, and the attachment is then
`refreshing` until the plane has minted for it. The test read `status` once, right after
the turn.

The test now records every status the attachment reports, waits for the refresh in flight
to finish, and asserts more than before: the attachment went `connecting`, `live`,
`refreshing`, and from then on only `live` and `refreshing`, never a reconnection and never
a refresh that failed (`live` with a reason), besides the single `initialize` and the new
token it already checked. Under the same loads, and a compile in WSL besides, it passed 20
runs in 20. The fake pod's repeated warning is what a real pod does and stays.

## The daemon a test starts

`RestartTest` and `AutospawnTest` start a real daemon in its own OS process, `elixir` with
a `-pa` for each of the build's 58 `ebin` directories. OTP never caches a `-pa` or `-pz`
directory (only the boot paths and `ERL_LIBS`), so every module the daemon loaded, OTP's
and Elixir's among them, was looked for on disk in each of those directories first. On
`/mnt/c`, where a WSL checkout of this Windows machine builds, every look is slow, and it
was most of the start.

The daemon now puts the build on its own path, cached, in a first `-e` of its own: the boot
names `%Troupe.Protocol.Endpoint{}`, and a struct is expanded before any of the `-e` it is
in runs. `ERL_LIBS` was as fast, but every program the daemon starts inherits it, the shell
its tools run in and any `elixir` among them, and it puts the build after kernel and stdlib
where the `-pa` it replaces put it first. Starting the daemon from a release would build
one in a test, minutes, and test that release rather than the code under test. The
30-second wait stays: the start under load is a fifth of it.
