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
bug this project cares about. The nightly also runs the TUI's suite three more times and
the GUI's five, in a random order, and names every test that failed in any run
(`scripts/flake-hunt`, which runs any suite that way: `scripts/flake-hunt 20 mix test <file>`).

## 2. What each suite needs

The policy is to skip loudly: a `SKIPPED:` block naming the command that brings the
dependency up, never silence.

| Dependency | Suites | Without it |
|---|---|---|
| PostgreSQL on 25432 (the suite creates and migrates its checkout's own database) | all of the plane's | every test excluded, with the two commands to run |
| PostgreSQL | the worker's control-channel failover test | skipped, flunks |
| OpenBao on 28200 | plane tokens, protocol KMS, every `Troupe.Worker.SessionCase` suite, the gateway's `PrivateTest` sealing | `setup_all` says so; each test flunks (the plane's `PersonCredentialsTest` and `PrivateErasureTest`, which need MinIO too, are skipped by a tag instead) |
| MinIO on 29000 | protocol object store and storage, worker sessions, the gateway's `PrivateTest` sealing | same |
| a kubeconfig with the CRDs | the operator's `:cluster` tests, the plane's enrolment test | excluded; `--include cluster` runs them |
| a second BEAM node | the plane's cluster test | skipped, flunks |
| `bubblewrap` | the sandbox tests | skipped, flunks |
| `python3` | the conformance test | skipped, passes |
| `inotifywait` / `mac_listener` | the native half of the watcher tests; two gateway `FilesTest` tests (an event inside a second, a deletion) | watcher: passes without asserting, polling is always tested; `FilesTest`: skipped, saying so, except under `CI=true`, where they fail |
| `zig` | anything that runs `shell` | `:reaper_missing` |

`scripts/dev-up` provides the first four; [local-setup.md](local-setup.md). Suites isolate
themselves from the developer's machine: the core points `TROUPE_CONFIG_HOME` at a
temporary directory once per run and passes `state_dir` through config, because
`System.put_env/2` is global; worker tests set `TROUPE_STATE_HOME` per test and are
`async: false`. Suites assert on events and telemetry, never on log lines.

## 3. What keeps a test from flaking

Decision 915 is the long form.

