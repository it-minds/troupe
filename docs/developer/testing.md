# Testing

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

## 1. Layout

Every app keeps its tests under `apps/<app>/test/troupe/**/*_test.exs` with case
templates and stubs in `apps/<app>/test/support/` (compiled only in the test environment
by `elixirc_paths(:test)` in each `apps/*/mix.exs`). File counts on 2026-09-13:
protocol 8, core 29, gateway 11, tui 4, ctl 5, worker 21, plane 26, operator 4, a2a 5.

The test environment differs from dev in three ways set at compile time:

- `config :troupe_core, :extra_tools` registers four misbehaving tools —
  `Troupe.Test.RaisingTool`, `ExitingTool`, `AskingTool`, `CountingTool` —
  "through the same extension point a future MCP adapter would use" (`config/config.exs:12-21`;
  defined in `apps/troupe_core/test/support/misbehaving_tools.ex`).
- The plane repo uses `Ecto.Adapters.SQL.Sandbox` with `pool_size: 30`, because "the
  placement test makes fifty creates at once" (`config/config.exs:72-81`).
- `mix check` itself runs in `:test` (`mix.exs:18-21`).

## 2. Running the suite

From the umbrella root, every app:

```bash
mix test
```

One file, from the root (this is how CI runs the conformance test, `.github/workflows/ci.yml:242`):

```bash
mix test apps/troupe_gateway/test/troupe/gateway/python_client_test.exs
```

One app, from its directory:

```bash
cd apps/troupe_plane && mix test
```

Tasks that locate the repository root do so from `Mix.Project.build_path()` so they work
from either place (`apps/troupe_protocol/lib/mix/tasks/troupe.schema.gen.ex:60-64`,
`apps/troupe_gateway/test/troupe/gateway/python_client_test.exs:134-138`,
`apps/troupe_core/test/troupe/log/fold_test.exs:20`).

One exception is not confirmable from the code alone. `apps/troupe_protocol/test/troupe/policy_test.exs:12`
does `import Troupe.Operator.Fixtures`, defined in `apps/troupe_operator/test/support/fixtures.ex`,
and `apps/troupe_protocol/mix.exs:29-56` declares no dependency on `troupe_operator`
(test-only or otherwise). Whether that file compiles when `mix test` is run from
`apps/troupe_protocol/` alone, rather than from the umbrella root where every app's
`ebin` is present in `_build/test/lib`, was not executed for this audit. Unconfirmed;
run the protocol suite from the root until someone checks. `mix troupe.boundaries` does
not flag it because it inspects `lib/` beams only (`apps/troupe_core/lib/mix/tasks/troupe.boundaries.ex:212-217`).

## 3. What each suite needs, and what happens without it

The repository's stated policy is to skip "loudly": print a `SKIPPED:` block naming
the command that brings the dependency up, never silently
(`apps/troupe_plane/test/test_helper.exs:16-18`, `apps/troupe_operator/test/support/cluster_case.ex:5-7`,
`python_client_test.exs:11-12`). How that is implemented differs per suite, and in most
cases a missing dependency makes the tests fail with a named reason rather than
disappear from the count. The two that are excluded properly are the plane's database
and the `:cluster` tag; everything else in the table still flunks.

