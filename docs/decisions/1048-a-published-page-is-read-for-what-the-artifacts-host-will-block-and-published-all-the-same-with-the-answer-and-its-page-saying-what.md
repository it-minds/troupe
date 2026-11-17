---
number: 1048
title: A published page, stylesheet or script is read on the plane for what the artifacts host's policy will block, from that policy's own lists, and is published all the same, the publish answer naming each blocked reference by file and the artifact's page in every client saying how many
date: 2026-11-17
status: accepted
issue: 1081
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/blocked.ex
  - apps/troupe_plane/lib/troupe/plane/web/artifacts/csp.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/desktop/src/views/Publish.tsx
  - clients/gui/apps/console/src/views/Artifacts.tsx
symbols:
  - Troupe.Plane.Artifacts.Blocked
  - Troupe.Plane.Web.Artifacts.CSP.sources/1
gist: "Publish reads HTML/CSS/JS for what the host's CSP blocks, rules from CSP.sources/1 only; a warning (blocked, blocked_count), never a refusal"
---

The artifacts host's policy (Decision 948) is right, and a page that loads a stylesheet from
another site opens unstyled with the reason only in a browser console. The agent that
published it, and the person who opens it, are now told.

**The check is on the plane, at publish**, so `artifact.publish`, `artifact.put`, a rollback,
the pod's `session.artifact.publish` and an upload handle all get it. Each file whose content
type is HTML, CSS or JavaScript is read when it is stored (`Artifacts.Blocked`): a stylesheet,
script, image, font, frame, sound or film from another site, an embedded object, an inline
`<script>`, an inline event handler, a `javascript:` address, and a `fetch`, `XMLHttpRequest`,
`WebSocket`, `EventSource` or `import` a script names literally to another site. Each finding
is `{file, kind, reference, line}`, at most 25 a file. It is a tokenising scan, not a
browser: what a script builds at run time is not seen.

**One list.** Which directive decides each kind, and what that directive allows, is read from
`Web.Artifacts.CSP.sources/1`, the same lists the header is built from: a change to the policy
changes the check with it. Relative references are the artifact's own; `data:` is allowed
where the policy says so (images and fonts).

**A warning, not a refusal, for every kind.** The publish succeeds and its answer carries
`blocked`; the tool's answer to the agent names each reference and says to publish a corrected
version. A refusal would also refuse a page whose author knows and accepts it: one that
degrades well without its web font, or whose inline `<script>` only adds polish. That holds
for an inline script too, which never runs: the rest of the page still reads.

**Where it is kept.** On each file of the version (`files[].blocked`), so a version that
carries a file carries what was found in it with no second read, and as a count of the version
the address serves on the artifact row (`artifacts.blocked`), moved by a pin as `bytes` is, so
`artifact.list` reads no version. Artifacts published before this have a count of zero and
are not read again. The console's and the desktop app's artifact pages say "This version
references N things the artifacts host blocks" with the list on request, as text; the
terminal's `/artifacts` says the count on the row.

**Not chosen:** a headless browser (Decision 1020 turned one down for the same reasons), a
second list of rules beside the policy, and refusing some kinds.

Undone, an agent again believes a broken page works, and the person sees it broken unexplained.
