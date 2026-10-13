---
number: 896
title: "An upload lands in session:/, the directory the session works in, which for a local session is the checkout, and says so; a path whose prefix names no mount is refused with the prefixes there are"
date: 2026-10-13
status: accepted
issue: 620
paths:
  - apps/troupe_core/lib/troupe/mounts.ex
  - apps/troupe_core/lib/troupe/workspace.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - docs/user/cli-reference.md
gist: "fs.upload writes to session:/, the checkout in a local session (documented, not moved); a word: prefix that is no mount is refused, not made a directory"
---

#620 found two things beside each other. `/upload` and `fs.upload` said a file went into
"the session's own mount", and for a session on a pod that is true: `session:/` is the
session's own directory, erased with it. For a local session `session:/` is the person's
checkout, so an uploaded file lands in the working tree, where `git add -A` picks it up,
another session in the same checkout sees it, and erasing the session leaves it. And a
path with a prefix that is no mount (`scratch:/plan.md` before the scratchpad existed, or
`plans:/plan.md`) was taken as a relative path, which on Linux wrote a directory literally
named `plans:`.

**Kept in the checkout, and said.** The choice was between that and a session-private
area, as the scratchpad's documents have (Decision 870). The private area loses: an upload
is a file the person hands the session to work with, and the session works in
`session:/`; a file elsewhere would be one the agent's file tools and its commands reach by
another name, and for a local session the person's file was already on the same machine.
What was wrong was the sentence, not the place. So `/upload`'s help (and with it the command
reference, which is written from the same table) and PROTOCOL.md's `fs.upload` say where the
file lands for each kind of session, and what that means in a checkout. A file the person
does not want in the checkout is one they do not upload to a local session.

**An unknown prefix is refused.** A path that begins with a word of two or more letters,
digits, dashes or underscores, then a colon, then a slash or nothing, is a prefix. One
that names none of `session:`, `team:<name>`, `org:`, `skills:` and `scratch:` is
`{:unknown_mount, word}`, and the sentence names the ones there are. It is refused in
`Troupe.Mounts`, so `fs.upload`, `fs.read`, `fs.list` and every file tool refuse it alike.
A colon later in a name (`notes:2026.md`) and a Windows drive letter (`C:/`) are not
prefixes, and resolve as they did.

**Proof.** `mounts_test.exs` (an unknown prefix refused with the sentence; a colon in a
name and a drive letter not taken for one) and `files_test.exs` (`fs.upload` to
`plans:/plan.md` is `forbidden`, names `session:/` and `scratch:/`, and writes nothing).
