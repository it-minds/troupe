---
number: 781
title: "A tool's result is cut at 32 KiB by default, not 60,000 bytes: what is cut is one `read_output` call away, and what is sent goes out again with every call after it"
date: 2026-10-05
status: accepted
issue: 407
paths:
  - apps/troupe_core/lib/troupe/config.ex
gist: "A tool's result is cut at 32 KiB by default, not 60,000 bytes: what is cut is one `read_output` call away, and what is sent goes out again with…"
---

- **Why 32 KiB (32,768 bytes).** The maintainer's choice between the old 60,000 and
  the issue's candidate, 16 KiB, the blob inline limit where 771's stub floor sits.
  32 KiB still sends whole what an agent ordinarily asks for: a `grep` of 200
  matching lines of up to about 160 bytes, and a file of `precise_edit`'s size (1,560
  lines, 31,042 bytes as `read_file` numbers them) in one read. At 16 KiB that file
  is cut, and so is such a `grep` past about 80 bytes a line, and each cut the model
  needs the rest of is a round trip; a number below 32 KiB needs measurements of its
  own.
- **What a cut costs.** The model is sent the first 32 KiB and the marker, and
  `read_output` pages the rest back, 200 lines a call: one round trip, the whole
  prompt again with the page, when the model needs the rest, and nothing when it
  does not. Against that, every later call carries up to 27,232 bytes less, until a
  compaction summarises the result away; in #407's dear run, four calls. Offline,
  `cut_output`, whose script does read the rest back, sends 39,649 tokens (four bytes
  each, 772) over its three calls where it sent 46,422: the call with the page
  carries the whole result either way, and the call before it 27 kB less.
- **One default.** `grep`, `git_read`, `read_file`, `shell` and `web_fetch` each kept
  a copy of 60,000 for a context with no config; they read `%Config{}`'s now, so the
  next move is one line. The key table says `read_output` pages the rest back, where
  it said the rest is kept as a blob.
