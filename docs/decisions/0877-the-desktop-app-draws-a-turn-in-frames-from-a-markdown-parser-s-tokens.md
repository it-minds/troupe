---
number: 877
title: "The desktop app draws a turn in frames from docs/design/frames.md, its answer from marked's tokens as elements with raw HTML as text; quiet by default from `transcript.detail`, a click on the strip opens the turn, `/detail` sets it for a session; reasoning it saw stream is kept live only; a curtain line says what runs"
date: 2026-10-12
status: accepted
issue: 474
paths:
  - clients/gui/apps/desktop/src/frames.ts
  - clients/gui/apps/desktop/src/views/Frames.tsx
symbols:
  - layout
  - curtainLine
  - Markdown
  - ProseFrame
gist: "Frames per frames.md; Markdown from marked's lexer tokens to elements, raw HTML as text, never innerHTML; quiet by default; strip click opens a turn; reasoning live only"
---

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
`micromark` with its GFM extensions (a dozen packages). Mermaid is drawn as a code frame
of its source in this slice; a diagram is a dependency of its own and the page's §9 says
so.

**Colours by role only.** A label, a heading and a list marker take the page's accent
role: `border.focus`, except where that is the reserved colour (Limelight's lime), where
it is `text.link`. A component may not branch on a theme, so `pnpm tokens` generates
`--frame-accent` by that rule for every theme and mode, the choice `mix troupe.palette`
makes for the terminal from the same files; no theme file changed.

**Where it differs from the terminal, and why.** The desktop app's transcript is one
stream that holds a subagent's calls and words beside its parent's, where the terminal
gives each agent a pane. A subagent's words and calls are the working of the turn they
fall in, and the strip counts every call it stands for, theirs too: a strip that hid calls
it did not count would say less than it covers. A table cell wraps instead of being cut at
32 columns, and a table wider than its frame scrolls inside it: a window can wrap a
column, which is why the terminal cuts.

**How much is open.** `transcript.detail` is read from `config.get` for the session's
workspace, which answers it from every layer of the ladder, and again on `config.changed`
for a `transcript` key; with no daemon to ask, or one from before the key, it is quiet.
Another level draws the history again. A click on the strip opens its turn as `everything`
draws it and a second shuts it; at `everything` a click shuts the turn to quiet, as the
terminal's `e` does. Never shut: a failed call (its error in its header and its body), an
approval or a question (their panels, in the reserved colour, as before), the cost line,
and every entry from the first budget stop on, which is drawn as `everything` with no
strip to stand for it. A scratchpad document stays its card.

**Reasoning is live only**, as in the terminal (TUI Decision 36), and this slice keeps it
so. The fold keeps the reasoning it saw stream as an entry where the reply it came before
lands, with how long it streamed by this client's clock (`fold` takes the time an event
arrived, which only ephemerals read). A session opened afterwards has none: its log's
replies carry their reasoning blocks (Decision 658), and drawing those is a question for
both clients together, not this slice.
