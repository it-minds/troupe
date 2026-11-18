---
number: 161
title: "A turn shows its answer in a prose frame on the rendered surface and its working as one strip above it; `transcript.detail` (quiet, tools, everything) and `e` open what quiet shuts; a failed call, an ask and what follows a budget stop are never shut; a curtain line says what runs"
date: 2026-10-12
status: accepted
issue: 474
paths:
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/theme.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
symbols:
  - Troupe.UI.TUI.Model.transcript_blocks/3
  - Troupe.UI.TUI.Model.curtain_line/4
  - Troupe.UI.TUI.Model.markdown/1
  - Troupe.UI.TUI.View.turn_in_view/1
  - Troupe.UI.TUI.Theme.on_surface/1
gist: "Quiet by default: answer framed on the surface, working one strip; e opens a turn; failed calls, asks, budget stops stay open; flourish only in the pane"
---

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
