# The terminal client's screen

What [`troupe`](../../clients/tui/README.md), the terminal client, puts on the screen once a
session is open, and the keys and pages it has: the keys, reading a transcript, colours,
tokens and cost, the observer, the command palette, the settings page, watch mode and the
agent picker. Installing it, the command lines and sessions on a plane are on
[its own page](../../clients/tui/README.md).

## Keys

- **Windows.** `1`–`9`, Enter, or a click on its row or tile activates a window; Esc
  returns to the command line. `xx` (x twice) cancels and removes the window; `dd`
  dismisses a finished one, keeping its worktree. Tab chooses the agent the window runs,
  each with its instruction beside it (`/plan` → Tab, `build` → "go" is plan-then-build;
  the title says which agent runs).
- **Answering.** `y`/`n`/`a` answer an approval (allow / deny / allow for the session).
  Typing and Enter sends input or answers a question; when a question offers options a
  digit picks one (with `multiple`, digits tick and untick and Enter sends the ticked
  set). Alt-Enter or Ctrl-J puts a newline in the box instead of sending.
- **Completing.** Tab on the command line completes command names and the window paths
  for `/merge`, `/discard`, `/cancel` and `/dismiss`; `@file` completes paths.
- **Reading.** `e` opens the turn you are reading, every frame of it, and closes it again;
  Ctrl-Y copies the transcript you are reading to the clipboard.
- **The task list.** `/todo complete <n>`, `/todo cancel <n>` (the task's number in the
  side panel) and `/todo add <text>` edit the activated branch's.
- **Quitting.** Ctrl-C twice, `/quit`, Ctrl-D or Ctrl-Q.

