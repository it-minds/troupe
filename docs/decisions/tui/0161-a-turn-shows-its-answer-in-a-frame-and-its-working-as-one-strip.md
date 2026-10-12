---
number: 161
title: "A turn shows its answer in a prose frame on the rendered surface and its working as one strip above it; `transcript.detail` (quiet, tools, everything) and `e` open what quiet shuts; a failed call, an ask and what follows a budget stop are never shut; a curtain line says what runs"
date: 2026-10-12
status: accepted
issue: 474
paths:
  - docs/design/frames.md
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/theme.ex
  - clients/tui/lib/troupe/ui/tui/palette.ex
  - clients/tui/lib/mix/tasks/troupe.palette.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - clients/tui/test/troupe/frames_test.exs
symbols:
  - Troupe.UI.TUI.Model.transcript_blocks/3
  - Troupe.UI.TUI.Model.curtain_line/4
  - Troupe.UI.TUI.Model.markdown/1
  - Troupe.UI.TUI.View.turn_in_view/1
  - Troupe.UI.TUI.Theme.on_surface/1
gist: "Quiet by default: answer framed on the surface, working one strip; e opens a turn; failed calls, asks, budget stops stay open; flourish only in the pane"
---

Issue #474, slice 1: the shared design document, `docs/design/frames.md`, and the
terminal's half of it. The maintainer's word on the issue ("Collapsed by default, and a
curtain line while it works") settles how much is open; the issue's body settles what a
frame is. The desktop app builds its half from the same page in the next slice. #228 is
closed by TUI Decisions 126 and 149, and the frames take their colours from those roles.

**One frame, six kinds.** Prose, code, diff, tool, reasoning and data, each with the header
grammar the design page writes down (`┌─ elixir · lib/p.ex`, `diff · path +n −m`,
`✓ shell mix test · 1 test · 7s`, `thinking · 12s`, `csv · 4 rows`; prose has none). A tool
call's entry keeps the times its events carried (`started_at`, `ended_at`), and a reasoning
entry how long the reasoning streamed, for the durations; a log replayed has no deltas and
says `thinking` alone.

**Reasoning reaches its frame.** Reasoning is live only (TUI Decision 36): the fold keeps
it when the message it came before lands. The link coalesces deltas per frame, and it
joined a frame's reasoning and text into one delta that was reasoning only when all of
it was, so a model that thought and began to answer within one frame — the scripted model
always, a real one at the seam — had its reasoning streamed as its answer and never
drawn as reasoning. Each run of reasoning and each run of text in a frame is now flushed
as its own delta, in order.

**The surface.** The view paints one background, a frame's: the new `surface` role, the
theme's `bg.hover` token, generated like every role (`mix troupe.palette`), drawn out to
the column before the scrollbar's. Of the background tokens hover is the one that steps
away from both a dark terminal's black and a light one's white in all four themes, and a
terminal's own background is unknown; the desktop app's `bg.sunken` assumes a canvas the
terminal does not have. With sixteen colours there is no honest step and with none no
colour, so the role has no stand-in there and the frame's rail, `▎`, carries it. The rail
is drawn at every depth: a frame takes the same rows and columns whatever the terminal can
colour, so scrolling, selecting and what is copied never depend on it, and copying drops
it as it drops every rail. This is the one exception to TUI Decision 126's "the canvas is
not painted": the canvas still is not. Nesting is one level: a fenced block inside prose is
a frame of its own between rules on the prose's surface, never a second step.

**Turns, and what quiet shuts.** A transcript is read as turns: one starts at a person's
line, a command they ran or a loop's iteration, and ends at the line that says what it
cost. The turn's answer is its prose after its last call (a `finish` aside); its working
is its reasoning, its calls and the prose between them. Quiet draws the working as one
strip where it began — `▸ 7 steps · 1 failed · grep, read_file, edit_file · 14s` — and
the answer as a prose frame; `tools` opens the call frames under a `▾` strip and keeps
reasoning to its header; `everything` collapses nothing. The prose between calls is
working, not answer: a model that narrates each call would otherwise give a turn of thirty
calls thirty strips, which is the scroll past thirty frames the issue is about. The
cost line stays where TUI Decision 160 puts it, but is no longer taken out of the
transcript before it is drawn: it ends a turn, so the pane draws it as nothing where the
side box says it, and keeps the transcript whole.

**The setting and the key.** `transcript.detail` is a key on the config ladder (`quiet`,
`tools`, `everything`; `quiet` by default), labelled for the settings page as a menu of the
three, read with the theme and again on `config.changed`. `/detail <level>` sets this
screen's own level for the session, outranking the setting until the session changes;
nothing reaches the log or a file, and the history is drawn again from the fold. `e` opens
the turn in view — the last while the pane follows the tail, otherwise the one at the top
of the view, which stays where it is — as `everything` draws it, and closes it again; at
`everything` it closes it to quiet. Per turn rather than the whole pane, because "one key
opens the whole turn" is the issue's word, and opening thirty turns to read one is the
flood quiet exists to stop. Not chosen: a click on the strip, which the desktop app does,
and which the TUI's mouse handling could take later.

**Never shut**, at any level: a failed call, its frame open with its error; an approval or
a question, drawn as before, whole, in the reserved colour and with no flourish; the cost
line; and everything after a budget stop — the agent's transcript remembers where its
first budget question or `budget exhausted` landed (`open_from`) and draws all after it as
`everything`. A scratchpad document stays a card (TUI Decision 159). A frame body past 24
lines shows its first 20 and `… n more lines`, opened in place with its turn; the answer's
prose is never cut, only a block inside it.

**The curtain line.** The activity line of TUI Decision 36 keeps every fact and gains a
prefix in the pane: `◐ the actors are powdering their nose — thinking (00:12)`. The set is
small and written in the design page and in `Model`'s one table; the n-th time the
window's own agent thinks, calls or compacts in a turn takes the n-th line of that list,
and past its end the line is the facts alone, so nothing repeats in a turn, and each turn
starts the lists again. Reads have their own list. The facts now say how many when several
calls run (`running 3 tools: …`). No flourish when the window waits on a person, after a
model error, or in a subagent's pane; and none outside the pane — a tile is a glance, and
the headless printer, `troupe bench` and `--json` never drew this line at all.

**Markdown** gains pipe tables (header bold over a rule, columns aligned as the rule says,
a cell past 32 columns cut with `…`) and nested lists (two columns a level, `•` `◦` `▪`,
and a wrapped item's rows under its text), and fenced `diff`, `csv`, `tsv` and `json`
become their frames. A table wider than 100 columns is shown as written under a line that
says so; raw HTML, images and footnotes are left as written.

**Not in this slice**, as #474 and the brief say: tree-sitter grammars a person installs
(a later slice of #474); the viewer (#61), where a frame past 500 lines will open; and the
desktop app's half, which builds from `docs/design/frames.md`.

**Proof.** `test/troupe/frames_test.exs`: the reproduction (a turn with reasoning, four
calls, one failed, and an answer with a table, a nested list and a fenced block, drawn
quiet: one strip above the answer, the failed call open, the answer on the surface out to
its edge, a person's line not), which failed on the chunk's tip with every call and the
reasoning on a line of their own, no strip and no surface; the surface at truecolor and
256, none with sixteen colours and the rail and rules still there, and no colour at all
under `NO_COLOR` with the frames still reading; `tools` and `everything`; `e` opening and
closing a turn, and closing one at `everything`; the level drawing every turn again with
the fold unchanged; a long frame cut and opened in place; a budget stop, an approval and a
scratchpad card; tables, nested lists, data and diff fences, a table too wide; the curtain
line's prefix, its facts, its order within a turn and its start again, and no flourish
where there must be none, in a tile or from the headless printer; and against the daemon,
`e`, `/detail` and the log unchanged, reasoning streamed in the frame its answer starts in
drawn as reasoning (on the tip it arrived as the answer's first words), and
`transcript.detail` from a project's file.
`transcript_rows_test.exs`, `tui_theme_test.exs` and the rest of the suite updated to the
frames.
