---
number: 650
title: What a tool had to cut is kept, and the marker says how to read the rest
date: 2026-09-20
status: accepted
paths:
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tools/output.ex
  - apps/troupe_core/lib/troupe/tools/read_output.ex
  - apps/troupe_core/test/troupe/tools/read_output_test.exs
gist: What a tool had to cut is kept, and the marker says how to read the rest
---

A
capped `shell` or `grep` result that threw the rest away would send the model to
run a test suite again to see line 900 of it. The full text goes into
`Troupe.Session.Blobs`, the content-addressed per-session store every oversized
event payload goes into, rather than into a second store: a cut result's full text
becomes a blob, its `sha256:` digest is the id, and the marker names the
`read_output` call with the line to resume from (after the kept head for `grep`,
line 1 for `shell`, whose kept part is the tail). The id is a digest the store
validates, so a path is never built from anything the model typed, and the blob
lives and dies with the session like the rest of its history. `read_file` is not
kept: reading again with the next offset returns the same bytes, and a store for
that would be a copy of the file.
