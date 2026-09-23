# Testing

## 1. Running

```bash
mix test                                                     # every app, from the root
mix test apps/troupe_gateway/test/troupe/gateway/python_client_test.exs
cd apps/troupe_plane && mix test                             # one app
```

Tests live in `apps/<app>/test/troupe/**/*_test.exs`, with case templates and stubs in
`test/support/`. The test environment registers four misbehaving tools (raising, exiting,
asking, counting) through the same extension point an MCP adapter uses, and gives the
plane's sandboxed repo a pool of 30 because a placement test makes fifty creates at once.
Run the protocol suite from the root: its `policy_test.exs` imports the operator's test
fixtures without declaring the dependency.

CI runs each app's suite as its own job; the nightly and a release run every suite nine
more times, because the suite is concurrent and a race that shows one time in five is a
bug this project cares about.

## 2. What each suite needs

The policy is to skip loudly: a `SKIPPED:` block naming the command that brings the
dependency up, never silence.

| Dependency | Suites | Without it |
|---|---|---|
| PostgreSQL on 55432, `troupe_plane_test` migrated | all of the plane's | every test excluded, with the two commands to run |
| PostgreSQL | the worker's control-channel failover test | skipped, flunks |
| OpenBao on 58200 | plane tokens, protocol KMS, every `Troupe.Worker.SessionCase` suite | `setup_all` says so; each test flunks |
| MinIO on 59000 | protocol object store and storage, worker sessions | same |
| a kubeconfig with the CRDs | the operator's `:cluster` tests, the plane's enrolment test | excluded; `--include cluster` runs them |
| a second BEAM node | the plane's cluster test | skipped, flunks |
| `bubblewrap` | the sandbox tests | skipped, flunks |
| `python3` | the conformance test | skipped, passes |
| `inotifywait` / `mac_listener` | the native half of the watcher tests | passes without asserting; polling is always tested |
| `zig` | anything that runs `shell` | `:reaper_missing` |

`scripts/dev-up` provides the first four; [local-setup.md](local-setup.md). Suites isolate
themselves from the developer's machine: the core points `TROUPE_CONFIG_HOME` at a
temporary directory once per run and passes `state_dir` through config, because
`System.put_env/2` is global; worker tests set `TROUPE_STATE_HOME` per test and are
`async: false`. Suites assert on events and telemetry, never on log lines.

## 3. Fixtures

- `test/fixtures/logs/<version>/` — six recorded logs per released version and the fold
  hash each produces. `mix troupe.fixtures.record <version>` writes them once per release
  and refuses to overwrite. `fold_test.exs` replays every version through the upcaster
  and compares hashes, and reads `agent/server.ex` to assert every event type the replay
  handles is witnessed. A moving hash is not a test to update.
- `fixtures/sample_repo/` — a small Mix project the core's workspace and tool suites read.
- `apps/troupe_gateway/test/conformance/` — `troupe.py` and `conformance.py`.
- Fakes: a pod on the control channel, an enrolment verifier with no API server and a
  second plane node (plane); a stub plane and a fake worker (A2A); `WorkerProfile` and
  `TroupePolicy` maps as the API server hands them over (operator).

## 4. Checks that are tests in all but name

- **The Python conformance client** is a client written against `PROTOCOL.md` in the
  standard library alone. The test starts a daemon on a Unix socket with the fake
  provider, runs `conformance.py` against it, and asserts on its report: contiguous replay
  from `seq` 1, an accepted `input.send`, an answered approval, a verified hash chain. It is
  what proves a client needs no private access.
- **The admin parity test** asserts every public function of `Troupe.Plane.Admin` has an
  API method and an MCP tool, every method a summary and described arguments, every
  destructive one a `confirm`, and that nothing returns session content.
- **The schema tests**: a real session's every event validates against
  `Troupe.Protocol.Schema`, and the compatibility rules `mix troupe.schema.diff` enforces.
- **The asset tests**: every asset the console's and the front page's documents name
  exists, is allowlisted and is served, and the front page spends the reserved colour once.
- **The egress test**: `docs/egress-allowlist.md` names every host the components declare.
- **`mix troupe.boundaries`** is part of `mix check`, not `mix test`.

## 5. Beyond the unit suites

- `mix troupe.e2e` (operator): the cluster suite, against `scripts/remote-up`'s kind
  cluster; CI's `cluster` job.
- `scripts/pitr-drill`: restores the compose PostgreSQL to a point, rebuilds the index and
  asserts the lost session came back ([../admin/backup-restore.md](../admin/backup-restore.md)).
- The TUI's suite (`mix check` in `clients/tui`) and the GUI's (`pnpm test`), whose
  `test/support` is a protocol-accurate identity provider, plane, worker and daemon; the
  GUI's plane end-to-end suite runs in CI against a plane built from the same commit
  ([e2e.md](../../clients/gui/docs/e2e.md)).
- `scripts/verify-local.ps1` checks an install made by `scripts/install-local.ps1` on this
  Windows machine.
