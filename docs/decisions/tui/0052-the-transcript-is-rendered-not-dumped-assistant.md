---
number: 52
title: "The transcript is rendered, not dumped: assistant messages are markdown, code is syntax-highlighted, and a file read is shown as numbered source"
date: 2026-09-11
status: accepted
paths:
  - clients/tui/test/troupe/transcript_rows_test.exs
gist: "The transcript is rendered, not dumped: assistant messages are markdown, code is syntax-highlighted, and a file read is shown as numbered source"
---

A line is no longer a string but a kind plus tagged segments, so a row can carry several styles and the markers (`` ` ``, `**`, `#`, `-`) are dropped instead of taking up columns. Fenced blocks get a rule above and below with the language on it, a `│` rail, and syntect highlighting through `ExRatatui.CodeBlock.highlight/3`; `read_file` output is split on its eight-column number gutter so the numbers sit in their own dim column and the code keeps its own indentation. Highlighting costs about 0.04 ms a line, so it happens once, where the event is folded, and only up to 400 lines a block — past that the text still gets its gutter and rail, just no colour. Everything a frame needs is therefore precomputed: the per-frame path measures bytes and slices the rows in view (0.2 ms for a thousand-line body). Text that is still streaming stays plain, because it changes on every frame and becomes markdown the moment the message lands. A line may also carry a `:fill` segment, which stretches to the end of the row when it is drawn, so a rule fits any width without the model knowing it.
