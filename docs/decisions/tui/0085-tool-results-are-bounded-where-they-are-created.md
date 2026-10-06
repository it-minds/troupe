---
number: 85
title: Tool results are bounded where they are created, never afterwards, and every omission names the call that returns it
date: 2026-09-17
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
gist: Tool results are bounded where they are created, never afterwards, and every omission names the call that returns it
---

Shrinking a result already in history would be the cheapest-looking fix and the worst one: it rewrites a message, which invalidates the cache from that point on and re-bills everything after it. So `Troupe.Tool.Bound` is applied at ingestion — a command keeps its first 60 and last 140 lines because failures and summaries come last, a file read a 250-line window, a listing or a search 50 items, a JSON document its arrays trimmed at element boundaries, and 30 000 characters is the backstop for the minified-file-on-one-line case. Everything is sanitized first: ANSI escapes out and invalid UTF-8 replaced, because `Jason.encode!/1` raises on invalid UTF-8 and one binary file in a tool result would otherwise take the turn down; for the same reason every cut is on a line or grapheme boundary and never `binary_part/3`. Nothing is stranded. A file read, a listing and a search are idempotent, so their markers name the same tool at the next offset; a command and a fetch are not, so the full text goes to `Session.Outputs` under the session directory and the marker names a `read_output` call — the agent never re-runs a test suite to see the line that was cut. `Tool.Runner` and `Agent.Server.complete/4` apply the sanitize-and-cap backstop to every path, including inline tools and subagent summaries, so nothing unbounded or unencodable can reach a message. `shell` now leads with its exit code on success as well as failure, so the status survives a head-and-tail cut.
