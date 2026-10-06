---
number: 796
title: Every CI job names its runner image, Ubuntu 26.04 where a trial ran it, and stops at about three times its usual length
date: 2026-10-06
status: accepted
paths:
  - .github/workflows/
  - apps/troupe_core/test/troupe/agent/acp_agent_test.exs
gist: No ubuntu-latest (26.04 where trialled, 24.04 for the cluster suite); every job has timeout-minutes; the ACP test's fake agents take no -pa
---

D77 in `docs/developer/defects.md` had three items: GitHub moves `ubuntu-latest` from
Ubuntu 24.04 to 26.04 over the four weeks from 2026-10-19
([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)) and
nothing had checked that our jobs work there; a native build whose runner hangs holds a
release; and `Troupe.Agent.ACPAgentTest` failed on a loaded machine. The maintainer's
instruction for the first: try the critical jobs on 26.04 and move if they work, otherwise
pin 24.04.

## The trial

A temporary workflow ran the critical jobs on `ubuntu-26.04` once, with no cache, so every
dependency was fetched and compiled on the new image (run 37483437510, image
`ubuntu-26.04` version 20260927, Ubuntu 26.04.1 LTS, kernel 7.0.0). Every job passed:

| job | what it ran | result |
| --- | --- | --- |
| umbrella | `erlef/setup-beam` (OTP 28.5.0.5 built for ubuntu-26.04), Zig, inotify-tools and bubblewrap with the AppArmor sysctl, `scripts/dev-up` in Docker, `mix compile --force --warnings-as-errors`, migrations, `troupe_protocol`'s suite, core's sandbox and file-watch suites | passed, 3.0 min: the protocol's 185 tests and core's 12, the sandbox's among them, which flunk without a working bubblewrap |
| TUI | the two locks agree, `mix compile --warnings-as-errors`, `mix troupe.cli.reference --check` | passed, 2.3 min |
| GUI | `tokens:check`, `icons:check`, `typecheck`, `build`, `test` | passed, 1.6 min |
| native TUI | `native.yml`'s `linux_x86_64` musl build (Burrito and its ERTS download) and its headless Fake smoke run | passed, 5.7 min |
| pages and chart | `setup-python` 3.12, `mkdocs build --strict`, `helm lint`, kubeconform in Docker | passed, 1.0 min |
| VS Code | typecheck, unit tests, the suite inside a downloaded VS Code under `xvfb-run`, `pnpm package` | passed, 0.9 min |

Not tried: the desktop app's Linux build, which stays on 22.04 as `native.yml` says (the
glibc floor), so how it builds on 26.04 does not matter yet; and the cluster suite, below.

## What runs where

- **Every job that said `ubuntu-latest` says `ubuntu-26.04`.** Named rather than left to
  the label, so the move happens on this commit and not in the middle of some release during
  GitHub's rollout; a run never mixes the two images (the umbrella jobs share one Mix cache
  keyed on `runner.os`, which is `Linux` on both); and the next move is again somebody's
  choice rather than GitHub's.
- **The cluster suite runs on `ubuntu-24.04`.** kind and Cilium lean on the kernel more than
  anything else here, and the trial did not run them: 25 minutes of a runner and the five
  images. Moving it is changing its label on a branch and running the nightly there
  (`gh workflow run nightly.yml --ref <branch>`) before that change merges.
- **Labels already named stay.** The TUI's jobs (`ubuntu-24.04`; its compile passed on 26.04
  too, so it can move when someone wants), the daemon's and the TUI's native builds
  (`ubuntu-24.04` and `-arm`: the daemon's tarball carries the build host's ERTS, so the
  build host's glibc is the floor for whoever installs it), the desktop app's Linux build
  (`ubuntu-22.04`), `live.yml` and `quick-start.yml`.
- `windows-latest` and `macos-latest` (the VS Code extension's matrix, the desktop app's
  Windows build) are not part of this: GitHub's notice is about Ubuntu.

## Timeouts

**Every job that runs on a runner has `timeout-minutes`**, at about three times what it
usually takes and above the slowest successful run seen, from the last twenty successful
runs of `release.yml`, `nightly.yml` and `prerelease.yml` (and fifteen of the light
workflows). A runner that hangs fails its job in minutes instead of GitHub's six hours.
Before, the native daemon and TUI builds had 40 minutes for every target and the desktop
app 60, and the release, pre-release and image jobs none: the 0.8.4 release's macOS arm64
TUI build sat in "Build the release" for 39 minutes, where it takes five to seven.

A matrix that spans platforms gets one per target: `timeout` in `native.yml`'s target
lists, read as `timeout-minutes: ${{ matrix.timeout }}`.

| job | usual (median, slowest) | timeout |
| --- | --- | --- |
| troupe-daemon linux x86_64, linux aarch64, macOS aarch64 | 1.6 to 1.8, at most 2.8 | 10 |
| troupe-daemon macOS x86_64 | 6.6, 11.5 | 25 |
| troupe-daemon Windows | 3.2, 3.9 (one 32.6: `setup-zig`'s download) | 15 |
| troupe linux x86_64 | 5.5, 6.1 | 20 |
| troupe linux aarch64 | 4.6, 5.2 | 15 |
| troupe macOS x86_64 | 13.2, 22 | 40 |
| troupe macOS aarch64 | 5.4, 7.2 | 20 |
| troupe Windows | 7.9, 10.8 | 25 |
| desktop Linux, Windows | 4.4 and 5.2, 7.6 and 8.8 | 20 |
| desktop macOS (universal) | 5.3, 11 | 30 |
| the TUI's binary in clean containers | 0.3, 0.4 | 15, above its commands' own `timeout`s (up to 5 minutes), which name the one that hung |
| an image | 0.4 from the cache, 3.6 without | 30 |
| a test leg | a few minutes; the worker's ten soak passes 18.4, 20 | 25, or 60 with a soak |
| compile/credo (`lint`, dev-check's `elixir`), the TUI's | 1.3 to 2, at most 3.1 | 20 |
| the GUI, protocol, the VS Code extension | 0.8 to 1.8, at most 2.4 | 15 |
| the GUI against a plane | 2.8, 3.3 | 20, above the stack's own ten-minute `--wait-timeout`, so its log is still printed |
| the cluster suite | 24.2, 25 | 45, as it was |
| the light checks and the release's own steps | under 1 | 10 |
| what changed, ci-ok, dev-ok, the targets, the version, dco | seconds | 5 |

A timeout that fires on a slow but healthy run is a re-run, not a reason to raise it: the
Windows daemon build that spent 29 minutes in `setup-zig` passed, and at 15 it would have
been run again. A value goes up when a target's usual time does.

## The ACP agent test

"A subprocess that exits is reported as partial" failed one or two runs in twelve on a
loaded machine. Reproduced with 64 busy shell loops in WSL beside it: it timed out on the
7th of 12 runs, after 30 seconds, in its last `refute_receive`, each run taking 27 to 30
seconds. The fake agents were a bare `elixir` with a `-pa` for each of the build's 58
`ebin` directories, each looked in first for every module the script's compile loads. On
`/mnt/c` that made each subprocess test take 4 seconds instead of 0.4, and under the loops
the partial one spent 24 to 27 of its 30 before its 3-second `refute_receive`. The agents
now speak JSON through the standard library's `JSON` and take no `-pa`, and the module's
timeout is 60 seconds, above the 38 its own waits add up to. Under the same loops the test
then passed 21 runs in a row, at 5 to 8 seconds each, and the whole file six in a row.
