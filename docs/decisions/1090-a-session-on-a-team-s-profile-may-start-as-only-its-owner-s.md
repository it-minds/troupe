---
number: 1090
title: "A platform session's create says whose it is: both clients send `visibility: \"team\"` by default and `private` on the desktop's tick \"Only me, until I invite people\" or the terminal's `--only-me` (`/new`, `troupe run`), the sentence says who can open it either way, and the list, the head and the status line mark such a session \"only you\", never \"private\""
date: 2026-11-22
status: accepted
issue: 1168
paths:
  - clients/gui/apps/desktop/src/views/StartSession.tsx
  - clients/gui/packages/client/src/newSession.ts
  - clients/gui/packages/client/src/fleet.ts
  - clients/gui/apps/desktop/src/views/bits.tsx
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/ui/new_session.ex
  - clients/tui/lib/troupe/cli/run_target.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
symbols:
  - platformVisibility
  - onlyYou
  - Troupe.UI.NewSession.visibility/1
  - Troupe.UI.TUI.View.only_you?/1
gist: "Platform create sends visibility team, or private on the tick 'Only me, until I invite people' / --only-me; sentence says who can open it; mark 'only you', never 'private'"
---

Issue #1168. The desktop sent `visibility: "team"` on every platform create; the terminal's
`/new` screen did too, but `troupe run` and every other create through `Remote` sent nothing
of its own and got `"private"`. The plane takes either and keeps its default (`private`, the
owner and the people invited by name); nothing changes on the plane. This narrows 1017 and
975 ("who can open it follows from where it runs") and TUI 172 ("a platform session from the
screen is the team's").

- **What is sent.** Both clients send the team's (`"team"`) unless the person says otherwise:
  the desktop's tick, off by default, under the sentence once the platform and a profile are
  chosen; `/new --only-me` (with `--remote PROFILE` too) and `troupe run --only-me` in the
  terminal. Then `"private"`: the session runs on the team's profile, pods and budget, and
  nobody on the team sees it until invited by name (949) or given to the team (#1169). The
  team chip stays where two teams may use the profile, since the budget is still a team's.
- **The words.** The sentence ends "only you can open it until you invite people"; the line
  under the tick says "Everyone on <team> can open it." or "Only you can open it until you
  invite people; administrators oversee it as any session." The mark is "only you" (desktop
  `ONLY_YOU_MARK`, terminal `View.only_you/0`), on a pod row whose `visibility` is `private`
  and whose `your_role` is `owner`; the desktop draws it in the place of "Team", which would
  say everyone on the team can open it. "Private" stays a sealed session's word (785, DESIGN.md
  §11): the plane's `private` visibility on a pod session is not one.
- **The status line.** `session.open` does not answer the visibility, so the terminal carries
  what the listing said (HQ's open) or what the create sent into the worker connection, and
  the status line says "only you" after "remote (…)".

Not chosen: a second chip on the sentence, which would make "who can open it" a choice
every start asks; a tick in the terminal's screen, where the TUI's flags are how chips are
pre-set (172); calling it "private", which would say sealed. Undone, the clients disagree
again on what a platform start means, and a session nobody on the team can see is listed
with no mark saying why.
