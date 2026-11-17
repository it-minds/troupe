---
number: 1034
title: Durations, counts, lists, byte cuts, globs and digests are written once, in the protocol app, and no app keeps a private copy
date: 2026-11-17
status: accepted
issue: 1022
paths:
  - apps/troupe_protocol/lib/troupe/protocol/words.ex
  - apps/troupe_protocol/lib/troupe/protocol/text.ex
  - apps/troupe_protocol/lib/troupe/protocol/glob.ex
  - apps/troupe_protocol/lib/troupe/protocol/digest.ex
  - clients/tui/lib/mix/tasks/troupe.xref.ex
symbols:
  - Troupe.Protocol.Words
  - Troupe.Protocol.Text.cut/2
  - Troupe.Protocol.Glob.regex/2
  - Troupe.Protocol.Digest
gist: "Words, Text.cut, Glob.regex and Digest are the only copies; every app and the TUI call them; `min` in prose, `30-minute` before a limit"
---

# Durations, counts, lists, byte cuts, globs and digests are written once, in the protocol app

The small helpers that turn a number or a list into words, cut a binary to a size, turn a
glob into a regular expression or write a SHA-256 as hex live in `troupe_protocol`, the
one app the core, the plane, the gateway, the worker and the TUI may all call, and
nowhere else:

- `Troupe.Protocol.Words`: `duration/2` (`59 s`, `1 min 30 s`, `1 h 1 min`; `:short` is the
  terminal's strip and header form, `14s`, `4m 2s`; `:adjective` is a limit's size before
  its noun, `30-minute`), `ago/2`, `count/3`, `plural/3`,
  `and_list/1` (`a, b and c`).
- `Troupe.Protocol.Text.cut/2`: the longest valid UTF-8 prefix within a byte size.
- `Troupe.Protocol.Glob.regex/2`: `**/`, `**`, `*`, `?`, with options for a subject with no
  directories, `{a,b}` and `[a-z]`.
- `Troupe.Protocol.Digest`: `sha256/1` (lowercase hex) and `tagged/1` (`sha256:<hex>`).

A module that needs one of these calls it; a private function with the same body is a
copy and goes. A wrapper with a name of its own that says what the value is for (a blob's
name, a salted secret's hash) may stay, as long as its body is the call. `Words` is
pure formatting, so the TUI's UI may call it as it calls `Glob`; `mix troupe.xref`
allows it.

A minute is `min`, an hour `h`, a second `s`, in prose on every surface the server and
the terminal write; the strip and header form is the terminal's alone, and a limit named
before its noun keeps the released stop sentence, "its 30-minute working limit is spent",
which the desktop app says too. Only a latency
measured for a person tuning something (`answered in 312 ms`, a log's `first byte after`)
keeps milliseconds.

**Not chosen**: one helper module per app. Ten duration formatters had grown that way and
spelled a minute three ways (`3m`, `3 min`, `3-minute`); the plane may not call the core,
so the core could not be the home.

**If undone**: a sentence about a limit, a timeout or a count reads differently on the
plane, in the daemon and in the terminal, and the four byte cuts and four glob
translators drift apart again, as they had (graphemes in one, a byte at a time in
another; a different `**` in each).
