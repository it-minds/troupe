---
number: 975
title: "A session starts from a message: the new-session screens in the desktop app and the terminal put the message box first and the settings in one sentence of chips, pick the profile by a stated rule (the last used with room, else the first with room), read @profile, #agent, /local and /platform from the message and take them out before the agent reads it, queue on a full profile as the plane's existing pending wait made visible, turn On this computer on by itself when the daemon answers, title the session from the first line, and record the agent and the title on the session's row"
date: 2026-11-12
status: accepted
paths:
  - clients/gui/apps/desktop/src/views/StartSession.tsx
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/test/new-session.test.tsx
  - clients/gui/packages/client/src/newSession.ts
  - clients/gui/packages/client/test/new-session.test.ts
  - clients/gui/packages/client/src/plane.ts
  - clients/gui/packages/client/src/daemon.ts
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/lib/troupe/plane/sessions.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/session.ex
  - apps/troupe_plane/priv/repo/migrations/20261112000975_session_agent.exs
  - apps/troupe_worker/lib/troupe/worker/session/manager.ex
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_core/lib/troupe/sessions/title.ex
  - apps/troupe_core/lib/troupe/sessions/index.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/ui/new_session.ex
  - clients/tui/lib/troupe/ui/tui/new_session_page.ex
  - clients/tui/lib/troupe/cli/run_target.ex
  - PROTOCOL.md
  - docs/user/README.md
  - clients/gui/README.md
symbols:
  - autoPickProfile
  - messageTokens
  - Troupe.UI.NewSession
  - Troupe.Sessions.Title
gist: "Message first, settings as one sentence of chips; auto-pick last-used-with-room else first-with-room and say why; tokens stripped; Queue it is the plane's pending wait; agent and title on the row"
---

People asked for a chat box to start a session quickly, and a session cannot start
without a profile. The answer the maintainer chose from the design mock (2026-11-12) is
that there is always a profile, and it is never a question.

## Decision

**The message comes first.** The new-session screen in the desktop app and `/new` in the
terminal open on the message box. Under it the settings read as one sentence, "Runs [on
the platform] with [dev] as [build] · everyone on core can open it", and each bracketed
word is a chip that opens its picker underneath: where it runs, the folder when it runs
here, the profile with its room, the agent. On this computer the sentence reads "Runs [on
this computer] in [folder] as [build] · only you can open it", and the folder's picker
holds what the local half had: recent folders, Choose…, a typed path, the worktree
choice, watch mode and private where the daemon can seal one. The agent's picker is a plain
pick, one option per agent with what it does and the default marked: before a session
exists there is nothing to switch and no file to open from here, so the in-session
`AgentPicker`'s start, switch and edit are not on this screen (this narrows Decision 920
for the new-session screen; it still reads `agents.list` on this computer).

**The profile is picked by a rule, and the rule is said.** Nobody having picked one, it is
the last one used (the newest of the person's own sessions on the plane by
`last_active_at`, else the last one chosen on this machine) while it has room, else the
first with room in the order `profiles.list` gives. A line under the sentence says which
rule picked it ("Picked dev because you used it last.", "Picked dev: standard is full
right now."). A chip or a token overrides it, and the line then says "Set from your
message: …" or nothing. A model reading the message to choose the profile would slot into
the same line; the rule-based pick ships first, and how often people override it is the
measure of whether that is worth doing. Picking only profiles that reach nothing outside
their workspace, so that one reaching company systems needs a click, is not done.

**Tokens set the chips and are taken out.** `@profile`, `#agent`, `/local` and `/platform`
at the start of the message or after whitespace set the chips, are tokens only where
they name something on offer (so `#123` and `@someone` stay as typed), win over a chip,
and are removed before the agent reads the message. `@profile` without `/local` means the
platform. Picking a chip's option takes the token of its kind out of the message, so the
last thing the person did is what holds. The rules are one module per language
(`newSession.ts` in `@troupe/client`, `Troupe.UI.NewSession` in the terminal), held to the
same examples, and `troupe run` reads its task text by them too.

**A full profile is queued, not refused.** The plane already makes a create on a full
profile below the administrator's ceiling wait (`pending`, Decision 497) and holds its
prompt. No new queue: the screens make that wait visible. A full profile's chip is the
queued colour, the line says "Full house: …", and the button reads "Queue it"; the casting
screen says "Waiting for a free place in <profile>" and asks `token.mint` again each
`retry_after_ms` until the session is placed (no client waits on one reply for good,
Decision 923), then opens it. Going back stops the wait; the session waits on at the
plane by itself. At the ceiling (`max_sessions`, which `profiles.list` now answers) the
button is off and the line is the plane's own sentence once a refusal has said it.

**Who can open it follows from where it runs.** Only you for this computer or a private
session; everyone on the profile's teams (`profiles.list`'s `teams`, by name) on the
platform, and the create asks for `visibility: "team"` so the sentence is true. The old
screen said "Everyone on [object Object]" and made the session private.

**"On this computer" turns on by itself.** While this computer's daemon does not answer,
the option is off with "APP NOT RUNNING" and the line says why; it turns on when the
daemon connects. This narrows Decision 963 on this screen alone: its banner ("the daemon
is ready now", Refresh) is not shown on the new-session screen, which asked nothing of
the daemon that a refresh would ask again. Every other screen keeps the banner.

**The title is the first line until edited**, sent as `title` to the plane and to the
daemon, whose `session.create` now takes one (at most 200 bytes, trimmed) and keeps it
beside the session's log; `session.title.set` renames a session in either.

**The agent is on the row.** The plane records the agent a session was created as and the
one its pod reports it was switched to, and answers `agent` and `created_at` on its rows,
so "start like last time" copies where, folder, profile and agent from a listing. A
session that waited for a place used to start as the profile's default whatever was
asked; it now starts as the agent it was asked for.

## Proof

`packages/client/test/new-session.test.ts` and the TUI's `new_session_screen_test.exs`
hold the rules to the same examples; `apps/desktop/test/new-session.test.tsx` drives the
desktop screen against the fake plane and daemon (auto-pick both ways, tokens and a chip
clash, full → Queue it → pending → placed, the ceiling, the daemon not ready then ready,
the local sentence, the title, Ctrl+Enter, start like last time, a failed start).
`scaling_test.exs` proves the agent survives a wait and the listing's ceiling and teams;
`session_title_test.exs` the daemon's title.
