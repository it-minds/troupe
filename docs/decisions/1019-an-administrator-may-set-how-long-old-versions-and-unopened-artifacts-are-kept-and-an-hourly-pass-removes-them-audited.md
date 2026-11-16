---
number: 1019
title: "An administrator may set how long an artifact's old versions are kept (artifacts_keep_versions_days) and how long one nobody opens is kept (artifacts_keep_unopened_days), both off by default and the organisation's alone; an hourly pass removes what has run out, one artifact or version at a time under its row's lock, never the newest or the pinned version, each audited by system:retention with by: retention; and every row says when it goes (goes_at), which opening it moves"
date: 2026-11-16
status: accepted
issue: 981
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/retention.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/retention/sweep.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/artifact.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/lib/troupe/plane/settings/setting.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/priv/repo/migrations/20261116001019_artifact_opened_at.exs
  - apps/troupe_plane/test/troupe/plane/artifact_retention_test.exs
  - clients/gui/packages/client/src/retention.ts
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/PublishedArtifacts.tsx
  - clients/gui/apps/console/src/views/settingUnits.tsx
  - clients/tui/lib/troupe/ui/tui/artifacts_page.ex
  - PROTOCOL.md
  - docs/admin/console.md
  - docs/user/artifacts.md
symbols:
  - Troupe.Plane.Artifacts.Retention
  - Troupe.Plane.Artifacts.Retention.sweep/1
  - Troupe.Plane.Artifacts.Retention.Sweep
gist: "artifacts_keep_versions_days / artifacts_keep_unopened_days (unit days_or_off, 0 = off, org-wide only); hourly singleton sweep; newest + pinned never go; audit artifact.delete / artifact.version.delete by system:retention, by: retention; goes_at on rows; opened_at set by artifact.open and the host's entry page"
---

Issue #981, a slice #62 left: "retention" was in its list of administrator's controls and
nothing shipped for it. An artifact and every version were kept until an owner deleted it or
an administrator took it down, which is the right default and the wrong only answer for an
organisation that has to say how long it keeps what its agents publish.

## The two settings

Under *Policy and settings*, beside the other artifact settings, in the `artifacts` group:

- `artifacts_keep_versions_days`: a version older than the newest is removed that many days
  after it was published, its files with it. **Never removed**: the newest version, and the
  version the owner pinned, so an artifact always has the version its address serves. A
  removed version cannot be opened or rolled back to.
- `artifacts_keep_unopened_days`: an artifact nobody has opened, republished or changed for
  that many days is removed whole, every version, its links, the people it was shared with
  and its comments, as `artifact.delete` removes it.

Both are integers in a new unit, `days_or_off`: a whole number of days, where `0`, `off` or
nothing is off, and anything else (a negative number, a fraction, words) is refused in the
setting's own sentence. Both ship as 0: a plane that sets neither runs nothing and shows
nothing new (DESIGN §8). A new unit rather than `days` because every `days` setting reads 0
as zero days, and "0 days" on a settings page that means "kept forever" would be a sentence
that names a thing that is not there; the console reads `days_or_off` 0 as "off".

**Per team: not in this slice.** The issue said "perhaps". A team's narrower period is a
second rung (`teams.*` and the ladder the other team settings have), and a team's wider one
would let a team keep what the organisation decided not to; neither has been asked for by
anybody running a plane. The setting's own sentence says a team cannot change it yet, and
the PR leaves that part of #981 open rather than closing the issue.

## Where "opened" comes from

A column, `artifacts.opened_at` (migration `20261116001019_artifact_opened_at`), set by
`Retention.touch/1` when somebody opens it: `artifact.open` (the ticket every client asks for
to open one), the artifacts host's entry page (`/a/<id>/` or `/a/<id>/v<n>/`, which a viewer
with the host's cookie reaches without a new ticket), and a public link's entry. Its other
files are not an open: a page's stylesheet is not somebody reading it again. At most one
write an hour per artifact. The count runs from the later of `opened_at` and `updated_at`
(its last publish or change), so a row from before the column counts from its last publish
and the migration fills nothing in, and an owner republishing or pinning it is using it too.
Removing an old version does not move `updated_at` (it writes with `update_all`), or the
pass would keep alive what it trims.

## The pass

`Retention.Sweep`, a `:global` singleton with a keeper on every replica, as the erasure pass
is (Decision 811). Every hour, and once as it starts: the periods are days, and a pass with
both off is two settings read. It does nothing while `artifacts_enabled` is off, since an
artifact nobody can open is not one nobody wants. It takes at most 200 of each kind a pass,
oldest first; the rest are the next pass's.

Each removal is its own transaction holding the artifact's row `FOR UPDATE`, as a republish
holds it, and reads the row again: an artifact opened or republished between the pass
choosing it and removing it is kept. A version's objects are its own and those it carried
from an earlier version (`stored_in`); an object goes only when no version left names it, so
a later version carrying a file keeps that file. Every stored version of each object is
deleted (the bucket keeps versions, Decision 786), and the artifact's `total_bytes`, which
the team's quota counts, drops by what went.

What the object store refuses is left as it was, the row and the objects, and tried again
by the next pass. The pass says it once, at `warning`, naming the artifact, when it first
fails, and not again while it keeps failing, so a store refusing one artifact for a week is
one line and not 168. What went is said at `info`.

## The audit

One row per removal, `system:retention` the actor, in the shape a takedown has and never the
content: a whole artifact as `artifact.delete` with `title`, `visibility`, `versions`, `by:
retention`, `days` (the period) and `session`; one version as `artifact.version.delete` with
`title`, `visibility`, `version`, `newest`, `by: retention`, `days` and `session`. Changing
either setting is already audited as `setting.put` / `setting.reset`, so turning one on asks
nothing more: the first pass's removals are audited as every other one is.

## Saying when

`artifact.list`, `artifact.get` and `admin.artifacts.list` rows carry `goes_at`, when the
unopened period removes it, or `null`; `artifact.get`'s versions each carry `goes_at`, `null`
for the newest, the pinned one and every one while that period is off, and the answer carries
`retention: {versions_days, unopened_days}` for the page's sentences. The words are one
module in `@troupe/client` (`retention.ts`), so the desktop app and the console say the same:
a card's line "Goes 3 Dec unless opened", beside its other pieces, and on the page "It goes on
3 Dec, every version with it, unless somebody opens it", with the period and that opening it
starts it again, and beside each version that goes "goes 22 Jan". The administrators' table
says it in the Published column. The terminal's gallery row and its versions list say the same
words, since its row shows a date already. With both off no field is set and nothing appears.
