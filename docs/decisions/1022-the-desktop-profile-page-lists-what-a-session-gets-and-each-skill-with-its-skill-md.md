---
number: 1022
title: "The desktop app's profile page lists only what a session gets, and each skill with what it does and its SKILL.md; `profile.get` carries `skill_details`"
date: 2026-11-17
status: accepted
issue: 1003
paths:
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/test/troupe/plane/profile_view_test.exs
  - clients/gui/apps/desktop/src/views/Profiles.tsx
  - clients/gui/apps/desktop/src/styles.css
  - clients/gui/apps/desktop/test/profiles.test.tsx
  - clients/gui/packages/client/src/profile.ts
  - clients/gui/packages/client/test/support/profiles.ts
  - PROTOCOL.md
  - docs/user/profiles.md
symbols:
  - Troupe.Plane.ProfileView.get/3
  - Skills
gist: "profile.get adds skill_details [{name, description, body, truncated}], body the SKILL.md after its front matter cut at 64 KiB; the desktop page drops Not here and gives skills a section of their own"
---

Issue #1003. The people reading the desktop app's profile page wanted to know what each
skill is, and found the list of agents they would not get more noise than help. The
page named the skills on one line, and drew a "Not here" table under the agents.

**`profile.get` says what each skill is.** The answer gains `skill_details`, the same
skills as `skills` in the same order, each `{name, description, body, truncated}`.
`body` is the skill's `SKILL.md` after its front matter, which only repeats the name and
description; `null` for a skill whose bundle entry has none. It is cut at 64 KiB on a
character boundary, `truncated: true` then, so a skill with a large file never makes the
answer large. It is composed in `ProfileView` from the bundle it already reads, not in
`Bundles.offering`, which activation uses too and which has no use for the bodies. The
field is additive: `skills` stays the names, for every client that reads it.

**The desktop page lists what a session gets.** The "Not here" table is gone from the
desktop app. The agents and the function agents stay. Skills are a section of their own
after the agents, one line each, the name and what it does. A skill with a body opens in
place to its `SKILL.md`, rendered as a reply is (`ProseFrame`, with its source toggle). A
plane from before `skill_details` gives the names alone, and the page shows them so.

This changes Decision 969 for the desktop app only: `agents_not_here` stays in the answer,
the terminal's `/profiles` still lists it, and the console's "What a member sees" keeps
its table, where an administrator checking a grant needs to know whose word took
an agent away.
