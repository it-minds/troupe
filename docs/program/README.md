# troupe

The umbrella repository. The documents that span the other repositories live here, and
one thing is built here: [`troupe-daemon`](daemon/README.md), the local harness binary,
packaged from `troupe-remote`'s three harness apps and released from this repository's
tags. `install.sh` and `install.ps1` install it.

| | what it is | state |
| --- | --- | --- |
| [`../troupe-remote`](../troupe-remote) | The harness and the platform. An Elixir umbrella: session actors, the event log, the worker runtime, the control plane, the Kubernetes operator, the A2A facade, the admin console. Deployed as four container images and a Helm chart. | stages 1–5 green, stage 6 part 1 green, the admin surface built |
| [`../troupe-gui`](../troupe-gui) | The client. A pnpm workspace: `@troupe/client` (the protocol in TypeScript), the desktop app, the bench. Plain web, wrapped by Tauri where a browser is not enough. | stages 1, 2 and 4 built; stage 3 not built |
| `.` | This directory. | the collected plan |

## The documents here

| document | what it answers |
| --- | --- |
| [`HANDOFF.md`](HANDOFF.md) | **Start here.** What was decided, the five spec revisions, the contract between the two repositories, what neither team may do without coming back, and the open questions that need a human. |
| [`docs/brief-remote.md`](docs/brief-remote.md) | Nine work packages for `troupe-remote`, in order, with their done items. Written to be picked up cold. |
| [`docs/brief-gui.md`](docs/brief-gui.md) | Six for `troupe-gui`. Three of them start today and depend on no server change. |
| [`docs/brief-daemon.md`](docs/brief-daemon.md) | The daemon: one harness (`troupe_core` + gateway + protocol) as a laptop binary under the TUI, the GUI and the worker pod. Five phases, the repository question, and the prompt to start the session with. Section 7's decisions are answered in place. |
| [`daemon/`](daemon/README.md) | **`troupe-daemon`, the binary.** A Mix project that pins the three harness apps from `troupe-remote` by commit and wraps them with Burrito, one binary per platform. Released from this repository's tags; `install.sh` / `install.ps1` at the root install it. |
| [`RELEASE.md`](RELEASE.md) | What is left between where the two repositories stand and a 1.0, in seven workstreams, each with what it brings, what is already in place, what is missing with file and line, the design, and the done items that prove it. |
| [`docs/orchestration-review.md`](docs/orchestration-review.md) | A review of the architecture against one admin's morning and one organisation's scale: why the StatefulSet is right and "pod" as an admin word is not, why scale-to-zero matters more than scale-up at eight profiles, and the seven capacity fields that should leave the admin surface. |
| [`docs/client-ux.md`](docs/client-ux.md) | The client, in depth. What a *person* sees: one list of four kinds of session, what changes when they open it on another computer, the **Me** menu that is not an admin menu, and eight stretch goals the platform does not yet support. |
| [`docs/control-panel.md`](docs/control-panel.md) | The console, in depth. The one surface that configures the whole product — policy, identity, bundles, triggers, provisioners, budgets, egress — and the coverage rule that keeps it honest. |
| [`docs/as-built.md`](docs/as-built.md) | What the thing looks like when all of it has landed: a walkthrough of one day in the platform, from a person opening the client to an admin answering an audit question. Written in the present tense on purpose. |
| [`docs/landscape.md`](docs/landscape.md) | The September 2026 competitive read that this plan folds in: seventeen platforms on six dimensions, and the twelve features worth taking. |

## How to read them

`../troupe-remote/spec.md` and `../troupe-gui/spec.md` remain the authority on
invariants. `RELEASE.md` does not weaken one; where it revises a decision it says which
decision, and why, in its own section for exactly that.

If you are a team or an agent about to do the work: read `HANDOFF.md`, then your brief, then
the documents your brief names. Nothing else is required reading.

Otherwise the order is: `RELEASE.md` for what happens and in what order, then `docs/client-ux.md`
and `docs/control-panel.md` for the two surfaces it produces, then `docs/as-built.md` for
what you are aiming at.

The two surface documents are deliberately separate products wearing one design system.
The client is the person's; the console is the platform's. Where one of them grows a
feature that belongs to the other, that is the failure both documents are written to
prevent.
