# Developer track

For whoever changes Troupe itself. Start with [CONTRIBUTING.md](../../CONTRIBUTING.md) and
[the tour](tour.md), then [ARCHITECTURE.md](../../ARCHITECTURE.md); the rest is here to be
looked things up in.

| File | What it covers |
|---|---|
| [tour.md](tour.md) | Where things live, running the suite, adding a tool, how the event log works |
| [architecture.md](architecture.md) | The apps and releases, the enforced boundaries, supervision trees, transports, where state lives, the TUI and GUI internals |
| [repo-structure.md](repo-structure.md) | The tree, where things live, what the image build sees |
| [tech-stack.md](tech-stack.md) | Every runtime, library and binary, and why |
| [local-setup.md](local-setup.md) | Prerequisites, the toolbox, development services, a plane on kind, development variables |
| [testing.md](testing.md) | Running the suites, what each needs, fixtures, the checks that are tests in all but name |
| [bench.md](bench.md) | `troupe bench`: what a turn costs and does, held to budgets; reading the report, moving a budget, the report's schema; the live bench against a real model, its cap and its history |
| [prompt-prefix.md](prompt-prefix.md) | Issue #465: what changes in front of a prompt between turns, the two ways out behind settings, the offline numbers, the gateway question, and the commands for the live ones |
| [build.md](build.md) | The images, the native builds, the reaper, generated files, `VERSION` |
| [ci.md](ci.md) | CI, pre-releases, releases, the nightly, and the documentation site |
| [deployment.md](deployment.md) | What a release publishes, what a roll does, rolling back |
| [conventions.md](conventions.md) | The gate, boundaries, the formatter's blind spot, commit style, naming, recipes |
| [fixing-issues.md](fixing-issues.md) | Working through GitHub issues in chunks: triage, fix, install locally, verify, pull request |
| [defects.md](defects.md) | Defects found in passing and not fixed yet |
| [command-audit.md](command-audit.md) | Issue #502: every command of the table run with and without a window, in a checkout and a worktree, locally and on a pod; what happened and what holds it |

The design: [../../ARCHITECTURE.md](../../ARCHITECTURE.md),
[the decisions](../decisions/README.md), [../../PROTOCOL.md](../../PROTOCOL.md). The
clients: [clients/tui](../../clients/tui/README.md) (and its
[decisions](../decisions/tui/README.md)), [clients/gui](../../clients/gui/README.md),
and the daemon's [decisions](../decisions/daemon/README.md).
