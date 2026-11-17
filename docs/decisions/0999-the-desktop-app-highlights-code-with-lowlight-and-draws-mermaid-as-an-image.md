---
number: 999
title: "The desktop app highlights a code frame with lowlight from a built-in set of highlight.js grammars, loaded on first use, in the palette's roles; draws a Mermaid fence with Mermaid 11 at securityLevel strict as an SVG image; gives Afterglow dark's frame surface a step; sets transcript.detail on Appearance; and both clients draw a replayed reply's reasoning from the log"
date: 2026-11-15
status: accepted
issue: 659
supersedes: [877]
paths:
  - clients/gui/apps/desktop/src/highlight.ts
  - clients/gui/apps/desktop/src/grammars.ts
  - clients/gui/apps/desktop/src/diagram.ts
  - clients/gui/apps/desktop/src/views/Frames.tsx
  - clients/gui/apps/desktop/src/views/Appearance.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/package.json
  - clients/gui/docs/design/themes/afterglow.tokens.json
  - clients/gui/packages/client/src/transcript.ts
symbols:
  - useHighlight
  - drawMermaid
  - TranscriptDetail
gist: "Desktop code highlighted by lowlight, lazily, in palette roles; Mermaid 11 strict, shown as an <img>; Afterglow dark sunken #06060B; transcript.detail on Appearance; replayed reasoning drawn from the log"
---

Issue #659's desktop items, what #474 left. Decision 877 kept Mermaid as source, left the
design's tokens alone and kept reasoning live; this supersedes those three sentences of it.
The terminal's half of reasoning on replay is TUI Decision 174.

**The highlighter: lowlight, with highlight.js's grammars.** A coding agent writes
TypeScript and TSX, JavaScript, Python, Elixir, Rust, Go, JSON, YAML, shell, SQL, HTML,
CSS, Markdown and diffs; highlight.js has a grammar for each (TOML and Dockerfiles are
added for little), and lowlight runs them and hands back a syntax tree rather than HTML,
so a highlighted line is drawn as elements like the rest of a reply (877: nothing reaches
`innerHTML`). The seventeen grammars and the engine are one chunk, 75 KB (25 KB
compressed), loaded the first time a frame has a language, never on first paint: a frame
is drawn as written and highlighted when the chunk is in. Both are BSD-3-Clause and MIT,
with lowlight's two small dependencies. Not chosen: Shiki, whose TextMate grammars match
the terminal's syntect best but weigh hundreds of kilobytes a language (TSX alone) and
need Oniguruma as WASM or a regex translation; Prism, whose languages register themselves
on a global and which is in maintenance; refractor, Prism under a tree, with more
dependencies than lowlight for older grammars. The language is the fence's first word
(`exs`, `toml` and `console` mapped to their grammars); a fence with none, or with one the
set lacks, stays as written. A file a call read is highlighted by its extension, as the
terminal does. Past 2,000 lines a block stays as written; the terminal's cap is 400 at
syntect's cost per line, and highlight.js runs after paint.

**Colours by role.** A token's kind maps to a role, never to a highlighter theme: keyword,
tag and heading the frame accent, as a label; a name being defined the primary ink;
strings, numbers and types the person palette's third, second and fifth hues, which no
theme gives the reserved colour and which clear 4.5:1 on every theme's surface in both
modes (the test computes it from the theme files); comments and punctuation muted; a
diff's added and removed lines their colours. The terminal takes syntect's colours at
truecolor (TUI Decision 126), so the two clients agree on what is highlighted and from
which fence, not on the hue.

**Mermaid.** Mermaid 11.17, loaded the first time a reply has a `mermaid` fence, at
`securityLevel: 'strict'` with HTML labels off, its colours the frame's roles read where
the frame sits and drawn again when the theme changes. What it draws is shown as an SVG
image, never put into the page: an image runs no script and loads nothing, whatever the
SVG holds, which is the sandbox frames.md asks of anything that runs; labels are set in a
system face so the image draws them in the face they were measured in. A fence that does
not parse is its source with one line, `This diagram did not draw:` and the parser's first
words; one that draws has a toggle to its source. A streaming fence is drawn once it has
stood still for 300 ms. Mermaid 12 is not taken: it depends on `elkjs`, under EPL-2.0 or
GPL-3.0, which the licence policy refuses without review, for a layout this does not use.
The terminal shows Mermaid as source, as it must.

**Afterglow dark's surface.** `bg.sunken` was the canvas's own `#0B0B12`, so a frame showed
by its hairline alone. It is `#06060B` now, a step below the void as every other dark
theme's sunken is below its canvas; muted text on it is 4.91:1, which also lifts it over
the 4.9 floor it missed on the canvas (4.77), and nothing else on it loses contrast.

**`transcript.detail` in the settings.** On Appearance, beside notifications, where the
settings that are yours and change nothing anyone else sees are: the three levels in the
terminal's words, `quiet`, `tools`, `everything`, each saying what it draws, written to
your own settings with `config.set`, which the terminal reads too; a line says when your
organisation or the environment chooses over you. It is there only where the daemon keeps
settings.

**Reasoning on replay.** A reply's reasoning is logged as a block of its own in
`llm_response.message` (Decision 658). When nothing streamed, the fold draws the reasoning
frame from those blocks, the root agent's only as live, a redacted or empty one left out,
with `thinking` and no time, since the log says when the reply landed, not when the
thinking began. What streamed wins: it carries its duration.

**Left.** Tree-sitter grammars a person installs (the spike first: their cost per line in
WASM against syntect's and highlight.js's, in both clients); the viewer hand-off past 500
lines, which is #61's.

**Proof.** `apps/desktop/test/code-frames.test.tsx`: a reply with TypeScript, Elixir, a
bare fence and an unknown language (highlighted, highlighted, as written, as written), a
file read highlighted by its extension, the roles and their contrast, a bad Mermaid
diagram against Mermaid itself, a replayed reasoning frame, the Appearance control writing
`transcript.detail`, and the surface a step from the canvas in every theme.
`apps/desktop/test/diagram.test.tsx`, with Mermaid stood in for since jsdom lays nothing
out: strict, the roles' colours, an image and no SVG in the page, the toggle.
`packages/client/test/transcript.test.ts`: the replayed entry and what is left out. Each
failed on the branch's base.
