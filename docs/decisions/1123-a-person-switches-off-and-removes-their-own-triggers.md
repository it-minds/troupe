---
number: 1123
title: "A trigger under a person's own sponsored principal is theirs to list, switch off and on, and remove through `trigger.own.*`, audited as an administrator's put and delete with `via: own`, refused on a gitops plane as those are"
date: 2026-11-28
status: accepted
issue: 1235
paths:
  - apps/troupe_plane/lib/troupe/plane/triggers/own.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/lib/troupe/plane/gitops.ex
  - clients/gui/packages/client/src/ownTriggers.ts
  - clients/gui/apps/desktop/src/views/OwnTriggers.tsx
  - clients/gui/apps/console/src/views/OwnTriggers.tsx
  - clients/tui/lib/troupe/client/own_triggers.ex
gist: "own = principal is Proposals.own_subject(team, caller) and its sponsor is the caller; trigger.own.list/disable/enable/delete, trigger ref as trigger.fire; audit trigger.put/delete via own; gitops refused (delete ok if resource missing); cap counts on+off, delete frees; initialize own_triggers; own_by on admin list"
---

Issue #1235. Extends Decision 1111, whose yes makes the trigger: the person it runs as may
now stop it without an administrator.

**Whose.** A trigger is a person's own where its principal is the subject a yes makes for
them in its team (`svc:<team>/own-<handle>`) and that principal's sponsor is them. Any other
trigger of their teams, an administrator's made by hand included, is refused `forbidden`
naming the principal it runs as; one outside their teams is `not_found`.

**The methods** sit beside `trigger.fire` under `trigger.` and take its `trigger` reference
(an id, `name` or `team/name`), read within the teams the caller is in: `trigger.own.list`
(observe), and `trigger.own.disable`, `.enable`, `.delete` (control). `own` names the limit,
as `me.` does for the caller's own things. `initialize` says `own_triggers`, so a client
offers the controls only where they work. A switch is a `Triggers.put/3` of `enabled` alone,
audited `trigger.put`; a removal is audited `trigger.delete`; both with the person as actor
and `via: own`, beside the revision a put records. Switching on is refused where the team
no longer lets members schedule; switching off never is. On a gitops plane both are refused
`managed_by_gitops` with the administrator's sentence (`Gitops.held/3`), the attempt
audited, except a removal of a row the cluster has no resource for. The five a person may
turn on count every row a yes made, on or off; a removal frees one. `admin.triggers.list`
marks such a trigger `own_by`, and the console's Triggers page says whose it is.

**Clients.** The desktop lists them on *Your triggers*, a rail item in *On the platform*
beside Profiles (extending Decision 1100's group by one item), and the proposal's record
line says the trigger's state with the controls under it; the console lists them under Your
sessions on Sessions › Mine; the terminal has `/triggers` and `/trigger off|on|remove NAME`.

## Not chosen

- Letting a member call `admin.trigger.put`/`delete` on their own: Decision 1111 refused
  members the admin API, and the admin path's checks are a team admin's, not a sponsor's.
- A member editing the schedule or the prompt: switching off and removing answer the issue;
  an edit is a second yes, which is a proposal's.
- Counting only enabled triggers against the five: switching off and on would then dodge it.

## If undone

The person answerable for the runs cannot stop them, a member at the cap cannot free a slot,
and an unwanted rerun spends their budget until an administrator acts.
