---
number: 173
title: "A page's key line fits the width it is drawn at: where it does not fit, its label goes first, then its keys from the end, never Esc and Enter while there is room for them, and the keys that leave the line are shown in the box under it; the console is named as Group → Area only, an administrator's page said as theirs"
date: 2026-11-14
status: accepted
issue: 894
paths:
  - clients/tui/lib/troupe/ui/tui/key_line.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/new_session_page.ex
  - clients/tui/test/troupe/key_line_test.exs
  - clients/tui/test/troupe/console_paths_test.exs
symbols:
  - Troupe.UI.TUI.KeyLine
gist: "Key line fitted to the width: label, then keys from the end; Esc/Enter stay; what leaves is shown under the line; console named as Group → Area, admin pages said as an administrator's"
---

A page says its keys on the command box's top border, one line drawn without wrapping. A
UX audit at 51b43904 (#894) found `/new`'s line at 113 characters, `/memory`'s at 120 and
`/artifacts`' at 140: at 80 columns the end was cut, and the end is where the way out is.

## Decision

**One fitter for every key line** (`Troupe.UI.TUI.KeyLine.fit/2`), applied where the box
is drawn, so no page measures its own. A line that fits is left alone. One that does not
loses its label (` memory — `) first, since the page names itself above, then its keys
from the end of the line, which a page writes most important first; a key that starts
`Esc` (the way out) or `Enter` (what acts) stays while a narrower line has room for it,
and below that only the way out stays.

**Nothing leaves for good.** The keys taken off the line are shown, in the line's order,
in the box under it (`also …`), which on a page holds nothing typed. A page's help could
have held them instead, as the audit's brief suggested ("? keys"); the terminal has no
per-page help, `?` is a character several pages type, and the box was empty already, so
the keys go where they are seen. A box being typed in keeps its line fitted and drops
the rest: the command line's and the palette's lines are short enough at 80 columns
without their label.

`/new`'s line is reordered so Tab comes before the newline keys, the less needed of the
two at 80 columns; TUI Decision 172's keys are unchanged.

**The console, named as it names itself.** A sentence that sends somebody to the console
names its page as `Group → Area` from the console's map (`nav.ts`, which its rail draws),
nothing finer: a panel of a page is not named. A page outside *Mine* is an administrator's,
so the sentence says so, and where it cannot know the reader's role it says both in one
line ("an administrator changes it on the console's Configure → Configuration bundles; ask
one if you are not"). `console_paths_test` holds every string the terminal says to it.

## Proof

`key_line_test.exs`: the fit at every width from 12 to 130, every key on the line or
under it in order, the way out always kept; `/new` at 80 and 120 columns.
`memory_screen_test.exs` and `artifacts_screen_test.exs` at 80 and 120 columns.
`console_paths_test.exs`: no panel after a place, every `A → B` in the terminal's strings
a console place, every sentence to the console naming one, an administrator's page said
as such. All failed on 51b43904.
