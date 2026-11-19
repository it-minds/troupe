---
number: 1074
title: "A Markdown artifact's image from another site is named at publish as an HTML page's is, and the rendered page shows in its place a sentence naming the site, never its address; the host's image policy stays its own files and data:"
date: 2026-11-19
status: accepted
issue: 1091
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/markdown.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/blocked.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_plane/lib/troupe/plane/web/artifacts.ex
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
symbols:
  - Troupe.Plane.Artifacts.Markdown.images/1
  - Troupe.Plane.Artifacts.Blocked.markdown/2
  - Troupe.Plane.Artifacts.Blocked.blocks?/2
gist: "Markdown ![](https://...) is a blocked image at publish (same finding shape) and a 'not shown' sentence naming its host on the page; img-src unchanged"
---

Issue #1091. Decision 1048 reads HTML, CSS and JavaScript at publish; a Markdown document
is rendered by the host into a page of its own, and an image from another site in it broke
silently under `img-src 'self' data:` (Decision 948).

**At publish.** Each `.md`/`.markdown` file of a `markdown` artifact, the files the host
serves rendered, is read for the images its page would ask for (`Markdown.images/1`, the
renderer's own pattern, so none in fenced code or a code span and none whose address the
renderer shows as text). Each one the policy blocks is a finding of kind `image`, directive
`img-src`, in 1048's shape, with its line. Whether one is blocked is `Blocked.blocks?/2`,
read from `CSP.sources/1`, so the check and the page change with the policy. A Markdown
file in an `html` or `file` artifact is served as it is, loads nothing, and is not read.
Raw HTML in Markdown is text here, so an `<img>` tag loads nothing and is not a finding.

**On the page.** Where such an image would be, the page says "An image from <host> is not
shown: this page shows only its own files", with the alt text on hover. The `<img>` is not
kept: under the policy it loads nothing and would only add a broken-picture icon beside the
sentence that explains it.

**Not chosen.** The check alone (the reader still sees a broken picture and is told
nothing). Allowing `img-src https:` for rendered Markdown: an image from a stranger's host
tells that host the reader's address and when they read it, which 948's own-files-only
policy exists to prevent, and it would make one artifact kind's page differ from the rest.

Undone, a document with a remote image again publishes as if it worked and opens with a
broken picture and no reason.
