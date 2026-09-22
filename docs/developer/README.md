# Developer track

| File | What it covers |
|---|---|
| [architecture.md](architecture.md) | The apps and releases, the enforced boundaries, supervision trees, transports, where state lives, the TUI and GUI internals |
| [repo-structure.md](repo-structure.md) | The tree, where things live, what the image build sees |
| [tech-stack.md](tech-stack.md) | Every runtime, library and binary, and why |
| [local-setup.md](local-setup.md) | Prerequisites, the toolbox, development services, a plane on kind, development variables |
| [testing.md](testing.md) | Running the suites, what each needs, fixtures, the checks that are tests in all but name |
| [build.md](build.md) | The images, the native builds, the reaper, generated files, `VERSION` |
| [deployment.md](deployment.md) | How a release deploys itself, what a roll does, rolling back |
| [conventions.md](conventions.md) | The gate, boundaries, the formatter's blind spot, commit style, naming, recipes |
| [fixing-issues.md](fixing-issues.md) | Working through GitHub issues one at a time: triage, fix, install locally, verify, pull request |

CI and releases: [../../.github/CI.md](../../.github/CI.md). The design:
[../../ARCHITECTURE.md](../../ARCHITECTURE.md), [../../DECISIONS.md](../../DECISIONS.md),
[../../PROTOCOL.md](../../PROTOCOL.md). The clients: [clients/tui](../../clients/tui/README.md)
and [clients/gui](../../clients/gui/README.md).
