# The program documents

These came from the umbrella repository, `it-minds/troupe`, which held the documents that
spanned the separate repositories and built the daemon. Everything it held is in this
repository now (Decision 666): the daemon is [`apps/troupe_daemon`](../../apps/troupe_daemon/README.md),
the installers are `install.sh` and `install.ps1` at the root, and the documents are here,
unchanged but for their links. Where they say "the other repositories", read the
directories:

| was | is | what it is |
| --- | --- | --- |
| `troupe-remote` | [the repository root](../..) | The harness and the platform. An Elixir umbrella: session actors, the event log, the worker runtime, the control plane, the Kubernetes operator, the A2A facade, the admin console, the daemon. Deployed as four container images and a Helm chart. |
| `troupe-gui` | [`clients/gui`](../../clients/gui) | The graphical client. A pnpm workspace: `@troupe/client` (the protocol in TypeScript), the desktop app, the bench. Plain web, wrapped by Tauri where a browser is not enough. |
| `troupe-tui` | [`clients/tui`](../../clients/tui) | The terminal client, which embeds the daemon when none is running. |
| `troupe` | this directory | The collected plan. |

## The documents here

| document | what it answers |
| --- | --- |
| [`HANDOFF.md`](HANDOFF.md) | **Start here.** What was decided, the five spec revisions, the contract between the two repositories, what neither team may do without coming back, and the open questions that need a human. |
| [`brief-remote.md`](brief-remote.md) | Nine work packages for `troupe-remote`, in order, with their done items. Written to be picked up cold. |
| [`brief-gui.md`](brief-gui.md) | Six for `troupe-gui`. Three of them start today and depend on no server change. |
| [`brief-daemon.md`](brief-daemon.md) | The daemon: one harness (`troupe_core` + gateway + protocol) as a laptop binary under the TUI, the GUI and the worker pod. Five phases, the repository question, and the prompt to start the session with. Section 7's decisions are answered in place. |
| [`apps/troupe_daemon`](../../apps/troupe_daemon/README.md) | **`troupe-daemon`, the binary.** Now the umbrella's fifth release, built from the harness in the same commit, one Mix release per platform. `install.sh` / `install.ps1` at the root install it. |
| [`RELEASE.md`](RELEASE.md) | What is left between where the two repositories stand and a 1.0, in seven workstreams, each with what it brings, what is already in place, what is missing with file and line, the design, and the done items that prove it. |
| [`orchestration-review.md`](orchestration-review.md) | A review of the architecture against one admin's morning and one organisation's scale: why the StatefulSet is right and "pod" as an admin word is not, why scale-to-zero matters more than scale-up at eight profiles, and the seven capacity fields that should leave the admin surface. |
| [`client-ux.md`](client-ux.md) | The client, in depth. What a *person* sees: one list of four kinds of session, what changes when they open it on another computer, the **Me** menu that is not an admin menu, and eight stretch goals the platform does not yet support. |
| [`control-panel.md`](control-panel.md) | The console, in depth. The one surface that configures the whole product — policy, identity, bundles, triggers, provisioners, budgets, egress — and the coverage rule that keeps it honest. |
| [`as-built.md`](as-built.md) | What the thing looks like when all of it has landed: a walkthrough of one day in the platform, from a person opening the client to an admin answering an audit question. Written in the present tense on purpose. |
| [`landscape.md`](landscape.md) | The September 2026 competitive read that this plan folds in: seventeen platforms on six dimensions, and the twelve features worth taking. |

## How to read them

[`spec.md`](../../spec.md) and [`clients/gui/spec.md`](../../clients/gui/spec.md) remain the authority on
invariants. `RELEASE.md` does not weaken one; where it revises a decision it says which
decision, and why, in its own section for exactly that.

If you are a team or an agent about to do the work: read `HANDOFF.md`, then your brief, then
the documents your brief names. Nothing else is required reading.

Otherwise the order is: `RELEASE.md` for what happens and in what order, then `client-ux.md`
and `control-panel.md` for the two surfaces it produces, then `as-built.md` for
what you are aiming at.

The two surface documents are deliberately separate products wearing one design system.
The client is the person's; the console is the platform's. Where one of them grows a
feature that belongs to the other, that is the failure both documents are written to
prevent.
