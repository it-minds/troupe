---
number: 101
title: One agent per session; a plain line is what you say to it
date: 2026-09-20
status: accepted
paths:
  - clients/tui/CLAUDE.md
gist: One agent per session; a plain line is what you say to it
---

Decision 7.3 of the brief: a branch is a session of its own, not a window inside one, so `Troupe.Client.dispatch/3` on a daemon session answers that another session is the way (`troupe run <agent> "task"` or HQ creates one, in its own worktree when the workspace is busy), and the window is `root` for daemon and pod sessions alike — `Troupe.Remote.Worker` names it so before the first event, where it used to invent `<profile>-1`. Text typed at the command line without a slash goes to the session's agent as input; a slash still names a command. The default agent is `build`, which the harness ships, where it was `code`, which this repository's deleted definitions did; the other eleven come back in phase 3 as bundle content. The old `Troupe.Config` (808 lines) is the harness's (204, plus the providers, opencode fallback and catalog it gained in phase 1), and `Troupe.Settings` is rewritten over its flat fields: settings live in the config file the daemon reads at session start, `watch` is the one a running session takes live (`watch.set`), and `mouse` — the TUI's own — rides in the config's `extra` map.