Any other command typed into a window's box runs as it would on the command line, on that
window where it takes one (`/copy`, `/merge`); a line that names no command (`/usr/bin is
missing`) goes to the window's agent. `x` and `d` are double presses because the window
they act in is also where you type: the first press puts the letter in the box, which says
what a second would do, and anything else you type (a reply beginning "do it" or "drop
that") keeps the letter as text.

**Selecting text with the mouse.** Drag across the pane to highlight; releasing the
button copies it, rails and line numbers stripped, and Ctrl-Y copies the selection while
one is up (Esc clears it). Troupe owns the selection because mouse reporting, which makes
tiles clickable and the wheel scroll, takes click-and-drag from the terminal. For the
terminal's own (rectangular blocks, the tiles or the observer), hold your emulator's
modifier (Option on iTerm2 and Terminal.app, Shift on GNOME Terminal, Konsole and most X11
terminals), or turn `mouse` off (`troupe --no-mouse`, or `/settings`); windows are still
`1`–`9`, and the pane still scrolls with PgUp/PgDn, ↑/↓ and End. With nothing selected,
Ctrl-Y and `/copy` copy a whole transcript, which no drag across a scrolling pane can.

## Reading a transcript

A turn shows its answer, not its working ([reading a transcript](README.md#reading-a-transcript)
says what is common to both clients). Everything rendered from something is a frame on a
surface one step from the terminal's background, with a rail, `▎`, down its left; what you
typed and the notes between turns are not on it. By default (`quiet`) a turn's reasoning,
its calls and the prose between them are one line where they began, above the answer:

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
`--json` prints. The design, which the desktop app follows too, is
[docs/design/frames.md](../design/frames.md).

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

## Colours

The themes are the desktop app's, from the same design tokens: Afterglow by default, or
Signal, Footlight or Limelight, the `theme` setting in `/settings`, which is the desktop
app's appearance setting too, so a theme picked in either is the one both draw in. In
Afterglow cyan is the machine working, and pink is for one thing only, a window that needs
you: its border and title (blinking about once a second; the `blink` setting turns that
off), the approval or question waiting in it, and the status line's count. Each theme
keeps its own reserved colour (Signal's magenta, Footlight's amber, Limelight's lime) for
the same thing. Every window carries the mark in its top right corner, and at the start of
its row in command mode: ◐ ◓ ◑ ◒ turning while its agent works, ◑ in the reserved colour
while it needs you, ⏺ done and not yet read, ○ at rest or not yet asked anything, ✗
failed.

Troupe uses as many colours as the terminal says it has: exact colours where `COLORTERM`
is `truecolor` or `24bit` and in Windows Terminal, the nearest of 256 where `TERM` names
`256color`, the terminal's own sixteen otherwise, and none under `NO_COLOR`. It paints no
background but a frame's, one step from the terminal's own, with exact colours and 256
(with sixteen or none the rail alone marks a frame), so it sits on whatever theme the
terminal has; a light background reported in `COLORFGBG` gets the light values.
`TROUPE_COLORS` overrides what the terminal says: `truecolor`, `256`, `16` or `none`, and
`light` or `dark` (`TROUPE_COLORS=256,light`).

## Tokens and cost

A tile reads `↑4.4k ↓3.1k`: tokens sent and received, the whole session's, `↑` what the
provider billed at close to full price. Input served from its prompt cache is reported
apart, as `cached` in the side panel and the observer's detail, and budgets spend the
billed part, so re-reading a cached prompt does not exhaust `max_input_tokens`. What one
turn cost is said when it ends, its subagents' calls included and `no price` when nothing
prices the model ([what a call costs](models.md#what-a-call-costs)). The
side panel says it under `This turn`, with the session's totals under `Session` and, once
a limit is near, how near:

```
This turn:
  3 calls · $0.04
  ↑ 300 sent · 3.0k cached
  ↓ 120 received
Session:
  41 calls · $0.61
  ↑ 1.2M sent · 310.0k cached
  ↓ 19.0k received
  ⚠ 82% of input tokens
```

While the next turn runs, `This turn` says `said when it ends`. Below 100 columns there is
no side panel, and the turn's cost is a line under the turn instead: `turn: 3 calls · ↑ 300
sent · 3.0k cached · ↓ 120 received · $0.04`.

## Observer

`/observer` is the overview across branches: every root agent with the subagents it
delegated to nested under it, each with what it is doing now (`thinking`, the tool it is
running, `needs you`), how long it has been at it and what it has spent. The panel beside
the tree details the selected agent: its definition and depth, its branch, whether that
branch is in your checkout or a worktree (and which), the model it called, its task list,
anything it is waiting on, and its recent tool calls. `↑`/`↓` moves, Enter opens that
agent's branch window, Esc goes back.

## Command palette

`/` on an empty command line, Ctrl-K with nothing typed, or `/help` opens a popup listing
every command in sections (Session, Navigate, Workspace, Setup, Agents, one entry per
agent with its description, Custom, the commands you and the repository wrote, with the
file each came from, and Quit), each with a one-line description, and the selected one
explained beside it with an example. Typing filters by name, alias or description (`mer`
narrows to `/merge`); `↑`/`↓` and PgUp/PgDn move; Enter runs the command, or leaves it on
the line when it needs an argument; Tab or Space leave it on the line too, so `/merge 2`
types as it always did; Esc goes back. A command that cannot run now (one that acts on a
window when none is activated, or a local one in a plane session) is shown greyed with the
reason. The list is the daemon's (`commands.list`), so the desktop app shows the same.

## Settings page

`/settings` lists every setting with its value and the file it came from, and help beside
it: what the selected setting does, and the commands, keys and concepts worth knowing.
`↑`/`↓` moves; Enter toggles a boolean, opens a menu (the models, and the provider, each
type saying what else it needs) or edits a value; `s` changes which file a change goes to;
PgUp/PgDn or the wheel scrolls the help; Esc goes back. The page and the desktop app read
and write through the daemon, so they always agree
([settings in both clients](configuration-settings.md#settings-in-the-desktop-app-and-the-terminal)).
`/models` opens the model menu directly ([models](models.md#the-models-troupe-can-address)).

Watch mode applies to the running session at once, and so do the theme, blinking and
`transcript detail` (`quiet`, `tools` or `everything`, typed), which the screen draws by
unless `/detail` set this session's own; everything else applies to sessions and branches
started from then on. A change is written by its current name (`models.default`, never the
old `model`). Environment variables still win over every file, so a setting masked by
`TROUPE_MODEL` is saved but not in effect, and the status line says so.

## Watch mode

A comment ending in `AI!` is a change request and starts a `quick` branch; `AI?` is a
question and starts an `answer` branch, which cannot edit; bare `AI` comments are
collected as context. The branch works in the checkout the comment is in, its window opens
as `quick-1` (and so on), and the line under the screen says which file and comment
started it; the session's own agent is told nothing. Both agents run on the cheap model
with few turns, since saving a comment is a cheap gesture and the branch it starts should
be one too. For something heavier, redefine `quick` or `answer` in `.troupe/agents/` or
your own `agents/`, which is what `/quick` starts too.

Anything that writes a file can write a comment, so a branch a comment started asks before
every write, edit and shell command, whatever `auto_approve` says, until you set
`watch_auto_approve: true`. The status line says whether the workspace is watched,
whichever client turned it on, and `/watch` turns it off. On Linux, native watching needs
`inotifywait`; without it Troupe falls back to polling and says so.

## Agents

`/agents` is the agent picker Ctrl-N and Tab open, at the manager's density: every agent,
the subagents too, each with where it comes from in the four words (Shipped, Your
organisation's, Yours, This repository's), its mode, model and tools, whether it is
read-only, its cap on turns, what it stands in for and which windows run it, and the files
that could not be read after them; Enter reads one's whole instruction and `b` starts a
branch on it. `e` opens it in your editor (`VISUAL`, then `EDITOR`; Notepad or `vi`
without either) and the daemon checks what you saved: refused, the errors are on the page
and your edit is kept for the next `e`; accepted, you pick where it goes, `r` the
repository's `.troupe/agents/` or `m` your own `agents/`, after it says which tools it
would run without asking, and asks again when the save adds one. `c` copies one into the
repository in one key, `n` makes a new agent from the one selected (one Troupe ships or
your organisation's as well as your own) under a name you type, `x` deletes a copy and
says what answers to the name after. `n` is the picker's everywhere it opens. A save comes
back to the picker on what was saved, so Enter, or `b`, starts on it at once. A bundle's agents, and every agent on a pod, are read-only here
and say where they are changed. What a definition holds, and the built-ins, are on
[agents, commands and workflows](agents.md).
