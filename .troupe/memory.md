---
built_at: 2026-09-23T22:15:40.966000Z
head: 6d73eea
files: 1127
---

## Overview
Troupe is a coding-agent harness that runs AI agents on Kubernetes clusters or local machines. Built in Elixir (Erlang OTP 28.5, Elixir 1.20.4) with Node.js 24 for the GUI, it ships five container images (plane, operator, worker, a2a, gui) plus a daemon and two clients — a terminal UI (TUI) and a desktop app — all released together from one `VERSION` file. Every agent, model request, tool execution, and subagent is an isolated process managed by Erlang's supervision tree; sessions survive client disconnects because state is a hash-chained fold over events. Clients communicate via JSON-RPC over WebSocket or HTTP POST, all documented in PROTOCOL.md.

## Layout
- `apps/` — Elixir umbrella: `troupe_core` (agent harness, session management, LLM providers, tools, log fold), `troupe_gateway` (JSON-RPC transport, daemon, WebSocket, loopback), `troupe_protocol` (message schemas, JSON-RPC, policy, sessions cipher/storage, KMS, egress), `troupe_plane` (control plane: admin API, auth/OIDC, fleet/scaling, budget, identity, web console), `troupe_operator` (Kubernetes operator: WorkerProfile → pods, TroupePolicy), `troupe_worker` (agent runner in a pod, plane link, session restore), `troupe_a2a` (A2A facade: agent cards, task routing)
- `clients/tui/` — Terminal UI: `:ex_ratatui` TUI, embedded daemon, remote plane/worker client, built as Burrito binary per platform; its own Mix project with path deps on umbrella apps
- `clients/gui/` — Graphical client: `pnpm` workspace with `@troupe/client` (TS protocol client), web app (Vite), Tauri desktop app (Rust backend + TS frontend); served at `/app` by the plane
- `charts/troupe/` — Helm chart: CRDs (WorkerProfile, TroupePolicy, TeamVolume), deployment templates for all five images, values files for small/scaleway deployments
- `protocol/schema/v1/` — Machine-readable JSON Schema for every JSON-RPC command and event
- `docs/` — Operator, developer, and user documentation; `docs/program/` is the project plan; `docs/admin/` is the operator's reference
- `scripts/` — CI, image building, deployment (`build-images`, `deploy`, `release`), local dev (`dev-up`, `dev-down`)

## Commands
Always run mix through mise (`.tool-versions`: Erlang 28.5.0.5, Elixir 1.20.4-otp-28, Zig 0.16.0, Node 24.19.0):
- Umbrella build: `mise exec -- mix compile --warnings-as-errors`
- Full check (compile + format + credo + boundaries + test): `mise exec -- mix check`
- Test: `mise exec -- mix test` (set `TROUPE_IDLE_TEST_MS=1000` for fast loops)
- TUI build: `(cd clients/tui && mise exec -- mix deps.get && mise exec -- mix check)`
- GUI build: `(cd clients/gui && pnpm install && pnpm build && pnpm test)`
- Daemon release: `(cd apps/troupe_daemon && MIX_ENV=prod mix release)`
- Image build: `scripts/build-images` (into kind or a registry)
- Release: `scripts/release <version>` (opens PR changing VERSION, CI builds and deploys)
- Verify locks agree: `elixir scripts/locks-agree.exs`
- Verify version consistency: `elixir scripts/version.exs check`
- Schema diff check: `mix troupe.schema.diff`
- Local dev deps: `scripts/dev-up`, `scripts/dev-down`
- TUI smoke test: `TROUPE_REMOTE_URL=https://plane... mise exec -- mix troupe.remote.smoke`
- Python conformance: `TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=script.json mix test`
- Helm deploy: `helm upgrade --install troupe charts/troupe --namespace troupe-system --create-namespace --values charts/troupe/values.small.yaml`

## Conventions
- `mix check` is the full gate: compile --warnings-as-errors, format --check-formatted, credo --strict, troupe.boundaries, test. Always run through mise.
- `mix troupe.boundaries` enforces architecture at compile time: A2A may depend only on `troupe_protocol`; the plane does not run agents; the operator knows about neither.
- Version consistency: `elixir scripts/version.exs check` verifies all copies of VERSION agree; lock agreement: `elixir scripts/locks-agree.exs` verifies TUI and umbrella locks agree on shared packages. CI runs both.
- Schema diff check: `mix troupe.schema.diff` fails the build on changes older clients could not survive.
- TUI layout rules (`clients/tui/CLAUDE.md`): anything under `Troupe.UI` may call `Troupe.Client` and nothing else in the harness. `mix troupe.xref` fails on violations. Never `System.cmd` in lib code — go through `Troupe.OS.Process` (reaper). Tests use `assert_receive` on events, never `Process.sleep`.
- Type checker is the gate: pattern-match structs before struct updates, avoid `x && y` as a statement.
- Session management: state is a hash-chained fold over events; a crashed agent re-runs the tool call it was mid-way through unless `resume_on_restart: true` is not set (then it records as interrupted).
