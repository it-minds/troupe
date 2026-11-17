# Reading a transcript

A turn shows its answer, not its working. Everything rendered from something is a frame
on a surface of its own, a step from the chat: the model's prose, a code block, a diff, a
tool call and what came back, reasoning, data. What you typed keeps its own panel. By
default a turn's reasoning, its calls and the prose between them are one line where they
began, above the answer: `▸ 7 steps · 1 failed · grep, read_file, edit_file · 14s`. The
design both clients follow is [docs/design/frames.md](../design/frames.md), and the TUI's
own way of drawing it is [below](#in-the-terminal).

- **In the desktop app** a click on that line opens the whole turn, every frame in it, and
  another click shuts it. `/detail quiet`, `/detail tools` or `/detail everything` in the
  command palette changes how much of every turn is open in this session's window, and
  draws the history again: `tools` opens each call's frame, its result cut past 24 lines
  to its first 20 (a press on `… 42 more lines` shows the rest in place) and its reasoning
  to `▸ thinking · 12s`; `everything` collapses nothing, arguments included, which is what
  a bug report wants. Whatever the level, a call that failed is open with its error, an
  approval or a question waits in its panel, and everything after a budget ran out is open.
- **The answer** is rendered from its Markdown: headings, lists nested to any depth,
  tables, quotes, and each fenced block a frame of its own, code with its language and
  path, a `diff` with `+n −m`, and `csv`, `tsv` or `json` as a table with its row count.
  **source** at the top of an answer shows the Markdown as the model wrote it. Raw HTML in
  a reply is shown as text, never as markup, and an image is never loaded; a `mermaid` block is
  drawn as a diagram, its source a press away.
- **Reasoning** is what the model streamed before it answered, so it is there for a turn
  the app watched happen, and not in a session opened afterwards.
- **While a turn works**, the line under it says what is running, how many and for how
  long, after a few words from the theatre: `◐ reading the script — running read_file
  a.ex (00:06)`. The facts are always there; waiting on you, the line is `waiting for you`
  in the colour that means you.
- **The default** for every session is the `transcript.detail` setting (`quiet`, `tools`
  or `everything`), from your `config.yaml`, a repository's `.troupe/config.yaml` or your
  organisation's, as any setting. `/detail` changes it for one session and writes nothing;
  the session's log is the same at every level.

## In the terminal

In the terminal a frame is on a surface one step from the terminal's background, with a
rail, `▎`, down its left; what you typed and the notes between turns are not on it. By
default (`quiet`) a turn reads:

```
> fix the failing test
▸ 7 steps · 1 failed · grep, read_file, edit_file · 14s
✗ read_file nope · no such file: nope · 2s
▎ ## Fixed
▎ The parser keeps the last line now.
```

`e` opens the turn you are reading (the last one while the pane follows the tail, the one
at the top of the view when you have scrolled) as `everything` draws it, and `e` again
closes it. `/detail quiet`, `/detail tools` or `/detail everything` sets how much of every
turn is open on this session's screen and draws the history again: `tools` opens each
call's frame and keeps reasoning to its header (`▸ thinking · 12s`), `everything`
collapses nothing. A frame longer than 24 lines shows its first 20 and `… 42 more lines`,
and opening its turn shows the rest in place; a scratchpad document stays a card that
`/scratch` opens.

An agent's finish is a `done:` note, its report's parts under it. Its `changed:` line is Troupe's count
of what the agent's file tools wrote: the files and the lines each added and removed, and what its shell commands changed as not counted. The desktop app shows the same count as the finish frame's `changed`.

Replies are rendered as in the desktop app, with these of the terminal's own: nested lists
are indented, each level its own marker (`•` `◦` `▪`); `inline code` and **bold** keep their
emphasis without their markers; code has full syntax highlighting; a `csv`, `tsv` or
`json` block that is not one is shown as written; a file an agent read is numbered source,
its line numbers in their own column. Raw HTML, images, footnotes, and a
table wider than 100 columns are left as written, under a line that says so. The same
colours run through diffs and tool calls, by outcome.

While a turn works, the line under it says what is running, how many and for how long,
after a few words from the theatre: `◐ the actors are powdering their nose — thinking
(00:12)`. The words never repeat within a turn, and are not there when a turn waits on
you, in a window's tile, or in `troupe run --headless`, `troupe bench` or anything
`--json` prints.

From the moment you send a line the facts say what is waited on. Until the daemon sends
the model request: `◐ the house lights go down — preparing (00:04)`, and from ten seconds
on, with no flourish, `◐ the daemon has not sent the model request yet (00:14)`. After
the request: `thinking (00:12)` as ever, and from twenty seconds with nothing back, `◐ no
answer from api.anthropic.com yet (00:35)`, the host your configuration's `base_url` or
provider names, never the key. The time counts from the line you sent, then from the
request. At forty-five seconds either way, a box under that line says what was sent and
when, what has happened since, the last event this screen heard, and what to do:

```
nothing has happened for 00:46
▎ your prompt went to the daemon at 14:02:11
▎ the daemon acknowledged it; it has not sent the model request
▎ the last event here was input, at 14:02:11
▎ Esc cancels the turn · `troupe doctor` asks the model for a token · the daemon's log is ~/.local/state/troupe/daemon.log
```

After the request the second line reads `the request went to api.anthropic.com at
14:02:12; nothing has come back`. The box goes with the first byte of an answer or the
turn's end; a tile says the facts alone, and `troupe run --headless` prints one line at
the same forty-five seconds, once for the prompt and once for the request, and no more.
A request the model refused leaves the window saying so, `model error: <the provider's
sentence>`, under the turn and in its tile, until the next line you send.

The activated pane follows the tail until you scroll (PgUp/PgDn, Home/End, ↑/↓ while
nothing is typed, or the wheel); the title says where you are (`↕ 120–150/400 · 12 new`),
and End, scrolling to the bottom, sending input or answering follows again. Tool output
keeps its indentation, tabs included; a tool's header says what came back and how long it
took (`· 300 lines`, `· +3 -1`, `· exit 1 (12 lines) · 4s`), and its frame holds the
output, with the diff for an edit you were asked to approve. Whatever a branch is waiting
on is the last thing in the transcript, diff and all, so it reads at any width. `←`/`→`
switch between the branch's agents so a subagent's transcript can be read; input still
goes to the branch root. With a pane open the window strip shrinks to a tray; clicking the
active tile jumps back to the latest output.

## The scratchpad

A document you want to keep, such as a plan, a report, a table or a diagram, does not
belong in the chat, where it scrolls away and has to be printed again to be revised. An
agent puts it on the session's scratchpad instead, with its `show` tool, and keeps its
reply to the short answer and the document's name. It revises a document in place with
`patch`, which replaces an exact span of it or adds to its end, so the conversation
carries the change and not the whole document again; you see the whole document,
revised. Showing a document again under the same name replaces it.

**When an agent uses it.** Only when you ask for a document (a plan, report, table or
diagram to keep or revise), or when its answer would run past about 80 lines. Anything
else it answers in the chat. Ask for "a plan as a document" to get one on the scratchpad;
ask it to "answer here" to keep a long answer in the chat.

- **In the TUI** each document is a card in the transcript where the agent showed it: its
  title, its name, its size, and `new` or `updated 3 times`. `/scratch` lists the
  session's documents and opens one beside the list, Markdown drawn as a reply is and the
  other kinds as written; `/scratch plan.md` opens that one at once.
- **In the desktop app** the card opens the scratchpad beside the conversation, a tab for
  each document, and **Show scratchpad** in the session's header opens it on the latest.
- **Kinds.** A document is `markdown`, `mermaid`, `json`, `csv` or `text`. The clients show
  the last four as text for now.
- **Where it is.** A document is the session's own, beside its log in the state directory,
  never in your working directory: there is nothing to commit or clean up. Erasing the
  session erases its documents, a private session's stay on your machine with its log, and
  a fork has the ones its history shows. Your own program reads one as `scratch:/<name>`
  (`scratch.list` and `fs.read` in [PROTOCOL.md](../../PROTOCOL.md)).
- **Limits.** 256 KiB a document (`scratch_max_bytes`) and 50 documents a session
  (`scratch_max_documents`). Past either, `show` and `patch` refuse and say so, and the
  agent replaces a document or answers in the chat. A document too long for one reply of
  the model's is written in parts: the agent shows its start and patches the rest on.
- **What it costs.** Until the conversation is compacted, a document's words are in it as
  the `show` call's arguments, so it costs about what the same answer in the chat would,
  and a `patch` carries only its change. A compaction leaves each document out for a
  one-line pointer (its name, title, version and size), and a long patch too, and the
  summary it writes lists every document on the scratchpad, so from then on the model is
  not sent them again but knows they are there. When the agent needs one after that, it
  reads it back with `read_file` on `scratch:/<name>`; that read is the only way the
  agent's tools reach the scratchpad, and it writes there only with `show` and `patch`. In
  a long session that compacts often, the scratchpad costs more than answering in the
  chat, not less: each revision is a call of its own and a reply, and each read back after
  a compaction is another ([bench.md](../developer/bench.md) has the measurement). That is
  why an agent uses it only when asked or for a long answer.
