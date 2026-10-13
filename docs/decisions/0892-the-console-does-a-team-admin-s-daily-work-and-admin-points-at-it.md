---
number: 892
title: "The console does a team admin's daily work, and the plane's index and the LiveView console's landing page point at it; the LiveView console stays as the way in when it cannot be used"
date: 2026-10-13
status: accepted
issue: 56
paths:
  - clients/gui/apps/console/src/owed.ts
  - clients/gui/apps/console/test/coverage.test.ts
  - clients/gui/apps/console/src/views/Team.tsx
  - clients/gui/apps/console/src/views/Teams.tsx
  - clients/gui/apps/console/src/views/Sessions.tsx
  - clients/gui/apps/console/src/views/Overview.tsx
  - clients/gui/apps/console/src/views/Audit.tsx
  - clients/gui/apps/console/src/views/bits.tsx
  - clients/gui/apps/console/src/plane.ts
  - apps/troupe_plane/lib/troupe/plane/web/index.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/overview.ex
  - charts/troupe/templates/plane-deployment.yaml
  - docs/admin/console.md
gist: "Console door = TROUPE_CONSOLE_URL (/console), /admin stays; losing edits typed; write's audit row read back; every admin.* reached or in owed.ts"
---

#56 slice 2, on Decision 886's console. Slice 1 drew the shell, client versions, the
organisation's document and the teams, reading, with only a team's limits changing. This
slice makes it do a team admin's daily work and turns the plane's front door towards it.

## The front door: `TROUPE_CONSOLE_URL`, and `/admin` stays

The index at `/` and the LiveView console's Overview (its landing page) point at the
console. Where it is comes from the deployment, as the GUI's `TROUPE_APP_URL` does
(Decision 670), because the console is served beside the plane and the plane cannot tell
whether it is there: `TROUPE_CONSOLE_URL`, default `/console`, which the chart sets to
`console.basePath` when `console.enabled` and to empty otherwise. Empty is a plane without
the console, and both pages then keep `/admin` as they were.

The LiveView console is not retired. It stays routed and linked ("the previous console"),
for two reasons the console cannot answer yet: break-glass is a cookie sign-in of its own
there, and the areas the console does not draw are done there. What stays only in it: the
break-glass sign-in, a person's own spending cap, and Connections, Runs and review, Worker
profiles, Configuration bundles, Triggers, Integrations, Workers and pods, Provisioners and
hosts, Budgets, Identity, Sign-in and Policy and settings (the setting ladder's
`admin.setting.effective` and the admin group's `admin.identity.check` included).
`src/owed.ts` names each method that waits for one of them.

- **Not a redirect from `/admin` to `/console`.** That would take break-glass away with it,
  and the areas only the LiveView draws, on the day nothing else is reachable.
- **Not a value of its own in the chart.** The console is the chart's or it is off; a
  console somewhere else is a case nobody has.

## What the team's tabs change, and how each is confirmed

Every change is previewed (what moves, and what it does in words), then confirmed. The
confirm is plain where the change can be given back by making the opposite one: linking a
group, granting a profile, naming or removing a team admin, enabling a group as a team. It
is typed where the change takes something away that cannot simply be handed back:
unlinking a group (typed by the group's id; the preview is `admin.team.unlink.preview`'s
count of who loses the team and the sessions they can open), revoking a profile (typed by
its name; the warning is that the team's sessions on it turn read-only), removing the team
(typed by its name, after `admin.team.disable.preview`), erasing a session (typed by its
id, after `admin.session.erase.preview`'s survivors) and a shorter retention (slice 1).
These are the plane's own `confirm` arguments on its destructive methods, rendered as a
dialog. Removing a team admin is a plain confirm: the plane marks it a write, and naming
them again restores it.

- **The revoke's warning has no count.** `admin.sessions.list` names no team for a
  session, so the console cannot count one team's sessions on one profile, and a count of
  every team's would be a wrong number in a warning. The warning says what happens to them;
  a count needs the plane to say which team a session is in.
- **A name already a team's is refused before it is sent.** `admin.team.enable` is keyed on
  the name and, given an existing team's, links the group into that team and changes it.
  The console says so and will not send it.
- **The audit's note is read back.** `admin.team.update` answers its own diff; the other
  writes answer the thing changed. After one of them the console reads the newest row of
  that action on that subject by the person from `admin.audit.list` and shows it, so what is
  shown is the record; where it cannot be read, the note says the change was made and the
  record could not be read here.

## Overview, Sessions and Audit

The console now opens on the Overview: *Needs attention* (pods broken, never reported or
draining; a profile short of pods; a team at or near its ceiling; unattended runs nobody
has looked at, from `admin.sessions.list`'s `needs_review`), each linking to where it is
fixed, which for an area not drawn yet is the previous console's page; then fleet per
profile and spend per team, from `admin.overview`. Sessions is the plane's metadata, never
content, filtered by state and profile at the plane and searched and paged over its answer
(the plane's newest 200). Audit is `admin.audit.list` narrowed at the plane and read a
hundred rows at a time; the chain's check is a platform admin's, as the plane holds it.
All of it reads `admin.*` and nothing else.

## Deep links survive the sign-in

The provider's redirect URI is registered without a fragment, so a deep link opened signed
out came back to the first screen. The console keeps the fragment in the tab's storage
across the provider's page and puts it back when the provider sends the browser back.

## Every `admin.*` method is reached or owed

`test/coverage.test.ts` reads the plane's method table (`Admin.API`), the client's one
call per method and the console's sources, and holds four rules, as the plane's
`console_coverage_test` holds the LiveView console: every method the plane serves is
called from a screen or listed in `src/owed.ts` with its area and why; nothing listed is
called yet, so the list only shrinks; nothing listed, called or in the client is a method
the plane does not serve; and what `Admin.Console.owed/0` says the LiveView console owes
this one (the GitHub App's page, on Integrations) is owed here on the same area or done.

## Fields are named by their labels

A field's label names it and its hint describes it (`aria-describedby`); no placeholder
names a field. `test/labels.test.tsx` opens every form the console draws and fails on a
field whose name is its placeholder, empty, or has its hint run into it.

## Proof

- On the chunk's tip: the console could not revoke a profile (no control: "Grant a
  profile" never appeared) nor show Sessions (an area not drawn), and a deep link came back
  from the provider to Teams; those tests failed there. The plane's index pointed its
  console door at `/admin` and the Overview named no console; `web_test.exs` and
  `panel_test.exs`'s new tests failed there.
- `apps/console/test`: 70 tests in 11 files against the fake plane, whose administrative half follows
  `Troupe.Plane.Admin` for every method the console calls, its refusals and its audit.
- In a browser against the fake plane, as a platform admin and as a team admin, dark and
  light, at a narrow width with the map folded.
