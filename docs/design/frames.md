# Frames — rendered output in both clients

How a transcript shows what was rendered from something: the model's prose, a code
block, a diff, a tool call and what it returned, reasoning, data. One vocabulary, two
implementations: the terminal UI builds it from this page (TUI Decision 161), and so does
the desktop app (Decision 877). Issue #474 is the why; this is the what.

A turn shows its answer, not its working. Everything else on this page serves that.

---

## 1. A frame

A frame is a **header**, a **body** and its **affordances**.

- The header says what this is and one fact about it, on one line.
- The body is the rendered content, on the **surface** (§3).
- The affordances are copy, open or close, and, where it applies, open in the viewer
  (#61, not built yet) or in the scratchpad (#472).

## 2. The six kinds

| kind | what it holds | header | body |
|---|---|---|---|
| **prose** | the model's Markdown: the answer, and the prose between its calls | none | the Markdown, rendered |
| **code** | a fenced block, or a file a call read | language, then `· path` when known | highlighted source; line numbers when it came from a file |
| **diff** | a fenced `diff`, or the edit a call made or asks to make | `diff · path +n −m` | added and removed lines in their colours |
| **tool** | one call and what came back | glyph, name, target, `· outcome`, `· duration` | the result |
| **reasoning** | what the model thought before it answered | `thinking · duration` | dim, in the reader's ink |
| **data** | a fenced `json`, `csv` or `tsv` | `json · n rows`, `csv · n rows` | a table when it parses as one, the source when it does not |

### Header grammar

The parts are separated by ` · ` (space, middle dot, space). Counts are words, not
symbols: `1 row`, `2 rows`, `1 step`, `7 steps`. The minus in `+n −m` is U+2212.

- **code**: `elixir · lib/p.ex`. The language is the fence's first word, the path its
  second word when that has a `/` or a `.` in it. With neither, the label is `code`.
- **diff**: `diff · lib/p.ex +3 −1`. The path is the fence's, else the `+++` line's with
  its `b/` taken off. `+n` counts the added lines and `−m` the removed, the `+++` and
  `---` lines aside.
- **tool**: `✓ read_file lib/p.ex · 120 lines · 2s`. The glyph is `✓` done, `✗` failed,
  `⋯` running. The target is what the call is about: the path, the command, the URL, the
  agent delegated to. The outcome is a few words: `120 lines`, `+3 −1`, the first line of
  an error with `(n lines)` when it has more. The duration is said from one second up;
  under a second it says nothing a person reads for.
- **reasoning**: `thinking · 12s`, from the first reasoning the model streamed to its
  reply. A transcript replayed from the log has no duration, and says `thinking`.
- **data**: `csv · 4 rows`, the header row not counted; `json · 2 rows` for an array of
  flat objects, whose columns are the keys in the order they first appear.
- **prose** has no header. It is the frame read most, and it is recognised by its surface.
  In the desktop app the rendered/source toggle sits where the header would be.

Durations: `14s` under a minute, `4m 2s` from a minute.

## 3. The surface

**Three surfaces, and not more.**

| surface | what is on it | desktop app | terminal |
|---|---|---|---|
| the chat | notes, a turn's strip, the curtain line, a tool's header | the session's background | the terminal's own background |
| a person's turn | what a person typed, a command they ran | `--bg-panel` and a coloured left edge, as today | the `>` or `!` marker in the accent |
| rendered | every frame's body, and prose whole | `--bg-sunken` and a hairline border | the `surface` background and the frame's rail, `▎` |

**The step.** Rendered output sits one step from the chat's background, and the step reads
as rendered, not as important: nothing louder than a background and a hairline or a rail.

In the terminal the step is the `surface` role, the theme's `bg.hover` token: of the
background tokens it is the one that moves away from both a dark terminal's black and a
light one's white in every theme, which is what a terminal whose own background nobody
knows needs. It is drawn at truecolor and at 256 colours. With 16 colours, or none
(`NO_COLOR`), there is no background, and the rail and the rules carry the frame alone.
The rail is drawn at every depth, so a frame takes the same rows and columns whatever
the terminal can colour, and what a person selects or copies does not depend on it.
Copying leaves the rail out.

**Nesting: one level of surface.** A code, diff or data block inside prose is a frame of
its own — its own header between rules, `┌─ elixir ───` above and `└───` below, its own
rail — on the prose's surface, with no second step. A transcript must not turn into a
stack of boxes.

## 4. Collapsing

**The strip.** A turn's working — its reasoning, its calls, and the prose between its calls —
is one line where it began, above the answer:

```
▸ 7 steps · 1 failed · grep, read_file, edit_file · 14s
```

`n steps` counts the calls, `finish` aside, which says itself in the line under it. The
desktop app's transcript holds a subagent's calls beside its parent's, so its strip counts
every call it stands for, theirs too (Decision 877).
`· k failed` is there when one failed, in the error colour. Then the tools used, in the
order first used, four at most and `and n more`; then the time from the first call's start
to the last one's end, or to now while one runs. `▸` when the steps are shut, `▾` above
them when they are open.

**The answer** is the prose after the turn's last call. It is open at every level, and its
prose is never cut short: it is the thing the turn was for.

**`transcript.detail`** says how much is open, in three values:

| value | a turn draws |
|---|---|
| `quiet` (the default) | the strip, the answer, and what is never collapsed (§5) |
| `tools` | the strip open (`▾`), the prose between calls, each call's frame open with a long result cut short, reasoning as its header alone |
| `everything` | nothing collapsed: reasoning open, every result whole — what a bug report wants |

It is a key on the config ladder (`transcript.detail`, `quiet` by default), which a
person's file, a project's and an organisation's defaults set like any other, and a client
changes it for one session: the terminal UI's `/detail quiet | tools | everything`. The
view is a client's own business: switching re-draws the whole history at the new level,
and nothing is written to the session's log.

**One key opens the whole turn.** In the terminal, `e` opens every frame of the turn in
view — the last one while the pane follows the tail, the one at the top of the view when
it is scrolled — as `everything` draws it, and closes it again; at `everything` it closes
the turn to `quiet`. The entry at the top of the view stays where it is. In the desktop
app, a click on the strip does the same.

**Long frames.** A frame body past **24 lines** shows its first **20** and a line saying
the rest, `… 42 more lines`; opening the turn expands it in place. A code, diff or data
block inside prose is cut the same way; the prose around it is not. A person's own command
keeps its last 20 lines, `… 42 earlier lines`, because the end of a command's output is
what a person ran it to read. At `everything` nothing is cut.

**Past 500 lines** a frame is a card that opens the viewer (#61) instead of a body in the
transcript, as a scratchpad document is already a card that opens the scratchpad (TUI
Decision 159). Until the viewer exists, both clients cut such a frame as above.

## 5. Never collapsed

Whatever the level:

- **a failed call** — its frame opens itself, the error in its header and its body;
- **an approval or a question** — the session waits on a person, so it is drawn whole, in
  the reserved colour (Decisions tui/0126 and tui/0149), and is never a joke;
- **the turn's cost line**, where the client draws one;
- **anything after a budget stop** — from the moment a budget ran out, every entry after
  it is drawn as `everything` would draw it.

A scratchpad document stays a card at every level (TUI Decision 159).

## 6. Colour roles

From the generated palette (#228, Decisions tui/0126 and tui/0149), by role, never by
colour. The desktop app's tokens are named beside each.

| what | role (terminal) | token (both) |
|---|---|---|
| the rendered surface | `surface` | terminal `bg.hover`; desktop `bg.sunken` with `border.hairline` |
| the frame's rail, the rules, a table's lines, line numbers | `rail` | `border.strong` |
| a code or data label, a heading, a list marker | `accent` | `border.focus` (`text.link` in Limelight); desktop `--frame-accent`, generated so |
| a tool that worked | `ok` | `status.allowed.fg` |
| a tool that failed, the strip's `k failed` | `error` | `status.error.fg` |
| a tool running, the curtain line's facts | `working` | `status.running.fg` |
| added, removed, a hunk's header | `added`, `removed`, `hunk` | `diff.addedText`, `diff.removedText`, `diff.hunkHeader` |
| reasoning, the strip, `… n more lines`, the curtain's flourish | `muted` | `text.muted` |
| what waits on a person, and nothing else | `needs_you` | `status.waiting.fg` |

Highlighting takes its colours from the highlighter at truecolor, their nearest of 256 at
256, and the reader's ink with fewer (Decision tui/0126). A grammar a person installs maps
its captures to these roles too (a later slice of #474).

## 7. The curtain line

While a turn works, one line under it says what is happening. Two halves:

```
◐ the actors are powdering their nose — thinking (00:12)
◐ reading the script — running 3 tools: read_file a.ex, read_file b.ex, list_files lib (00:06)
◐ fetching props — running shell mix test (00:04)
waiting for you
```

**The facts are never optional.** What is running, how many, and for how long — always
there, always after the flourish, in the same place. Somebody debugging at 11pm must not
have to expand anything to learn that `shell` has been going for four minutes.

**The flourish is a prefix**, never a replacement, and the first thing to go where there
is less room: a window's tile in the terminal says the facts alone.

**The set is small and written down here.** By what the agent is doing, the n-th time it
does that in a turn takes the n-th line; past the end of a list the line is its facts
alone. So nothing repeats within a turn, and a new turn starts each list again.

| over | the lines, in order |
|---|---|
| starting | the house lights go down |
| thinking | the actors are powdering their nose · running lines in the wings · the prompter finds the page |
| calls that only read (`read_file`, `grep`, `glob`, `list_files`, `git_read`, `read_branch`, `read_output`, `recall`, `web_fetch`) | reading the script · checking the prompt book · rereading the second act |
| any other call | fetching props · shifting the scenery · the stagehands are at it |
| compacting the context | cutting the second act · trimming for time |

**The register is fixed**: theatre, dry, never sorry, never pretending to be a person.
A line is localisable, since the facts beside it are.

**No flourish** on what waits on a person (`waiting for you`, in the reserved colour), on
a model error, or in a subagent's own pane. **No curtain line at all** in a headless run,
`troupe bench`, CI logs, or anything with `--json`: those print the facts, and a
machine-readable surface with jokes in it is a bug. In the terminal the activated pane
draws it, and nothing else does; in the desktop app, the session's transcript, under the
turn.

## 8. Markdown

Prose is Markdown, rendered: headings, emphasis, inline code, quotes, rules, lists **nested
to any depth** (the marker changes with the depth, `•` `◦` `▪`, and a wrapped item lines
up under its text), **pipe tables** (the header bold over a rule, columns aligned as the
rule says, a cell past 32 columns cut with `…`), and the fenced blocks of §2.

What a client does not render, it says plainly rather than drawing badly. The terminal UI
leaves raw HTML, images and footnotes as written, and draws a table wider than 100 columns
as written under a line that says so. The desktop app disallows raw HTML rather than
sanitising it: it is shown as the text it is, and an image as written, never loaded. A
link goes where it says only over `http` or `https`. A table cell wraps rather than being
cut, and a table wider than its frame scrolls inside it. It has a rendered/source toggle
on a prose frame, which settles every "is the model's Markdown broken, or is ours?"
question (Decision 877).

## 9. Not here yet

- Tree-sitter grammars a person installs, and the WASM spike to measure them: a later
  slice of #474. The built-in highlighting stays as it is.
- Highlighting in the desktop app, whose code frames show their source in the reader's
  ink until that slice settles what highlights there.
- Mermaid drawn as a diagram in the desktop app; it is a code frame of its source for now.
- The viewer (#61), where a frame past 500 lines will open.
