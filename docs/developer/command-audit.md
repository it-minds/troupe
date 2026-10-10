# Command audit (issue #502, part B)

Every row of `Troupe.Commands` (the table `commands.list` serves and every client's palette
draws) run in a session, with what happened and what now holds it: a test, or a defect in
[defects.md](defects.md). Recorded on 2026-10-10 on `development-2026-10-09-2` at
`50cb1e01` (0.10.0-beta), before command mode (#502 part A) changes what the root is.

## How it was run

- **The installed build on Windows.** `scripts/install-local.ps1`, then the installed
  daemon started on scratch homes with the `fake` provider, and the installed TUI's own
  code (its Burrito payload) driving a headless screen (`ExRatatui.CellSession`): each
  command typed as a person types it, a bracketed paste of the line and Enter, and the
  screen's state read back after it (where the focus went, the notice line, which
  windows came or went, what reached an agent as input). The fixture is a git repository
  with one repository command, `.troupe/commands/review.md`, and a worktree of it checked
  out beside it.
- **The same driver from source on Linux** (WSL), which is where most of the gaps below
  were first seen.
- **A pod** is the TUI's remote client against the suite's `FakeRemote` worker (it speaks
  the worker's protocol over real WebSocket frames), from source, plus the worker's own
  harness tests for what a pod refuses and the table it serves (`harness_auth_test.exs`).
  No real worker pod: the local dev plane (kind) is not up on this machine, and the live
  one is not for this.

The situations, as the columns below have them:

| Column | What was done |
| --- | --- |
| **Line** | the command typed on the command line with no window activated, with an argument where it needs one |
| **Window** | a finished `build` branch's window activated with its digit, the palette opened over it (Ctrl-K), the command's name typed and Enter |
| **Worktree** | both of the above again in a session opened in a linked worktree rather than the main checkout; only what differed is said |
| **Pod** | the command typed on a session a plane runs |

Every built-in but `new`, `worktree` and `quit` also runs from the palette with no window
activated in the suite (`command_palette_test.exs`, "every built-in typed in full still
runs").

## The table

"Notice" is the line under the screen. A test named without a file is in
`clients/tui/test/troupe/command_audit_test.exs`; "smoke only" means nothing but the
palette's run of every built-in holds the row.

| Command | Line | Window | Worktree | Pod | Covered by, or recorded in |
| --- | --- | --- | --- | --- | --- |
| `new` | a new session takes the screen; notice names it and says `/back` returns | as Line | as Line | `--remote PROFILE` starts one on the plane, `--branch` forks the pod session there | `new_session_test.exs` |
| `cancel` | notice: no window given | the branch's turn is cancelled; **the window stays and its worktree is kept**, against the row and TUI Decision 57 | as checkout | Line: no window given; Window: sends `turn.cancel` | D105; `collaboration_test.exs` (gateway) for the cancel |
| `dismiss` | notice: no window given | the window goes, the branch's session is detached | as checkout | Window: lets go of the session, **and later commands go to this machine's daemon** | "a window command picked from the palette acts on the activated window"; D105 |
| `merge` | notice: no window given | the branch lands, the window goes; **said nothing** before the audit, now says what merged. **On Windows it crashed the screen** before the audit: see below | lands on the linked worktree's branch | refused: no local worktree to merge | "each says what it did once the window has gone", "a local-only command says why it cannot run there"; `branches_test.exs` (gateway) |
| `discard` | notice: no window given | the worktree and its branch go, the window goes; now says so | as checkout | refused, the same way | as `merge`; a branch in the checkout now says "nothing to discard", not "nothing to merge" |
| `goal` | sets it; `/goal` shows it, `/goal clear` clears it | as Line | as Line | asked of the worker (`session.goal.*`), which the suite's stand-in doesn't answer | `goal_client_test.exs`; the worker's `harness_websocket_test.exs` |
| `loop` | without a goal: says to set one; with one: runs and stops at its count; `/loop stop` stops it | as Line | as Line | asked of the worker (`session.loop.*`), as `goal` | `loop_client_test.exs` |
| `sessions` (`resume`) | the picker opens | as Line | as Line | the picker opens | `new_session_test.exs`, `branch_client_test.exs`; D105 (a dismissed branch is not listed) |
| `back` | nothing to go back to, or back to the one left; a stopped session is woken | as Line | as Line | back from a pod session to a local one and again | `new_session_test.exs` |
| `hq` (`remote`) | HQ opens; with no plane, on this machine's sessions | as Line | as Line | HQ opens | `remote_hq_test.exs` |
| `observer` | the agent tree opens | as Line | as Line | as Line | smoke only (`command_palette_test.exs`) |
| `files` | the files panel opens on `session:/` | as Line | as Line | the worker's checkout | `remote_ui_test.exs`, smoke |
| `upload` | the file lands in the workspace; **one over about 16 MB fails with "the daemon is not reachable"** | the palette puts `/upload ` on the line and lets the window go | as Line | sent to the worker | `worker_commands_test.exs`, `remote_ui_test.exs`; D108, D107 |
| `copy` | notice: no window given | the window's transcript is copied (WSL); **on Windows "clip exited 1: The syntax of the command is incorrect"** | as Line | as local | "a window command picked from the palette acts on the activated window"; `clipboard_test.exs`; D109 |
| `memory` | says what the brief holds | as Line | the brief of the main checkout (Decision 831) | refused: the brief lives on the worker | `memory_client_test.exs`; "a local-only command says why it cannot run there" |
| `context` | one line: files read and left out | as Line | names the main checkout's brief | asked of the worker (`context.get`), as `goal` | `context_command_test.exs` |
| `watch` | turns watch on, says which backend; **a second `/watch` turned it on again** before this audit, now off | as Line | as Line | refused: watch runs where the files are; the palette greys it | "a second /watch turns watch off, and the status line follows"; the section below; D106 |
| `settings` | the settings page opens | as Line | as Line | the page opens (a pod's settings are its plane's) | `settings_test.exs` |
| `models` (`model`) | the settings page on the default model, its menu up | as Line | as Line | as `settings` | smoke only |
| `mcp` | the servers page opens | as Line | as Line | the page opens (a pod's servers are its profile's) | `mcp_page_test.exs` |
| `skills` | the same page, on the skills | as Line | as Line | as `mcp` | `mcp_page_test.exs` |
| `help` (`?`) | the palette opens | as Line | as Line | as Line | `command_palette_test.exs`, `plain_line_test.exs` |
| `agents` | notice: the primary agents, **with `worktree` among them** | as Line | as Line | the plane's profiles | smoke only; D107 |
| `worktree` | the default agent in a fresh worktree; **`<existing>` and `<name>:` are not read**, the whole line is the prompt | the palette puts `/worktree ` on the line and lets the window go | branches made beside the linked worktree | refused: one profile per pod session | D105, D107; "a local-only command says why it cannot run there" |
| `quit` (`exit`, `q`) | the screen exits, the session carries on | as Line | as Line | as Line | `command_palette_test.exs` (the row); the driver |
| `answer`, `ask`, `build`, `plan`, `quick`, `workflow` | a branch in its own worktree, its window opens and finishes | the palette puts `/<agent> ` on the line and lets the window go | worktrees beside the linked worktree | refused: one profile per pod session | `branch_client_test.exs` (`build`, `workflow`); D107; D105 for `ask` |
| `librarian` | a branch in the checkout itself (it writes only the brief) | as the others | in the linked worktree | as the others | `memory_client_test.exs` |
| `explore`, `general`, `implementer`, `reviewer` | no row: subagents (`mode: subagent`), started by `delegate`, not by a person | - | - | - | D107 |
| `custom` (`/review README.md`) | its prompt, `$ARGUMENTS` filled, goes to the session's own agent | the palette runs it at once with `$ARGUMENTS` empty, to the session's agent, not the window's | as Line | sent to the worker (`commands.run`) | `command_palette_test.exs`, `project_command_test.exs`; D107 |

## `/watch`, end to end

With no window activated, `/watch` turned watch on and the status line said which backend
(`watch: native` on Windows, `watch: poll` in WSL's `/tmp`). A comment ending in `AI?`
written into a file reached the session's own agent as a `watch` input whose turn ran
under the plan permission set: its `write_file` was refused ("not available in the
current profile") and nothing was written. An `AI!` written while a branch's window was
activated went to the same agent, not the branch, and made the change (`src/app.py`
rewritten, the comment gone); the activated window and the notice line said nothing of
it, only the root tile's state changed. A second `/watch` turned it off, now that the
toggle reads back what it set, and an `AI!` written after it reached nothing.

The gaps are D106: the trigger reaches the session's own agent, not `quick` or `answer`
(TUI Decision 67 is not kept), so watch and `/quick` are two paths; nothing on screen says
a trigger was taken; and no client can ask whether a session watches. On a pod `/watch`
is refused, and the palette greys it (`watch.set` is one of the methods a pod refuses,
`harness_auth_test.exs` in the worker).

## Also worth checking

- **`merge` and `discard` on a dirty checkout.** A branch that changed `README.md` merged
  into a checkout with its own uncommitted change to it: git refused, the checkout kept
  its change, and the notice said "merge conflicts; resolve in your checkout", though
  nothing conflicted (D105). `/discard` then left the checkout's changes alone. A branch
  merged into a checkout dirty in other files landed and kept them.
- **`cancel` mid-tool.** A branch running `sleep 30` in `shell`: `/cancel build-1` ended
  the call within two seconds ("cancelled: the turn was cancelled before this finished" in
  its transcript) and the window's state read finished; the window and its worktree
  stayed (D105). That the command's process is killed is `resilience_test.exs` in core.
- **`dismiss` of a window with unread output.** The window went; the branch's session is
  not in `/sessions`, which leaves out every session with a parent (D105).
- **`back` to a session that is gone.** One stopped in the daemon is woken by `/back`; an
  erased one is refused (`new_session_test.exs`).
- **A large `upload`.** 20 MB and 70 MB both failed with "the daemon is not reachable" and
  the connection was dropped and came back (D108).
- **`/loop` stopped from the command line.** `/loop stop` with no window activated stops a
  running loop (`loop_client_test.exs`); one that has finished says nothing runs.
- **`/worktree <existing>` with Tab.** Tab after `/worktree ` offered the checkout's own
  branch first, then the worktree checked out beside it; the command then ran in a fresh
  worktree with the name in its prompt (D105).
- **`ask` with no branch finished.** Its `read_branch` listed the session it was started
  from, as `build idle (no prompt)`, as though that were a branch, and nothing said that no
  branch had finished (D105).
- **Tab on the command line** completed `mer` to `merge `, which Enter then sent to the
  agent as words (D93). It now completes to `/merge `.

## `/merge` and `/discard` on Windows

The first installed run stopped at `/merge` from the palette over a branch's window. The
gateway ran `git worktree remove` inside the worktree it removed, which git cannot do on
Windows ("failed to delete ...: Permission denied", the tree unregistered but left), after
the merge had already landed. It answered that failure with `Error.new(:internal, ...)`,
which is no error code, so the daemon's connection process raised and closed the
connection; the client's link exited with it and took the screen down (D108). Run from
the checkout, the removal works there, and a git failure in `worktree.merge`,
`worktree.discard` is now an `internal_error` the caller is told
(`branches_test.exs`, "a worktree git cannot remove is an internal error the caller is
told"). `worktree.remove`, which the desktop app calls, still runs inside the tree (D105).

## Fixed with the audit

Each with a test that failed first, or for the Windows removal the command sequence above:
Tab completes a command with its slash (D93); a second `/watch` turns watch off and the
status line follows; `/merge` and `/discard` say what they did; `/discard` of a branch in
the checkout says "nothing to discard"; a merged or discarded worktree is removed on
Windows, and a git failure there no longer closes the connection. The suite's
`FakeRemote` worker answers `commands.list` as a pod does, so the pod tests see the
palette a pod session shows.
