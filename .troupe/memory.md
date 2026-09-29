---
built_at: 2026-09-28T07:17:27.641136Z
head: ff16a6a
files: 1311
---

## Commands
Root: `mix deps.get && mix check` (compiles with -warnings-as-errors, format, credo --strict, troupe.boundaries, test). `scripts/build-images` builds the five Docker images. `scripts/ci` is the CI job locally. TUI: `cd clients/tui && mix deps.get && mix check`. GUI: `cd clients/gui && pnpm install && pnpm build && pnpm test`. Daemon (prod): `cd apps/troupe_daemon && MIX_ENV=prod mix release`. Regenerate committed files: `mix troupe.schema.gen`, `mix troupe.admin.assets`, `mix troupe.theme`, `mix troupe.admin.tokens`, `mix troupe.egress`, `elixir scripts/licences.exs`, `mix troupe.palette` (TUI), `pnpm tokens` (GUI), `pnpm icons` (GUI), `mix troupe.fixtures.record <version>`. Deployment: `scripts/release <version>` opens PR; merging builds images and deploys via GitHub Actions.

## Conventions
Error handling: `{:ok, result}` or `{:error, %Error{}}` on public APIs. Session.Log is the only durable event publisher; agents emit ephemerals that may be dropped. Responses are idempotent acknowledgements (replay a command_id returns the first). Schema: add-only within v1, upcasters one version at a time, never drop. Every admin method is both API and MCP tool with confirm on destructive ops. Boundaries: clients cross the protocol only; LiveView calls Troupe.Plane.Admin alone. Test naming: `<subject>_test.exs` defining `Troupe.<App>.<Subject>Test`; test names are sentences. Comments say why, not what. Commit messages: plain prose stating behaviour now true, body describes what was wrong; no conventional-commit prefixes or attribution trailers, only Signed-off-by. Read AGENTS.md for agent-specific rules (fixing issues, defects.md, PowerShell ASCII, `mix check` is the gate, sign off commits).

## Overview
Troupe is an Elixir and TypeScript coding-agent harness that runs agents on Kubernetes pods or a laptop daemon. The platform ships as five Docker images (troupe-plane, troupe-operator, troupe-worker, troupe-a2a, troupe-gui), a Helm chart, and single-machine tools: the troupe daemon (Elixir Mix release), troupe CLI (terminal UI), and a desktop app (Tauri). One repository, one VERSION file, one release that deploys everything. The architecture is event-sourced: sessions live on pods or daemons, the log is hash-chained and is the session, clients see sessions through a protocol-defined JSON-RPC and WebSocket API documented in PROTOCOL.md.

## Layout
- `apps/` — Elixir umbrella: troupe_core (agent engine and session), troupe_gateway (WebSocket for workers), troupe_worker (harness), troupe_plane (control plane, admin console, cluster), troupe_operator (Kubernetes CRD controller), troupe_a2a (A2A facade), troupe_protocol (shared protocol types), troupe_daemon (single-machine daemon wrapper).
- `clients/tui/` — Terminal client (troupe CLI): its own Mix project, embeds daemon when none running.
- `clients/gui/` — Web and desktop apps: TypeScript packages for protocol client (@troupe/client), web app served at /app on plane, Tauri desktop (multiplatform).
- `charts/troupe/` — Helm chart for the full platform on Kubernetes.
- `docs/` — Administrator, developer and user documentation; `docs/developer/` has conventions, build, testing, local setup, deployment.
