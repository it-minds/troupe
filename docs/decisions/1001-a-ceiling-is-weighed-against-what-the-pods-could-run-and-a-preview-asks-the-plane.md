---
number: 1001
title: "A profile's max_sessions is weighed against the most its pods could ever run (its registered hosts, or the cluster policy's maxReplicas, times the size class's sessions per pod), never the replicas running now, and saved either way with a sentence where it is above; admin.clients.put takes dry_run, which a console asks for only where discovery names it; a limit's refusal says its ceiling in the setting's unit; the audit page and profiles.list speak the units and gone pods the other pages do"
date: 2026-11-15
status: accepted
issue: 957
supersedes: []
paths:
  - apps/troupe_plane/lib/troupe/plane/fleet/scaler.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - clients/gui/apps/console/src/views/Profiles.tsx
symbols:
  - Troupe.Plane.Fleet.Scaler.at_once/2
  - Troupe.Plane.ClientVersions.put/4
  - Troupe.Plane.SCIM.service_provider_config/0
  - ceilingAboveWords
  - limitWords
  - teamChangesInUnit
gist: "max_sessions vs the pods' most (hosts or policy maxReplicas x per pod, not replicas now), saved with a sentence; clients.put dry_run only where discovery lists it; refusal limit in the setting's unit; audit rows and profiles.list in units and gone; SCIM ServiceProviderConfig"
---

Issue #957 gathers what chunk 47's pull requests (#937, #939, #940, #941) left, and #870.
Most of it applies decisions already taken (992's names, 991's units, 994's gone pods);
four points needed choosing.

## What a ceiling is weighed against

The chunk 46 audit asked what happens when a profile's `max_sessions` is above what its
pods can run at once. **Against the most the pods could ever be, not the replicas running
now.** The scaler moves `replicas` with demand, down to none for a profile nobody uses, so
a `max_sessions` above `replicas × sessions_per_pod` is the ordinary state of an idle
profile, and a sentence on every save would be noise. What a ceiling can truly exceed is
the most the substrate allows: for a profile on registered hosts, the hosts enabled for it
times its size class's sessions per pod; on Kubernetes, the `TroupePolicy`'s `maxReplicas`
times the same, since the scaler never asks past it. Where neither bounds it the plane
answers `{sessions: null, by: null}` and nothing is said: the scaler adds pods up to the
ceiling itself (`Scaler.at_once/2`). `admin.profiles.list` carries it as `at_once`, and
`admin.profile.preview` as `capacity: {max_sessions, at_once, above}`; the console's
preview says one sentence with both numbers, and the write is saved either way, a ceiling
being a limit and not a promise. The pods-full refusal (`capacity`, a wake with every pod
full) names what the pods run at once and the profile's ceiling.

## A dry run the console asks for only where the plane says it has one

`admin.clients.put` takes `dry_run: true`: every check made, the policy as the put would
leave it with `changes` and `affected`, nothing written or audited, `dry_run` in the
answer. The console's recommend-this-plane's-version preview counts from it. **A plane
from before ignores an argument it does not know and would make the write**, so the
plane's discovery lists the writes that take one (`plane.dry_run`) and the console asks
only there; elsewhere it works the counts out as before. Where the plane reports no build
at all the button is replaced by one sentence saying the plane is too old to recommend
from. *Not chosen:* gating on the plane's version, which would guess at the next release's
number.

## Units on the refusal and in the audit

A limit's refusal stays `forbidden` (#941). Its `limit` is now the ceiling in the unit the
platform's setting is read in, `unit` beside it (`minutes` for the idle timeout, a
fraction where the ceiling is not whole minutes; `days`; `switch`); `ceiling` stays the
team field's own seconds or days. The Team page's idle field is asked in minutes, as the
Policy page asks the same setting.

Decision 991 kept the audit row in the plane's values ("a record, not a page"). That is
amended: the Audit page shows a `setting.put` or `setting.reset` row by the setting's
label with each value in its unit, from the plane's settings table, and a `team.update`
row's limits as the team's Limits tab names them. The row holds the plane's values still;
the key stays in the row's subject, and the search reads both.

## Gone pods and names

`profiles.list` carries `gone` on each pod, as `admin.profiles.list` has since Decision
994, and a gone pod counts for nothing in `capacity` and `healthy_pods`, whatever its
flags last said. Neither the desktop nor the terminal lists a profile's pods; the terminal
leaves a gone pod out of the health it draws, so a profile is not "degraded" for a pod the
operator removed, and the desktop's room is the plane's `capacity`. `owner_name` is on
`admin.session.erase.preview`, Connections' `sessions` and the memory `readers`, through
`Names.decorate`; the console's tables show the name with the subject on hover, as its
session and audit tables do (Decision 992; initials are a message's, DESIGN.md §2).

## SCIM's ServiceProviderConfig

`GET /scim/v2/ServiceProviderConfig` is served under the connector's token (RFC 7643 §5):
patch supported, bulk not, a filter supported with `maxResults` 200, `changePassword`,
sort and ETags not, the bearer token. 200 is what the plane now holds a filtered list to,
with `totalResults` counting every match; an unfiltered list still answers every
resource, which is how a provider reconciles. `/ResourceTypes` (users and groups) came in
the same change, being small; `/Schemas` is left, since no provider seen asks for it.
