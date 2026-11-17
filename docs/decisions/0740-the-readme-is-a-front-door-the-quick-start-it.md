---
number: 740
title: The README is a front door, the quick start it points to is run by CI, and the product is shown with example data
date: 2026-09-30
status: accepted
issue: 188
paths:
  - .github/workflows/quick-start.yml
gist: The README is a front door, the quick start it points to is run by CI, and the product is shown with example data
---


*The README* is one screen: what Troupe is in two sentences, one Mermaid diagram of the
machine and the cluster, what it is not, the install from the release installers for
Linux, macOS and Windows, where to go next, and the licence with the name's terms. Five
badges, each something a reader can act on: CI on `main`, the quick start's own run, the
latest release, the protocol's version and the licence. The protocol badge is static, so
the quick start's job fails when it stops naming PROTOCOL.md's version.

*The quick start* (`docs/quick-start.md`) is install, a key, a first session, what it
cost, a cap, and what a plane adds, in that order, because the budget is the part a
newcomer would not guess exists. The first session is `troupe run plan … --headless`,
which reads and never writes, so nothing in it waits on an approval; the fix is made
next in the TUI, where an approval is a key. What it cost is read from the session's
log with `jq`, because Troupe keeps no price table and the log is where the answer is:
a figure from the nightly live check for scale, prices marked as an example, and
`models.prices` for a provider that reports tokens only. The cap is three keys in
`config.yaml`, shown in force with `--explain`.

*Run by CI.* A block the page marks `<!-- quick-start -->`, `<!-- quick-start: sh -->`
or `<!-- quick-start: powershell -->` is one `quick-start.yml` runs:
`scripts/quick-start-blocks` takes them out in order, and the job runs them as one
script, in `sh -e` on Ubuntu and in PowerShell with native exit codes fatal on Windows,
from the installers a reader downloads, with `TROUPE_PROVIDER=fake` answering from a
file. Then it checks that a session's log holds the reply and that the cap is in
force, and that the README's install blocks are the page's word for word. It runs on a
pull request that changes the page, the README, PROTOCOL.md or itself, and nightly,
because what breaks it with no change here is a release; by hand it installs a named
release. It cannot run a real model, the TUI, macOS or a plane, and the page says so.
Markers rather than a script of its own, because a script beside a page is a second
copy of it and the page is what a reader follows.

*Why Troupe* (`docs/why-troupe.md`) says who it is for, how it compares with an agent
CLI on a laptop without a claim about one it could not show, what a plane buys and
what it asks, and when you do not need it, each claim linked to the page or code
behind it. *The glossary* (`docs/glossary.md`) defines each word once, and a page links
to it the first time it uses one.

*Pictures*, under `docs/assets/`, made with a headless Chromium from made-up data only: no
real person, host or key.
