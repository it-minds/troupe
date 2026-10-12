---
number: 877
title: "The desktop app draws a turn in frames from docs/design/frames.md, its answer from marked's tokens as elements with raw HTML as text; quiet by default from `transcript.detail`, a click on the strip opens the turn, `/detail` sets it for a session; reasoning it saw stream is kept live only; a curtain line says what runs"
date: 2026-10-12
status: accepted
issue: 474
paths:
  - clients/gui/apps/desktop/src/frames.ts
  - clients/gui/apps/desktop/src/views/Frames.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/src/tokens.css
  - clients/gui/apps/desktop/package.json
  - clients/gui/scripts/tokens.ts
  - clients/gui/scripts/fake-deployment.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/apps/desktop/test/frames.test.tsx
  - docs/design/frames.md
symbols:
  - layout
  - curtainLine
  - Markdown
  - ProseFrame
gist: "Frames per frames.md; Markdown from marked's lexer tokens to elements, raw HTML as text, never innerHTML; quiet by default; strip click opens a turn; reasoning live only"
---

Issue #474, slice 1, the desktop app's half: the frames TUI Decision 161 drew in the
terminal, built from the same page, `docs/design/frames.md`. The maintainer's word on the
issue ("Collapsed by default, and a curtain line while it works") settles how much is open.

**The parser: marked's lexer, drawn as elements.** The regex renderer could not do tables
or nested lists, two of the three things a model writes most. `marked` (MIT, no
dependencies, about 46 KB) is a GFM parser whose lexer hands back a token tree; the app
draws each token as a React element and never asks marked for HTML, so no reply reaches
`innerHTML`. Raw HTML, block or inline, is a token like any other, and it is drawn as the
text it is: disallowed, not sanitised, with no sanitiser to keep current and nothing a
reply can make the page load or run. An image is drawn as written and never loaded; a link
is an anchor only to `http` or `https`, and anything else is its words. Not chosen:
`markdown-it` (five dependencies, a flat token stream, HTML out by default),
`react-markdown` (the unified stack, some forty packages for the same tokens) and
`micromark` with its GFM extensions (a dozen packages). Footnotes are left as written,
as the terminal leaves them. Mermaid is drawn as a code frame of its source in this slice;
a diagram is a dependency of its own and the page's §9 says so. The version is held at
`~18.0.14`, three weeks old when this was written, and `scripts/licences.exs` records it.

**The frames.** `frames.ts` works out, from the transcript, the level and the time, what
the page says a turn is: its turns (from a person's line or a loop's iteration to the
line that says what it cost), what each entry is to its turn (the answer is the root's
prose after its last call; the working is reasoning, the calls and the prose between
them), the strip, every header's grammar and the curtain line's set. `Frames.tsx` only
draws: prose on the rendered surface with no header but the toggle to its source; a fenced
block a frame of its own inside it on the same surface, between rules, no second step; a
call with its header on the chat (`✓ read_file lib/p.ex · 3 lines · 2s`) and its result
under it, a file read as numbered source and the arguments under the result, open at
`everything`; reasoning as `thinking · 12s` over its text. The surface is `--bg-sunken`
behind a hairline, as the page says. In Afterglow's dark mode `--bg-sunken` is the canvas
itself, so there the hairline carries the step alone, as the terminal's rail does with
sixteen colours; the design's tokens are not this slice's to change.

**Colours by role only.** A label, a heading and a list marker take the page's accent
role: `border.focus`, except where that is the reserved colour (Limelight's lime), where
it is `text.link`. A component may not branch on a theme, so `pnpm tokens` generates
`--frame-accent` by that rule for every theme and mode, the choice `mix troupe.palette`
makes for the terminal from the same files; no theme file changed. A test reads the
stylesheet's frames section and fails on a colour that is not a token.

**Where it differs from the terminal, and why.** The desktop app's transcript is one
stream that holds a subagent's calls and words beside its parent's, where the terminal
gives each agent a pane. A subagent's words and calls are the working of the turn they
fall in, and the strip counts every call it stands for, theirs too: a strip that hid
calls it did not count would say less than it covers. A table cell wraps instead of being
cut at 32 columns, and a table wider than its frame scrolls inside it: a window can wrap a
column, which is why the terminal cuts. A long body opens in place by itself with a press
on `… 22 more lines`, as well as with its turn.

**How much is open.** `transcript.detail` is read from `config.get` for the session's
workspace, which answers it from every layer of the ladder, and again on `config.changed`
for a `transcript` key; with no daemon to ask, or one from before the key, it is quiet.
`/detail <level>` in the palette sets it for that session for as long as the app runs, by
daemon connection and session, and writes nothing to the log or a file; `/detail` alone
says which level and where it came from. Another level draws the history again. A click
on the strip opens its turn as `everything` draws it and a second shuts it; at
`everything` a click shuts the turn to quiet, as the terminal's `e` does. Never shut: a
failed call (its error in its header and its body), an approval or a question (their
panels, in the reserved colour, as before), the cost line, and every entry from the first
budget stop on, which is drawn as `everything` with no strip to stand for it. A scratchpad
document stays its card.

**Reasoning is live only**, as in the terminal (TUI Decision 36), and this slice keeps it
so. The fold keeps the reasoning it saw stream as an entry where the reply it came before
lands, with how long it streamed by this client's clock (`fold` takes the time an event
arrived, which only ephemerals read). A session opened afterwards has none: its log's
replies carry their reasoning blocks (Decision 658), and drawing those is a question for
both clients together, not this slice.

**The curtain line** is the page's §7 under the turn while the root agent works: the
turning mark, a flourish from the written set chosen by how many times this turn it has
thought, called or compacted (counted in the fold from `agent_state`, and started again by
each turn), then the facts, which are always there: `thinking (00:12)`, `running read_file
a.ex`, `running 3 tools: …`. Waiting on a person is `waiting for you` in the reserved
colour and nothing else. At rest after a model error there is no line; the error's note
says it. The line is not read out as it ticks.

**Proof.** `apps/desktop/test/frames.test.tsx`, against the fake daemon: the reproduction
(a turn with streamed reasoning, four calls of which one fails, and an answer with a
table, a nested list and a fenced block), which on the chunk's tip drew every call as a
line of its own, no strip, and the table as pipes, `**last**` with its stars and the fence
as inline code; the levels from a project's file, `/detail` and the history drawn again;
a click on the strip; durations from the events' times; a budget stop, an approval and a
question; long frames cut and opened in place, and the card; raw HTML as text and nothing
loaded; the source toggle; diff and data fences; the curtain line's order, its reset, its
end and waiting; and the colours. `packages/client/test/transcript.test.ts` covers the
reasoning entry, the calls' times and the curtain's phases in the fold.