| Dependency | Suites | Behaviour when absent | Code |
|---|---|---|---|
| PostgreSQL on `localhost:55432`, database `troupe_plane_test` migrated | all of `apps/troupe_plane/test` | `Repo.start_link` fails; `ExUnit.start(exclude: [:test])` excludes every test and prints the two commands to run. This is the only suite that is truly excluded | `apps/troupe_plane/test/test_helper.exs:19-34` |
| PostgreSQL | `apps/troupe_worker/test/troupe/worker/failover_test.exs` (the control-channel end-to-end test, which starts a real plane) | `test_helper.exs` starts the plane repo if it can and is quiet otherwise; the test prints `SKIPPED` and `requires_peer/1` flunks | `apps/troupe_worker/test/test_helper.exs:3-10`; `failover_test.exs:38-55,185-186` |
| OpenBao on `localhost:58200` | `apps/troupe_plane/test/troupe/plane/tokens_test.exs`; `apps/troupe_protocol/test/troupe/kms/open_bao_test.exs`; every worker test on `Troupe.Worker.SessionCase` | `setup_all` prints `SKIPPED` and marks the context; each test's `requires_*` then flunks with "see the message from setup_all" | `tokens_test.exs:20-28`; `open_bao_test.exs:27-36,47`; `apps/troupe_worker/test/support/session_case.ex:33-41,91-93` |
| MinIO on `localhost:59000`, bucket `troupe-sessions` | protocol `object_store_test.exs`, `sessions/storage_test.exs`; worker `SessionCase` suites | same pattern; `requires_store/1` flunks | `apps/troupe_protocol/test/support/object_store_case.ex:25-59` |
| a kubeconfig (`KUBECONFIG` or `~/.kube/config`, context from `TROUPE_KUBE_CONTEXT`) with the Troupe CRDs installed | `apps/troupe_operator/test/troupe/operator/{cluster,admin_cluster,latency_cluster}_test.exs` | `test_helper.exs` probes once for a cluster; without one it prints `SKIPPED` with `scripts/kind-up` and the `helm upgrade` line, and starts ExUnit with `exclude: [:cluster]`. The tests are excluded, not run and not failed. `--include cluster` overrides | `apps/troupe_operator/test/test_helper.exs:11-29`; `cluster_test.exs:39-41` |
| a cluster with `ghcr.io/objective-mj/troupe-worker:dev` loadable | `apps/troupe_operator/test/troupe/operator/latency_cluster_test.exs` | `@moduletag :cluster`, so it is excluded with the rest when there is no cluster; with one, `setup_all` prints `SKIPPED` if the worker image is not loadable | `latency_cluster_test.exs:31,55-72` |
| a real API server (for `TokenReview`) | `apps/troupe_plane/test/troupe/plane/enrolment_test.exs` | `@moduletag :cluster`; the plane's `test_helper.exs` probes for a cluster and excludes the tag without one, printing `SKIPPED` and `scripts/kind-up`. `requires_cluster/1` still flunks under `--include cluster` | `apps/troupe_plane/test/test_helper.exs:27-56`; `enrolment_test.exs:15,146-147` |
| the ability to start a second BEAM node (`Replica`) | `apps/troupe_plane/test/troupe/plane/cluster_test.exs` | prints `SKIPPED`; `requires_peer/1` flunks | `cluster_test.exs:25-45,171-172` |
| `bubblewrap` | `apps/troupe_core/test/troupe/sandbox_test.exs` | prints `SKIPPED`; `setup` flunks every test | `sandbox_test.exs:20-30` |
| `python3` | `apps/troupe_gateway/test/troupe/gateway/python_client_test.exs` | prints `SKIPPED` and the single test passes with `assert true` | `python_client_test.exs:23-25,59-62` |
| `inotifywait` (Linux), `mac_listener` (macOS), `inotifywait.exe` (Windows) | the `native backend` half of `apps/troupe_core/test/troupe/watch/watcher_test.exs` | `Backend.usable?/2` is false; each test runs through `run_if_available/2` and passes without asserting; the polling backend is exercised regardless | `watcher_test.exs:36-62`; `apps/troupe_core/lib/troupe/watch/file_system_backend.ex:41-48` |
| `zig` | the `shell` tool and anything that runs a process through `reaper` | `mix compile.reaper` prints a warning and skips; tests that run `shell` then fail with `:reaper_missing` | `apps/troupe_core/lib/mix/tasks/compile.reaper.ex:45-53`; `apps/troupe_core/lib/troupe/reaper.ex:20-25` |

Every suite that touches the developer's environment isolates itself: the core, ctl and
tui helpers point `TROUPE_CONFIG_HOME` at a fresh temp directory once per run and unset
`TROUPE_STATE_HOME`, because `System.put_env/2` is process-global and would leak across
`async: true` tests; per-test state goes through `state_dir` in config instead
(`apps/troupe_core/test/test_helper.exs:1-10`, `test/support/session_case.ex:27-41`).
Worker tests set `TROUPE_STATE_HOME` per test and are all `async: false` for that reason
(`apps/troupe_worker/test/support/session_case.ex:58-62`).

Logger output is set to `:critical` (core, ctl, tui, a2a) or `:warning` (worker,
operator) in each `test_helper.exs` because the suites "assert on events and telemetry,
never on log lines" (`apps/troupe_core/test/test_helper.exs:12-14`). `TROUPE_TEST_LOGS`
turns the ctl suite's logs back on (`apps/troupe_ctl/test/test_helper.exs:15-17`).

## 4. Fixtures

### Recorded logs

`test/fixtures/logs/0.2.0/` holds six JSONL logs — `simple_turn`, `metered_turn`,
`tool_use`, `approval`, `subagents`, `error_and_recovery` — and `hashes.json` with the
fold hash each produces. `mix troupe.fixtures.record <version>` writes them, refuses to
overwrite an existing version, and is meant to run "once per release, and never again
for a version already recorded" (`apps/troupe_core/lib/mix/tasks/troupe.fixtures.record.ex:5-37`).
The scenarios are chosen "to cover the fold rather than to look like real sessions"
(`:60-75`).

```bash
mix troupe.fixtures.record 0.3.0
```

`apps/troupe_core/test/troupe/log/fold_test.exs` replays every version's logs through
`Troupe.Log.Upcast` and compares against the recorded hash (`:1-30`); it also reads
`apps/troupe_core/lib/troupe/agent/server.ex` as text and asserts every event type the
agent's replay clauses handle is in `Fold.witnessed_types/0` (`fold_test.exs:72-75,176`;
`apps/troupe_core/lib/troupe/log/fold.ex:59-70`). A moving hash "is not a test to
update" (`fold_test.exs:10-12`).

