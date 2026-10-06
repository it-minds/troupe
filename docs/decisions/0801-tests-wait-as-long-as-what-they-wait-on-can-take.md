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

Three tests held up releases or chunk pull requests without anything being wrong: the
worker's `ReaderLogTest` "a restore waits for a reader that is taking its log away" timed
out on the ninth of the ten passes in the 0.8.6 release run (37496770930, first attempt);
the GUI client's "mints and refreshes on the open socket without interrupting a turn"
failed the chunk 21 pull request's GUI job (`actual: 'refreshing'`); and the gateway's
`RestartTest` and `AutospawnTest` start a daemon that "never came up" in time under load
(D8, D73, D81). Each now waits for the thing it is about, as long as that thing can take
on a healthy machine, and no assertion went.

The load in every measurement below is 64 busy shell loops in WSL on this 32-thread
machine, as Decision 796 used, and for the GUI client also 40 busy `node` loops on Windows,
because the shell loops in WSL barely touch a Windows process.

## The restore behind a reader's lock

The restore takes the session's log lock, `Restore.with_log/2`, which is `:global.trans/3`.
A taken lock is not handed over when it is let go: the waiter tries again after a random
pause, uniform up to 125 ms and doubling with each try to at most 8 seconds
(`global:random_sleep/1`). The test holds the lock 500 ms, so the restore is usually
asleep for a few hundred ms more after the release, and now and then for seconds; a test
process that is late to let go, as a busy runner makes it, lets the pauses grow. The
default 5-second `Task.await` was shorter than one pause can be.

- Under load, 41 runs at the test's 500 ms: the restore finished 27 to 1,528 ms after the
  release. A simulation of the pauses (a million runs) agrees: median 230 ms, 99th
  percentile 1.8 s, and 64 in a million over 4.5 s.
- With the hold made 4 s for the measurement, a test process three and a half seconds late
  to let go, 30 runs: 7 finished more than 5 s after the release (5.1 to 6.8 s), each one a
  failure of the old `Task.await`; the simulation says 18 % over 4.5 s at that hold.
- The fastest finished 27 to 52 ms after the release: the restore's own work, when its next
  try came at once.

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
the turn. On the tip under both loads it failed 2 runs in 20 that way, with the token
already replaced.

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
was most of the start. From launch to a listening daemon, three runs each:

| how the build is on the code path | `/mnt/c`, idle | `/mnt/c`, under load | ext4, idle | ext4, under load |
| --- | --- | --- | --- | --- |
| a `-pa` for each directory (before) | 22.4 to 23.5 s | 36 to 45 s | 0.44 to 0.46 s | 2.8 to 3.1 s |
| a `-pz` for each directory | 10.6 to 11.4 s | | | |
| `ERL_LIBS` naming the build's `lib` | 1.7 to 1.8 s | | | |
| `Code.prepend_paths(..., cache: true)` from inside (now) | 1.5 to 1.7 s | 5.5 to 7.1 s | 0.38 to 0.41 s | 2.9 to 3.0 s |

On ext4, the build copied to WSL's own disk as a CI runner has it, the `-pa` costs little,
which is why CI's gateway passes have not been failing on it; the flake is the one a
checkout on `/mnt/c` meets. `RestartTest` waits 30 seconds for its daemon, so under load
there it failed every time: both of its tests, "the daemon never came up", on the tip.

The daemon now puts the build on its own path, cached, in a first `-e` of its own: the boot
names `%Troupe.Protocol.Endpoint{}`, and a struct is expanded before any of the `-e` it is
in runs. `ERL_LIBS` was as fast, but every program the daemon starts inherits it, the shell
its tools run in and any `elixir` among them, and it puts the build after kernel and stdlib
where the `-pa` it replaces put it first. Starting the daemon from a release would build
one in a test, minutes, and test that release rather than the code under test. The
30-second wait stays: the start under load is a fifth of it.

Under the same load both files then passed 20 runs in a row, `RestartTest`'s two tests and
`AutospawnTest`'s four, 23 to 33 seconds a run for the two files together, where the run on
the tip took 148 seconds to fail.

## Not in this

- `ReaderLogTest` "a read whose reader meets an activation as it writes" also waits behind
  the log lock with the default 5-second `Task.await` (`Task.await(reading)`); its hold is
  shorter, so the pause it can meet is too, but it is the same wait.
- The lock's backoff in production: a reader or an activation waiting behind a long hold
  can sleep up to 8 s after it is free. Nothing holds it that long today.
