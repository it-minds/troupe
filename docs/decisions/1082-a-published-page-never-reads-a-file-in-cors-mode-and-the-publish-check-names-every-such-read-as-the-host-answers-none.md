---
number: 1082
title: "A published page reads its own files only through what loads without CORS (a classic script, a stylesheet, an image and the like): the artifacts host answers no CORS read, so the publish check names every fetch, XMLHttpRequest, EventSource, import(), module script, web font and crossorigin load of the page's own files as a read, and the tool description and the user guide say so"
date: 2026-11-21
status: accepted
issue: 1092
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/blocked.ex
  - apps/troupe_plane/lib/troupe/plane/web/artifacts/csp.ex
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - clients/gui/packages/client/src/artifacts.ts
symbols:
  - Troupe.Plane.Artifacts.Blocked
  - Troupe.Plane.Web.Artifacts.CSP.sources/1
gist: "A page cannot fetch its own files (origin null, no ACAO ever); publish flags every CORS-mode load of its own files as kind `read`, from the sandbox flags; description and docs say <script src>/<link>/<img>, never fetch"
---

Issue #1092. Measured in Chromium against the host's own listener: a sandboxed page's origin is
`null`, so a `fetch`, `XMLHttpRequest`, `EventSource`, `import()`, module script and web font
of its own file go in CORS mode, `Origin: null`, `Sec-Fetch-Site: cross-site` and **no
cookie** (credentials are only sent same-origin). The host sends them to sign in (302, no
`Access-Control-Allow-Origin`) and the browser refuses them. A classic `<script src>`, a
stylesheet and an `<img>` go `no-cors` with the cookie and load.

**The host answers no CORS read, and the check says so.** `Blocked` names each of those loads
of the page's own file as kind `read` (a literal address, or the call where it has none);
one naming another site keeps its kind (`connect`, `script`, `font`). Whether a read is
refused is read from the policy's own sandbox flags (`CSP.sources("sandbox")`, no
`allow-same-origin`), so the check moves with the policy. It stays a warning, as Decision 1048
holds. The tool description, the publish answer, the clients' words and the user guide say a
page reads its own files through `<script src>`, `<link>`, `<img>` and the like, data a
script needs goes in a `.js` file that sets a global, and a font is a `data:` address.

**Not chosen: making the read work.** It needs `Access-Control-Allow-Origin: null` with
`Access-Control-Allow-Credentials: true` (the request carries no cookie otherwise, and is
sent to sign in). Every sandboxed document anywhere has origin `null`: a stranger's page,
another artifact on this host, a sandboxed frame on any site. Each could then read every
artifact the viewer may see with the viewer's cookie, which Decision 948's isolation forbids;
nothing in the request (no referrer, `cross-site` either way) ties it to the page. A
capability in the path stays turned down for 948's reason. Nor `allow-same-origin`, which
gives the page this host's origin, its cookie and every other artifact the viewer may read.
Answering only public links' files readably would make a read work on one address and fail
on the next, which is a worse sentence to give an author.

Undone, an agent again publishes a page whose data never loads, and the check calls it clean.
