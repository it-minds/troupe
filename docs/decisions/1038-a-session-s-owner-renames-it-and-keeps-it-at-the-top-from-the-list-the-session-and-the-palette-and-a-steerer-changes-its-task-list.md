---
number: 1038
title: "A session's owner renames it and keeps it at the top from a row's ⋯ in the desktop list, the session's ⋯ and the palette's /rename and /keep, which are harness built-ins the terminal runs too; the word is Keep at the top, as an artifact's; and whoever may steer a session completes, cancels and adds a task in the Tasks pane"
date: 2026-11-17
status: accepted
issue: 1032
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/gui/apps/desktop/src/views/Sessions.tsx
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/src/views/Tasks.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/tui/lib/troupe/client/marks.ex
  - docs/user/sessions-shared.md
gist: "Rename and Keep at the top/Let go from the top: a row's ⋯, the session's ⋯, /rename and /keep [off] (harness built-ins, TUI too); answer patched onto the row; Tasks pane completes, cancels, adds"
---

`session.title.set`, `session.pin` and `todo.edit` had a library wrapper each and no
caller. Now:

- **Where.** Renaming and keeping sit beside archiving, the other owner's change to how a
  session is listed: in the session's ⋯, and in a ⋯ beside each row of the list the person
  owns (beside it as Claim is, since the row opens the session). The title becomes a field
  in place: Enter sends, an empty name takes it off, Esc or leaving the field keeps it.
- **The palette.** Its list is the harness's (Decision 698), so `/rename <name>` and
  `/keep [off]` (alias `/pin`) are built-ins in `Troupe.Commands`, and the terminal client
  runs them too, through the daemon or the plane as `/archive` does. The desktop's
  `/rename` alone opens the head's field.
- **The word.** Keep at the top, Kept, Let go from the top: Decision 1018's words for the
  same act on an artifact. "Pin" stays the protocol's and an artifact version's word.
- **No push.** Neither the daemon nor the plane says a name or a pin changed, so the
  answer is put on the row in the store at once, and the list is asked again after.
- **Tasks.** `todo.edit` takes `add`, `cancel` and `complete`; it has no change of a task's
  text, so the pane offers those three. The harness takes an edit during a turn as well as
  between, so the pane is editable whenever the person may steer the session.

**Not chosen.** Rows of the desktop's own in the palette: the one table is the reason it
lists what a person can type anywhere. Text edits of a task: no method has them.

**If undone.** The three methods go back to having no caller, and the terminal and the
desktop list different commands.
