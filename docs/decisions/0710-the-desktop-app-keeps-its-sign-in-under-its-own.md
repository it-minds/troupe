---
number: 710
title: The desktop app keeps its sign-in under its own bundle identifier
date: 2026-09-27
status: accepted
issue: 224
paths:
  - clients/gui/apps/desktop/src-tauri/src/secrets.rs
  - clients/gui/apps/desktop/src-tauri/tauri.conf.json
gist: The desktop app keeps its sign-in under its own bundle identifier
---

Issue #224,
defects D33. `secrets.rs` named every credential-store entry with a fixed service,
`com.objective-mj.troupe`, so a build made with another identifier, as a test build
installed beside the real app is, read and wrote the real app's refresh token: in
plane mode it would restore that sign-in and could rotate it, signing the real app
out. The service is now the running build's `identifier`, from its Tauri config,
which `tauri build --config` sets.
- **No migration.** The shipped identifier is the string the fixed name was, so an
  upgrade finds its sign-in where it left it, and a renamed build starts with none. A
  test in `secrets.rs` reads `tauri.conf.json` and fails if the identifier changes,
  because then the old entry has to be moved first.
- **Proof:** the two tests in `secrets.rs`; a renamed build (identifier
  `com.objective-mj.troupe.fix224`) installed from the chunk's tip wrote a dummy key
  under `com.objective-mj.troupe`, and the same build with this change wrote,
  read and cleared it under its own identifier and did not see or touch the entry
  under the real app's name, by Credential Manager's target names and write times.
