# Troupe documentation

> Audited against troupe-remote commit `4083b1f` (branch `main`), 2026-09-13. Every document in this tree carries the same
> line; when the code moves, re-audit before trusting a line number.

> **Re-audited 2026-09-14.** This repository was then the remote only: `apps/troupe_tui`,
> `apps/troupe_ctl`, the `troupe` Burrito release and its installers were deleted, and
> `clients/python` moved to `apps/troupe_gateway/test/conformance/` as the test fixture it
> always was.
>
> **2026-09-21: the monorepo** (Decision 666). The TUI and the GUI came back as
> `clients/tui` and `clients/gui`, with their history and their own documentation, the
> daemon as `apps/troupe_daemon`, and the program documents as [program/](program/README.md).
> The chart serves the GUI, and a merged `VERSION` change releases and deploys everything
> (669, 670). The **developer** and **admin** tracks say so where it matters; the **user**
> track below still documents the terminal client as it was in `apps/`, and is deprecated.

Four tracks, one audit, one deep dive. Each track links to the others rather than repeating
them; start with the one that matches what you are trying to do.

| Document | One line |
|---|---|
| [developer/](developer/README.md) | How the code is organised, how to build and test it, what CI does, how a build reaches a cluster, and the conventions the gate enforces. |
| [user/](user/README.md) | **Deprecated.** What Troupe does from the user's seat, written when the terminal client lived in `apps/`: signing in, running sessions, every feature, end-to-end workflows, troubleshooting. Kept as an artifact; the TUI's current documentation is [`clients/tui`](../clients/tui/README.md). |
| [program/](program/README.md) | The plan the separate repositories were built to — the handoff, the briefs, the release plan — kept as it was written. |
| [history/](history/README.md) | The commit maps for the three imported repositories, for a SHA an imported document quotes. |
| [admin/](admin/README.md) | Operating a deployment: every environment variable and Helm value, roles and permissions, profiles and policy, bundles and triggers, integrations, backup and restore, monitoring, routine tasks. |
| [whitepaper.md](whitepaper.md) | How the subsystems fit together and why: the event log, the daemon, the plane, worker pods, the operator, cost accounting, with architecture and flow diagrams and the trade-offs each decision carries. |
| [AUDIT.md](AUDIT.md) | The Phase 1 inventory this suite was written from: what exists, where the older prose contradicts the code, findings that need a caveat, and the open questions the docs mark as unconfirmed. |

Older documents at the repository root and under `docs/` remain the design record:
`ARCHITECTURE.md`, `DECISIONS.md`, `PROTOCOL.md` (normative for clients), `REPORT.md`,
`spec.md`, [a2a.md](a2a.md), [deploying-on-scaleway.md](deploying-on-scaleway.md) and
[plans/](plans/README.md). Where one of them disagrees with the code, [AUDIT.md](AUDIT.md) §2
says so and the track documents follow the code.

The clients keep their own documentation beside their code: the graphical one's is
[`clients/gui/docs`](../clients/gui/docs/README.md), the terminal one's
[`clients/tui`](../clients/tui/README.md).

## Self-check

Each track's `README.md` ends with a coverage table for its own scope:

- [developer/README.md](developer/README.md): every job and step in `.github/workflows/ci.yml`
  and every development variable, with the section that documents it.
- [admin/README.md](admin/README.md): every environment variable read by `config/runtime.exs`,
  `config/config.exs` and `System.get_env` under `apps/*/lib`, every Helm value in
  `charts/troupe/values.yaml`, every admin method and every expected Secret.
- [user/README.md](user/README.md): every top-level feature, CLI command, TUI command, protocol
  command a user may issue, plane harness method and A2A route.

There is no `.env.example` in this repository, so the variable inventory was derived from the
configuration code rather than from a template; [AUDIT.md](AUDIT.md) §1.5 explains the method.
The consolidated result of the three checks, run against the finished documents, is recorded
at the end of this file.

### Result (2026-09-13, after the documents were written)

A script checked the finished documents against commit `4083b1f`:

| Check | Source of truth | Result |
|---|---|---|
| Every environment variable read by `System.get_env` / `System.fetch_env` in `config/*.exs` and `apps/*/lib` (81 distinct names, including `TROUPE_OIDC_MCP_SCOPE` added by `4083b1f`) | the configuration code | all 81 present in [developer/](developer/README.md) or [admin/](admin/README.md); the complete per-release tables are in [admin/configuration.md](admin/configuration.md) |
| Every job (`check`, `chart`, `protocol`, `images`, `release`) and every named, `run:` and `uses:` step of `.github/workflows/ci.yml` | the workflow file | all present in [developer/ci-cd.md](developer/ci-cd.md), which also states that no step deploys anywhere |
| Every plane `/rpc` harness method, every `admin.*` method, every protocol command in the gateway dispatch table, every plane HTTP route, every worker and A2A route | `apps/troupe_plane`, `apps/troupe_gateway`, `apps/troupe_a2a` | all present in [user/](user/README.md) or [admin/](admin/README.md). The CLI and TUI commands the original check also covered are no longer in this repository. Three names the pattern matched in `harness.ex` (`session.activate`, `session.read`, `acl.changed`) are pushes from the plane to a pod, not client methods; they are described in [whitepaper.md](whitepaper.md) §6.3 |

Nothing was found missing. There is no `.env.example`; the variable inventory was derived
from the code as described in [AUDIT.md](AUDIT.md) §1.5.

