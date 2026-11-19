---
number: 177
title: "/profile <name> and troupe profiles lead with the sentence a bundle's author wrote, put a server's subtitle under its name and, once any of its tools has a line, a row per tool: the line cut to the width, the tool's name after it in the dim face, a bare name where there is none; a profile without about reads as before"
date: 2026-11-19
status: accepted
issue: 1135
paths:
  - clients/tui/lib/troupe/ui/profile_view.ex
  - clients/tui/lib/troupe/ui/tui/profiles_page.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
gist: "Profile page: about.summary first (folds), server subtitle under its head (folds), a row per tool once any has a line (line cut with …, name after it dim; bare name else; 'and all of its other tools' for all); no about = as before"
---

Issue #1135. `profile.get` now carries what a bundle's author wrote (`about`, root decision
1063); the page of Decision 171 listed bare tool names and no sentence.

**The sentence** is the page's first row, before Agents, a blank after it; the frame folds
it at the width as it folds any row. `troupe profiles NAME` prints it right under the
`profile NAME` line in place of the blank.

**A server's subtitle** is the row under its `name · host · access · asked` head, indented
as its tools are, folded the same way.

**A row per tool** once the author has written a line for any of the server's tools: the
line, two spaces, then the tool's name, drawn in the dim face the page uses for what is
quieter. The line is cut with `…` so the name stays on the row at any width; a tool without
a line is its bare name on its own row. On an open allowlist (`all`) the described tools
come first, by name, then *and all of its other tools*. A server none of whose tools has a
line keeps the wrapped `tools: a, b, c` row, and a profile with no `about` reads exactly as
before. A line kind of its own, `{:tool, line, name}`, carries the two faces; the plain
lines join it with the same two spaces.

## Not chosen

- **Folding a long tool line.** The name would land alone on the next row, read as a tool
  of its own; the name is what a reader looks for, so the line gives way.
- **The name first.** The author's line is the reader's word for the tool; the name is the
  reference, as on the desktop page (root decision 1070).
- **Rows per tool without any line.** The page would grow by a row per tool for nothing it
  did not already say.

## What breaks if undone

The page shows bare names again and the author's words are only on the desktop; a cut
removed, a long line pushes its name out of the frame.
