---
number: 129
title: A window's state is derived by the model from what the daemon sends, since the daemon sends none
date: 2026-09-27
status: accepted
supersedes: [4]
paths:
  - clients/tui/test/troupe/window_attention_test.exs
gist: A window's state is derived by the model from what the daemon sends, since the daemon sends none
---

Supersedes the `branch_state` of Decision 4, which only the
old in-process harness logged: since Decision 100 every window said `running` for
ever, so the status line never counted what needs you, done or failed, no window
was unread, and Enter on the command line opened the first window rather than the
one asking. The fold now says `needs_input` while anything in a window is pending,
a subagent's request as much as its own agent's, and otherwise where the window's
own agent is: `running`, or at rest once the log says its turn is over (the
durable `agent_state` that `turn_ended`, `cancelled` and `agent_done` become; the
live one says `idle` once before the task is taken). A rest is `failed_unread`
when the headless printer would exit `1` for it (a model request that failed, a
tool that kept failing, an agent that ended other than `finished`), except that a
cancel stays `done_unread` as Decision 7 has it; otherwise `done_unread`. Either is
unread until the window is opened, and a window that ends while it is open is
read. The view's own count of what is pending (Decision 126) agrees with the
model's now. Proof: `test/troupe/window_attention_test.exs`, which failed on the
chunk's tip, and the installed TUI on a delegation whose subagent asks, on the
pull request.
