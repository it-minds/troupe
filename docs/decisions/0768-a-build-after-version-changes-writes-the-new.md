---
number: 768
title: "A build after `VERSION` changes writes the new version into every app's `.app`: each project that reads `VERSION` lists `troupe_protocol`'s `:troupe_version` compiler after `:app`"
date: 2026-10-04
status: accepted
issue: 380
paths:
  - apps/troupe_a2a/mix.exs
  - apps/troupe_core/mix.exs
  - apps/troupe_daemon/mix.exs
  - apps/troupe_gateway/mix.exs
  - apps/troupe_operator/mix.exs
  - apps/troupe_plane/mix.exs
  - apps/troupe_protocol/lib/mix/tasks/compile.troupe_version.ex
  - apps/troupe_protocol/mix.exs
  - apps/troupe_protocol/test/mix/tasks/compile.troupe_version_test.exs
  - apps/troupe_worker/mix.exs
  - clients/tui/mix.exs
  - docs/developer/build.md
gist: "A build after `VERSION` changes writes the new version into every app's `.app`: each project that reads `VERSION` lists `troupe_protocol`'s…"
---

Issue #380 (D60), following 668. Every `mix.exs` reads `VERSION` when
Mix loads it, but Mix's `:app` compiler writes an `.app` again only when `mix.exs`, the
config or the compile directory is newer than it, and a new `VERSION` is none of those.
So an incremental build after a bump kept the previous `vsn` in every `.app` but
`troupe_protocol`'s (its `Troupe.Version` recompiles on `VERSION`, which touches the
compile directory): `scripts/install-local.ps1` in a checkout that had built the
previous release installed binaries that said it, and `Troupe.VersionTest` failed in a
test build. CI builds from clean and never saw it.
- **A compiler, not the script.** Mix has no way for a project to say its `mix.exs`
  reads a file: `@external_resource` is a module's, and the config files Mix watches
  are the ones the config imports. That left a compiler that checks, or a script that
  removes the `.app` files before it builds. The script would mend `install-local.ps1`
  alone; the compiler mends every incremental build, `mix test` in a checkout and a TUI
  built by hand among them, and needs no record of the version a `_build` last saw,
  because the `.app` is that record.
- **What it does.** After `:app` it reads the `.app`, and when its `vsn` is not the
  project's version has `:app` write it again (`compile.app --force`). Otherwise it
  reads one small file and does nothing.
- **Where it lives.** In `troupe_protocol` (`Mix.Tasks.Compile.TroupeVersion`), because
  every other project here, the umbrella's apps and the TUI, depends on that app, so it
  is compiled and on the code path before them; `troupe_protocol` reaches its own after
  `:elixir`, as `troupe_core` does `:reaper`. The alternative was a file every
  `mix.exs` required, one more thing each would load before Mix knows its project.
- **A new project that reads `VERSION` lists it too** (`docs/developer/build.md`).
  Nothing checks that one does.
- **Proof:** `Mix.Tasks.Compile.TroupeVersionTest` builds a project that reads its
  version from a file twice, each time in a `mix` of its own, the file changed between:
  with `:troupe_version` the second `.app` says the new version, and without it, kept
  as the reason, the first. On the tip, a test build, `VERSION` at 0.8.1-beta and a
  second build left seven of the eight `.app` files at 0.8.0-beta and
  `Troupe.VersionTest` failing ("troupe_core is 0.8.0-beta and VERSION is
  0.8.1-beta"); with this all eight said 0.8.1-beta and that test passed. And
  `install-local.ps1`, run in this checkout at 0.8.0-beta, then with `VERSION` at
  0.8.1-beta, then put back, installed a `troupe-daemon` and a `troupe` that said
  0.8.1-beta and then 0.8.0-beta, each time the version the checkout had not built.