### Other fixtures

- `fixtures/sample_repo/` — a small Mix project, used by
  `apps/troupe_ctl/test/troupe/cli/options_test.exs`.
- `apps/troupe_operator/test/support/fixtures.ex` — `WorkerProfile` and `TroupePolicy`
  maps "as the API server would hand them over" (`:1-8`), used by the operator's
  `resources_test.exs` and the protocol's `policy_test.exs`.
- `apps/troupe_plane/test/support/{fake_pod,enrolment_stub,replica}.ex` — a fake worker
  on the control channel, an enrolment verifier that needs no API server, and a second
  plane node.
- `apps/troupe_a2a/test/support/{stub_plane,fake_worker}.ex` — the two things the facade
  talks to.

## 5. Checks that are tests in all but name

### The Python conformance client

`clients/python/conformance.py` is "a client written against `PROTOCOL.md` in the Python
standard library and nothing else … the only check that actually proves the claim the
whole stage rests on: that Troupe's own TUI has no private access"
(`python_client_test.exs:2-9`). The test starts a daemon on a Unix socket with the fake
provider, warms the session so `from_seq: 0` has something to replay, runs
`python3 conformance.py --socket <path> --session <id>` with `PYTHONPATH` set to
`clients/python` and `PYTHONDONTWRITEBYTECODE=1`, and asserts on the JSON report it
prints: server name `troupe-daemon`, principal `user`, all three scopes, the session in
the fleet, `replayed == head_seq` (`python_client_test.exs:64-84,117-132`). The script
itself checks a contiguous replay from `seq` 1, an accepted `input.send`, an answered
approval and the hash chain (`conformance.py:1-14,42-60`).

### The admin parity test

`apps/troupe_plane/test/troupe/plane/admin_parity_test.exs` enumerates the public
functions of `Troupe.Plane.Admin` (minus `actor_for/1`, `actor_for_session/1`,
`actor_for_subject/1`, `admin?/1`, `:31`) and asserts: each has a method in
`Troupe.Plane.Admin.API`, a command in `Troupe.Ctl.Admin`, and a tool in
`Troupe.Plane.Admin.MCP`; no method or command names something that does not exist; every
method has a summary ending in a full stop and every argument a description; every
`:destructive` method names a `confirm` argument that exists; and nothing in the context
returns session content (`:33-150`). It is why `troupe_plane` has a test-only dependency
on `troupe_ctl` (`apps/troupe_plane/mix.exs:61-65`).

### The boundaries task

`mix troupe.boundaries` is part of `mix check` and CI rather than of `mix test`; see
[architecture.md](architecture.md) §2 and [conventions.md](conventions.md) §2.

### The schema tests

`apps/troupe_core/test/troupe/session/log_schema_test.exs` runs a real session and
validates every event it wrote against `Troupe.Protocol.Schema.validate_event/2`
(`:1-40`). `apps/troupe_protocol/test/troupe/protocol/schema_test.exs` covers the
compatibility rules the `troupe.schema.diff` task enforces.

### The console assets test

`apps/troupe_plane/test/troupe/plane/console_assets_test.exs` reads the rendered root
document, extracts every asset it names, and checks each against `Plug.Static`'s
allowlist and the disk — a "missing kind of assertion" that `panel_test.exs`'s in-process
LiveView mounts cannot make (`:1-19`).

## 6. Timeouts and concurrency

Most files raise the default timeout with `@moduletag timeout:` — 60 s for plane and
core suites, 120-300 s for gateway and worker suites, 600 s for
`dormant_scale_test.exs` and `latency_cluster_test.exs`. Suites are `async: true` where
state is isolated through config; worker, gateway harness and cluster suites are
`async: false`.

## 7. Why CI runs the suite ten times

`.github/workflows/ci.yml:87-90`: "Ten runs, because the suite is concurrent and a race
that shows up one time in five is a bug this project cares about." The step is
`for i in $(seq 10); do mix test || exit 1; done`. `REPORT.md:6-7` records five
consecutive green runs as the stage 1 bar.

## 8. The PITR drill

`scripts/pitr-drill` is not part of the suite. It takes a base backup of the compose
PostgreSQL, seeds a session after a restore point, restores to that point on port 5433,
rebuilds the index from object storage with `MIX_ENV=test mix troupe.index.rebuild --database-url`,
and asserts the lost row came back (`scripts/pitr-drill:9-19,122-150`). Its closing note
names the two tests that cover the other halves under `mix check`:
`Troupe.Worker.IndexRebuildTest` and `Troupe.Plane.ReconcileTest` (`:171-176`). See
[../admin/backup-restore.md](../admin/backup-restore.md).
