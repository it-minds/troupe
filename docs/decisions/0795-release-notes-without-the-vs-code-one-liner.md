---
number: 795
title: A release's generated notes no longer open with the one-line install of the daemon, the TUI and the VS Code extension
date: 2026-10-06
status: accepted
paths:
  - .github/workflows/release.yml
  - .github/workflows/prerelease.yml
gist: Generated release notes don't lead with the VS Code one-liner (0.8.1's launch); the installers' --vscode stays, listed with the other flags.
---

Decision 765 had each release's notes open with one line per shell that installs the
daemon, the TUI and the VS Code extension (`install.sh --tui --vscode`,
`install.ps1 -Tui -VSCode`). That was for the release that introduced the extension
(0.8.1), and the maintainer wants it gone from every release after it: most readers of a
release have no use for the extension, and the line put it ahead of the cluster and the
plain machine install.

`release.yml` and `prerelease.yml` no longer write that paragraph and its two commands.
What stays from 765: the `.vsix` built and attached as `troupe.vsix`, and the installers'
`--vscode` / `-VSCode`, named among the other flags under "On a machine". The one-liner
itself stays where a person looking for it reads: `docs/user/vscode.md`. A release whose
notes should lead with something says so in the notes written for it, above the generated
part.
