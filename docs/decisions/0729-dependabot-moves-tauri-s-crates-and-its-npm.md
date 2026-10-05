---
number: 729
title: Dependabot moves Tauri's crates and its npm packages in one pull request, and keeps `@types/node` on the runtime's major
date: 2026-09-29
status: accepted
paths:
  - .github/dependabot.yml
gist: Dependabot moves Tauri's crates and its npm packages in one pull request, and keeps `@types/node` on the runtime's major
---

defects.md D37, in the 0.6.3 chunk. Decision
717's pairs were in two groups, npm `tooling` and cargo `tauri`, so one pull request
could move one half alone, as #120 did.
- **One group across the two ecosystems.** `multi-ecosystem-groups: tauri`, monthly,
  takes `@tauri-apps/*` from `clients/gui` and `tauri*` from `src-tauri`, and the
  ordinary npm and cargo entries ignore those names, so the group's pull request is
  the only one that moves them. Dependabot still opens it when only one ecosystem
  has an update, so a registry that lags the other can yet send half a pair; the
  Tauri CLI's check then refuses the build, as it should, and the pull request waits.
- **`@types/node` is the Node the tools run on**, `.tool-versions`' 24, not the
  newest: 26's types describe APIs 24 does not have. It is back on 24, Dependabot
  ignores its majors, and the major moves by hand in the change that moves that line.