- **A GUI test waits for what comes after an async step**: `await sees("…")` (and the
  console's `await seesLink("…")`), not `expect(says("…")).toBe(true)`, which each app's
  `waits.test.tsx` refuses unless the line says why it is meant at once
  (`// at once: <why>`). A control is the same: `await seesButton("…")` (the console's
  `await seesField("…")` too, or `await waitFor(() => row(…), …)`) and read it from what
  the wait answers, `expect((await seesButton("Save")).disabled).toBe(true)`, not
  `expect(button("…")).not.toBeNull()` or `button("…")!.disabled`, which the same check
  refuses for `button`, `field` and `row`. Absence (`toBeNull()`) is not checked: it
  cannot flake this way, only pass early. To show a race on purpose, make the fake slow:
  `daemon.delayMs["config.get"] = 300`, or `subscribeDelayMs`.
- **An async ExUnit module sets no environment variable** but a `TROUPE_TEST_...` one of its
  own; `Troupe.Credo.AsyncEnv` checks it. A test that needs another home is
  `async: false` or passes the home as an option.
- **Each checkout has its own plane test database**, `troupe_plane_test_<hash of its
  path>`, so two worktrees' plane suites no longer deadlock (`40P01`); CI keeps
  `troupe_plane_test`, and `TROUPE_PLANE_TEST_DB` names one.
- **The GUI's client tests read nothing from outside `clients/gui`** that
  `clients/gui/Dockerfile` does not copy and the root's `.dockerignore` keeps: the image
  runs them with that context alone (`packages/client/test/support/image-reads.ts`).
- **A flaky test is fixed at its cause**: no retry, no longer timeout, no skip.

## 4. Fixtures

- `test/fixtures/logs/<version>/` — six recorded logs per recorded version (0.2.0 and
  0.3.0; no release since has recorded its own) and the fold hash each produces.
  `mix troupe.fixtures.record <version>` writes them and refuses to overwrite. `fold_test.exs` replays every version through the upcaster
  and compares hashes, and reads `agent/server.ex` to assert every event type the replay
  handles is witnessed. A moving hash is not a test to update.
- `fixtures/sample_repo/` — a small Mix project the core's workspace and tool suites read.
- `apps/troupe_gateway/test/conformance/` — `troupe.py` and `conformance.py`.
- Fakes: a pod on the control channel, an enrolment verifier with no API server and a
  second plane node (plane); a stub plane and a fake worker (A2A); `WorkerProfile` and
  `TroupePolicy` maps as the API server hands them over, and `FakeCluster`, an API server
  in memory that a reconcile pass runs against (operator).

## 5. Checks that are tests in all but name

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
- **`mix troupe.bench`**, `troupe bench` from a checkout: the harness's offline suite, each
  number held to a budget in `apps/troupe_core/priv/bench/budgets.json`; CI's `lint` job
  and `scripts/ci` fail past one ([bench.md](bench.md)).

## 6. Beyond the unit suites

- `mix troupe.e2e` (operator): the cluster suite, against `scripts/remote-up`'s kind
  cluster; CI's `cluster` job.
- `scripts/kind-upgrade-check [--from <version>] [--recreate]`: the release before this
  one from the registry, an organisation seeded through the protocol, this tree's CRDs and
  `helm upgrade`, and every seeded thing asked for again; CI's `upgrade` job, and what a
  fixer runs under the plane lock before pushing a change to the chart, the operator or a
  migration ([ci.md](ci.md#the-upgrade-from-the-previous-release)). `scripts/kind-upgrade-check
  require-tls [chart]` is the other upgrade it checks, against `scripts/remote-up`'s cluster:
  a plane without TLS on its control port, a pod made then, and the upgrade to
  `requireTls: true`, which passes when the operator replaces the plaintext pod by itself.
- `scripts/pitr-drill`: restores the compose PostgreSQL to a point, rebuilds the index and
  asserts the lost session came back ([../admin/backup-restore.md](../admin/backup-restore.md)).
- `scripts/dev-restore-rehearsal [--keep]`: a database and a bucket of its own on the dev
  stack, seeded through the plane's modules, dumped (`pg_dump`, `mc mirror`), dropped,
  restored, and asked whether every table, the audit chain, the memory, an object's bytes
  and the index rebuilt from the bucket came back; prints each step's time. Run where
  `scripts/dev-up` and `mix` run (on Windows, under WSL). The restore the
  admin pages outline is this one ([../admin/upgrading.md](../admin/upgrading.md#7-restore)).
- The TUI's suite (`mix check` in `clients/tui`) and the GUI's (`pnpm test`), whose
  `test/support` is a protocol-accurate identity provider, plane, worker and daemon; the
  GUI's plane end-to-end suite runs in CI against a plane built from the same commit
  ([e2e.md](../../clients/gui/docs/e2e.md)).
- The VS Code extension's: `pnpm test` in `clients/vscode` (the folder, the program, the
  line it types, put through every shell the machine has, the Settings view's rows, its
  Models group and the manifest), and `pnpm test:vscode`, its suite inside a real VS Code
  against a fake `troupe`, with its own user data and extensions directories
  ([vscode.md](../user/vscode.md#how-it-is-built-and-tested)).
- `scripts/verify-local.ps1` checks an install made by `scripts/install-local.ps1` on this
  Windows machine.
- `scripts/check-installers` (`install.sh` under `sh` and `bash`, or the shells named) and
  `scripts/check-installers.ps1` (`install.ps1`, run once with `powershell` and once with
  `pwsh`): the installers against a release of stand-ins in a scratch directory, whose
  `troupe-daemon` only writes down what it is asked. Nothing is downloaded, and no real
  install, `PATH` or login entry is touched. The questions are answered through a
  pseudo-terminal for `install.sh`; `install.ps1`'s are checked by lifting the function that
  asks out of the script, because a check has no console.
- `scripts/live-check task|delegate|loop`: one headless run against a real model, and
  what it has to show; the nightly runs all three against the gateway
  ([ci.md](ci.md#the-live-check)). With `TROUPE_PROVIDER=fake` and a
  `TROUPE_FAKE_SCRIPT` it runs offline, which is how a change to it is tried first. Its
  cost column is the gateway's price, else the one `TROUPE_MODEL_PRICES` gives (*priced
  here*); a script with `"cost_micros": null` answers as a gateway streaming a response
  does, with no price, which is how that column is tried offline.
