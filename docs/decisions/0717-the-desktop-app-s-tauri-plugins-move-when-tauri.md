---
number: 717
title: The desktop app's Tauri plugins move when tauri does, their Rust and JavaScript halves together
date: 2026-09-27
status: accepted
paths:
  - .github/dependabot.yml
  - clients/gui/apps/desktop/src-tauri/Cargo.toml
gist: The desktop app's Tauri plugins move when tauri does, their Rust and JavaScript halves together
---

Folding Dependabot's updates into the 0.6.1 chunk; the rule 708
followed for the notification plugin, made the rule for all of them.
- **The CLI checks the pairs.** `tauri build` refuses a build whose `tauri-plugin-*`
  crate and `@tauri-apps/plugin-*` package differ in their minor ("Found version
  mismatched Tauri packages"), and so does `tauri-action` in `native.yml`. Dependabot
  updates the crates and the npm packages in separate groups, so one of its pull
  requests can move one half alone: #120 took `tauri-plugin-http` to 2.7.0 with
  `@tauri-apps/plugin-http` on 2.6, and the build stopped there.
- **A plugin's next minor waits for tauri's.** `@tauri-apps/plugin-http` 2.7 depends
  on `@tauri-apps/api` 2.12, and `tauri-plugin-notification` 2.5 on tauri 2.12; beside
  tauri 2.11 the first would put a second, newer copy of the API into the bundle. So
  both stay on the minor that goes with tauri 2.11, pinned with `~` on both sides
  (`tauri-plugin-http ~2.6` and `~2.6.1`, `tauri-plugin-notification ~2.4` and
  `~2.4.0`), and the pins come off in the change that moves tauri, `@tauri-apps/api`
  and the CLI to 2.12 together. `tauri-plugin-single-instance ~2.4` (730) has no
  JavaScript half, and its 2.5 wants tauri 2.12 too.
- **Proof:** the renamed desktop build (`pnpm tauri build --bundles nsis`) with the
  pins; with #120's lock as Dependabot wrote it, the same build stops at the check.
