---
number: 948
title: "An artifact is a versioned page on the plane, published to the organisation or to a profile's people, served from an origin that can touch nothing else: its rows in Postgres and its files in the object store under artifacts/<id>/<n>/, published by publish_artifact or /publish through the daemon's sign-in on a laptop and over the control link on a pod, read only on a host and port of its own, sandboxed under a policy that runs its own scripts alone, behind a cookie of that host's own that only a one-time ticket from the plane sets, and browsed in the console's Artifacts beside Mine"
date: 2026-10-25
status: accepted
issue: 62
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/*.ex
  - apps/troupe_plane/lib/troupe/plane/web/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/web/artifacts/csp.ex
  - apps/troupe_plane/lib/troupe/plane/web/csp.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_plane/lib/troupe/plane/application.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/priv/repo/migrations/20261025000948_artifacts.exs
  - apps/troupe_plane/test/troupe/plane/artifacts_test.exs
  - apps/troupe_plane/test/troupe/plane/artifacts_host_test.exs
  - apps/troupe_core/lib/troupe/artifacts.ex
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_worker/lib/troupe/worker/artifacts.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/gui/apps/console/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/packages/client/src/artifacts.ts
  - charts/troupe/values.yaml
  - charts/troupe/templates/plane-deployment.yaml
  - charts/troupe/templates/network-policy.yaml
  - config/runtime.exs
  - PROTOCOL.md
  - docs/user/artifacts.md
  - docs/admin/configuration.md
  - docs/admin/console.md
  - docs/admin/installing.md
symbols:
  - Troupe.Plane.Artifacts
  - Troupe.Plane.Web.Artifacts
  - Troupe.Plane.Web.Artifacts.CSP
  - Troupe.Tools.PublishArtifact
  - Troupe.Artifacts
gist: "Artifacts: versions at one id, org or profile:<name>; read only on their own host+port, sandboxed (no allow-same-origin), own scripts only; host cookie only from a plane ticket"
---

Issue #62's first slice, as the maintainer decided it on #765 on 2026-10-25: organisation and
profile visibilities first; an isolated origin and a strict policy; versions at one address;
no public links. Picked people, teams, share links, comments, in-console editing and the
desktop app's own gallery are later slices (D44 and after).

## What one is

A row in `artifacts` (owner by the person's id, so a re-key keeps it, nulled when the person
is removed so an organisation's report outlives the account; the team its bytes count
against; `organisation` or `profile:<name>`; the origin, `{session_id, agent, where}` with
`where` `pod`, `laptop` or `person`, the same attribution `fs_changed` gives an agent; the
version in force) and one row per version in `artifact_versions`, never updated: each file's
path, SHA-256, content type and size, a hash over them, and who published it when. The bytes
are in the plane's object store under `artifacts/<id>/<n>/<path>`. Republishing is the owner's
alone, keeps the kind, and makes `n + 1` at the same address; nothing is overwritten.

**Limits.** 16 MiB a file and 64 MiB a version, and each team's `artifact_quota_bytes` (1 GiB
by default, zero for none) over every version of its artifacts, which Budgets shows. One call
carries the files as base64 (the simpler of the two the slot offered, since the control link
carries base64 already), so what a single publish can hold is the door's body limit: the
plane's 4 MiB (Decision 909) on a laptop, which is why the chart's Ingress default rises from
1m to 4m, and the control link's 8 MiB on a pod. An upload handle that reaches the stated
caps is a later slice.

**Who sees one.** Its owner; everybody for `organisation`; the people a profile's grants
cover for `profile:<name>`; a platform administrator every one, since a takedown is theirs.
Anybody else is answered `not_found`, as for one that is not there, and visibility is read
again at every request on both hosts, so leaving a team takes its profile's artifacts away at
the next click. **Who publishes.** A person, to a profile they are covered by, or to the
organisation unless `artifacts_publish_organisation` is `platform_admins`; nobody in no team,
since the bytes count against one. `artifacts_enabled` off refuses every publish and lists
and serves nothing, keeping what is stored. Publish (with the version, hash, session, agent
and any visibility it moved from) and delete (`by`: `owner` or `takedown`) are audited, never
the content. The slot named the settings `artifacts.enabled` and
`artifacts.publish_organisation`; they are underscored to match every other setting's key.

## How it is published

`artifact.publish`, `artifact.get`, `artifact.list`, `artifact.open` and `artifact.delete` at
`/rpc`, as the person; these are a person's methods, so the console calls them as it calls
`me.memory` (Decision 942). A pod's agent sends `session.artifact.publish` over its control
link, and the plane takes whose it is, the team and the profile off the session row, as it
does for `session.memory.put` (Decision 943); the control link carries the artifact because
the person asked for it published, and nothing else of the session's. On a laptop the daemon
sends `artifact.publish` with its own sign-in; signed out, the tool is refused with a sentence
naming the file in the workspace. `publish_artifact` asks first unless a per-tool rule allows
it, is confined to the workspace as `remember`'s anchors are, keeps paths below the files'
shared directory so a page's relative links resolve, and puts `artifact` on its
`tool_call_completed`. It is offered only where a host installed somewhere to send it
(`Troupe.Artifacts.install/1` adds it to the extra tools), so the offline bench and a host with
no plane are not offered a tool that could only refuse. A person publishes one file with the
terminal client's `/publish`. The desktop app's "Publish…" is not in this slice.

## Where it is read: an origin that can touch nothing else

**Its own host and its own listener.** The plane serves artifacts on a second port
(`TROUPE_ARTIFACTS_PORT`, 4003 in the chart) from a plug router of its own, behind a second
Ingress for `plane.artifactsHost`; that listener has no route to `/rpc`, the console, the API
or the plane's session cookie, and the plane's own listener serves no artifact. The chart and
the plane both refuse an artifacts host equal to the plane's. Locally it is another port and
another name (`127.0.0.1` beside `localhost`): a port alone shares cookies.

**The policy** (`Web.Artifacts.CSP`, not Decision 803's, which stays the plane host's): every
answer carries `sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox
allow-downloads` and never `allow-same-origin`, so the page runs in an opaque origin where
`document.cookie` and storage throw and no answer from any host, this one included, can be
read; `default-src 'self'`, `script-src 'self'` (its own files, no inline script, no `eval`),
`connect-src 'self'` and nothing of the plane's, `form-action 'none'`, `object-src 'none'`,
`frame-ancestors` the plane's own origin alone, with `nosniff` and `no-referrer`.

**Sign-in.** The console asks `artifact.open` when the person clicks Open and opens the
answer in a new tab: a one-time ticket, signed with the plane's secret under a salt of its own
and good for a minute, which `/enter` redeems once (its nonce is recorded) for a cookie of the
artifacts host's own, `HttpOnly`, host-only (no `Domain`), signed under another salt, for an
hour, and every request still checks who that is now. No plane token or plane cookie ever
reaches the artifacts host. A viewer without the cookie is sent to the console's
`#/artifacts/<id>`, which signs them in and opens it again. The cookie is `SameSite=None;
Secure` wherever the host is HTTPS or this machine's own: a sandboxed page is a document of
no site, and its own stylesheets and scripts are fetched as from another site, which a `Lax`
cookie is not sent with (measured below). Not chosen: a capability in the path, which needs
no cookie but puts a bearer in every URL a page's links copy; it stays the fallback if
browsers that block third-party cookies turn out to withhold this one.

**Markdown** is rendered on the plane: headings, emphasis, lists with task boxes, quotes,
tables, links and images only to the web, mail or within the artifact, raw HTML escaped, code
highlighted server-side, and Mermaid flowcharts drawn as a static SVG (other diagram types
shown as their source). No script of anybody's is needed to read one. A `file` is served as it
was published, with its content type, under the same policy.

## The gallery and the controls

The console's **Artifacts** is in the person's own group beside Mine, so every role has it:
tabs Mine, Organisation and one per granted profile; a card is the title and the kind and
never the page; an artifact's page lists its versions, links its session, opens it on the
artifacts host and deletes it (the owner) or takes it down (a platform administrator, typed
by the id). Budgets shows each team's artifact bytes against its quota, which the team's
Limits tab sets (`admin.team.update`'s `artifact_quota_bytes`). The two settings are under
*Policy and settings* in a group of their own.

## Proof

- `apps/troupe_plane/test/troupe/plane/artifacts_test.exs`: files in the store and hashes in
  the row; republish as the next version at the same address, owner only, kind kept; audit
  with session and the visibility moved from, no content; shapes refused (paths with `..`, a
  leading `/`, `v<n>`, bad base64, no entry file); 16 MiB and 64 MiB; the team quota, shown in
  `admin.teams.list`; no team, no publish; a non-member of a profile neither lists nor gets
  nor opens its artifacts, and loses them on leaving; `platform_admins` only; switched off;
  delete by owner and takedown by a platform admin with every byte gone; tickets once, a
  minute, forged refused; no host, `unavailable`.
- `apps/troupe_plane/test/troupe/plane/artifacts_host_test.exs`, over a socket against the
  artifacts listener: the policy on every answer, directive by directive; the cookie
  `HttpOnly`, `Secure`, `SameSite=None`, no `Domain`, from a ticket alone, used once; the
  plane's own cookie host-only; signed out sent to the console; versions at their addresses;
  a non-member and a leaver told there is none; nothing of the plane's answering there and no
  artifact on the plane's listener; Markdown rendered, highlighted, its flowchart an SVG, its
  `<script>` and `javascript:` link text; off, nothing served.
- `control_test.exs` (`session.artifact.publish` for the owner of a session the pod holds and
  nobody else), `apps/troupe_worker/test/troupe/worker/artifacts_test.exs` (over a real control
  link into the object store), `apps/troupe_core/test/troupe/tools/publish_artifact_test.exs`,
  `apps/troupe_gateway/test/troupe/gateway/artifacts_test.exs` (through the daemon's sign-in,
  signed out a sentence, a session's agent naming its session),
  `clients/tui/test/troupe/publish_command_test.exs`, and the console's `artifacts.test.tsx`.
- In a browser: a probe page published on a plane run against the development services and
  opened in headless Edge (Chromium) through a ticket. Its own stylesheet and script loaded;
  its inline script did not run; `document.cookie` and `localStorage` threw `SecurityError`;
  `self.origin` was `null`; `fetch` of the plane's `/rpc` and of the artifacts host's own
  stylesheet both failed. With the cookie `SameSite=Lax` instead, the page's own stylesheet
  and script did not load at all, which is why it is `None`.

All of these failed on the chunk's tip (`f1684a4b`): there was no artifact, method, tool,
listener or console area.
