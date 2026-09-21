# Developer track

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> **Re-audited 2026-09-14.** This repository is the remote and ships no client. The
> Kubernetes-only change removed `apps/troupe_tui`, `apps/troupe_ctl`, the `troupe`
> Burrito release, `install.sh`, `install.ps1`, `scripts/build-local`,
> `scripts/test-install.*` and the `build`, `containers`, `installer-sh` and
> `installer-ps1` CI jobs, and moved `clients/python` to
> `apps/troupe_gateway/test/conformance/`. Statements below have been brought in line with
> that; line citations that predate it refer to the tree at commit `20fe871`.

> **2026-09-21: the monorepo** (Decision 666). The TUI, the GUI and the daemon are in this
> repository again — `clients/tui`, `clients/gui`, `apps/troupe_daemon` — and the
> installers are back at the root, installing the TUI and the daemon (671). A merged
> `VERSION` change releases and deploys everything (669). Where this page says the
> repository ships no client or no binary, that was true of the tree it was audited
> against and is not now.

Note on the baseline: while these files were being written the uncommitted change landed
as commit `6c29471` ("`groups` is not a scope, in the last place that still asked for
it"). The line numbers cited here were checked against the working tree that contains
it, which is identical to `3f7c91f` plus that change.

| File | One line |
|---|---|
| [architecture.md](architecture.md) | Seven apps, four releases, the enforced boundaries, the supervision trees, the three transports, where state lives |
| [tech-stack.md](tech-stack.md) | Every runtime, library, native binary and external service in use, with the reason the code gives |
| [repo-structure.md](repo-structure.md) | Annotated tree, each app's `lib/` layout, where tests, fixtures, schemas and CRDs live, what is generated and by which task |
| [local-setup.md](local-setup.md) | Prerequisites, `scripts/dev-up`, the test database, why the only local plane is `scripts/remote-up`, every development variable and `config.yaml` key |
| [testing.md](testing.md) | Suite layout, what each suite needs and what it does without it, fixtures, the conformance client, the parity test, the ten CI runs |
| [build.md](build.md) | The four server images, the reaper, the three generators; where the GUI's image, the daemon and the TUI are built |
| [ci-cd.md](ci-cd.md) | The three workflows: what a pull request runs under `ci-ok`, what `main` publishes, how a merged `VERSION` change releases and deploys |
| [deployment.md](deployment.md) | Images, CRDs, the chart, the migration hook, rollout behaviour, the kind and Scaleway flows, rollback |
| [conventions.md](conventions.md) | The gate, boundaries, the formatter blind spot, credo, stated rules, commit style, naming, recipes |

The other tracks: [../user/README.md](../user/README.md),
[../admin/README.md](../admin/README.md), [../whitepaper.md](../whitepaper.md).

## Self-check: CI coverage

Every job of the three workflows, and the section of [ci-cd.md](ci-cd.md) that covers it.
Line numbers are left out on purpose: the workflows were rewritten for the monorepo
(Decision 669), and a job's name is the stable way to find it.

| Workflow | Job | Covered in |
|---|---|---|
| `ci.yml` | triggers, concurrency, `env` | ci-cd.md §1 |
| `ci.yml` | `changes` | §2, the filter table |
| `ci.yml` | `check`, `chart`, `protocol` | §2; testing.md §7 (the soak); build.md §3 (the schema) |
| `ci.yml` | `tui`, `gui`, `gui-e2e`, `versions` | §2 |
| `ci.yml` | `native` | §2; §4 |
| `ci.yml` | `ci-ok` | §2 |
| `ci.yml` | `cluster`, `images` | §3 |
| `ci.yml` | `release`, `release-native`, `publish`, `deploy` | §3; deployment.md |
| `release.yml` | `daemon`, `tui`, `tui-containers`, `desktop`, `attach` | §4 |
| `deploy.yml` | `deploy` | §3; deployment.md §6 |

Secrets, variables and the `production` environment are §5. What the workflows do not
contain — a staging environment, signing, native builds on every merge — is §7.

## Self-check: development variables

Every variable the track was asked to cover, and where it is documented.

| Variable | Documented in |
|---|---|
| `TROUPE_SKIP_BUILD` | local-setup.md §4, §7; deployment.md §3 |
| `TROUPE_PROFILE_NAME` | local-setup.md §4, §7 |
| `TROUPE_GATEWAY_URL` | local-setup.md §4, §7 |
| `TROUPE_GATEWAY_MODEL` | local-setup.md §4, §7 |
| `TROUPE_GATEWAY_SMALL_MODEL` | local-setup.md §4, §7 (with the caveat that nothing reads the resulting `TROUPE_SMALL_MODEL`) |
| `ITM_LLM_GW_KEY` | local-setup.md §4, §5, §7; deployment.md §3 |
| `TROUPE_KIND_CLUSTER` | local-setup.md §7; build.md §1 |
| `TROUPE_REGISTRY` | local-setup.md §7; build.md §1; deployment.md §2 |
| `TROUPE_IMAGE_TAG` | local-setup.md §7; build.md §1; deployment.md §2 |
| `TROUPE_PUSH` | local-setup.md §7; build.md §1; deployment.md §2 |
| `TROUPE_PG_CONTAINER` | local-setup.md §7 |
| `TROUPE_PITR_DB` | local-setup.md §7 |
| `TROUPE_REAPER_TARGETS` | local-setup.md §7; build.md §2; repo-structure.md §4 |
| `BURRITO_TARGET` | local-setup.md §7; build.md §2 |
| `TARGET_ABI` | local-setup.md §7; build.md §2 |
| `ZIG_LOCAL_CACHE_DIR` | local-setup.md §7; build.md §2; ci-cd.md §5 |
| `ZIG_GLOBAL_CACHE_DIR` | local-setup.md §7; build.md §2; ci-cd.md §5 |
| `TROUPE_PROVIDER` | local-setup.md §6, §7 |
| `TROUPE_FAKE_SCRIPT` | local-setup.md §6, §7 |
| `TROUPE_STATE_HOME` | local-setup.md §7; architecture.md §6; testing.md §3 |
| `TROUPE_CONFIG_HOME` | local-setup.md §6, §7; testing.md §3 |
| `TROUPE_DAEMON_SOCKET` | local-setup.md §7; architecture.md §4 |
| `TROUPE_DAEMON_COMMAND` | local-setup.md §7 |
| `TROUPE_TEST_LOGS` | local-setup.md §7; testing.md §3 |
| `KUBECONFIG` | local-setup.md §7; testing.md §3; architecture.md §3.5 |
| `TROUPE_KUBE_CONTEXT` | local-setup.md §7; testing.md §3; architecture.md §3.5 |
| `MIX_ENV` | local-setup.md §7 |
| Not asked for but documented because a developer meets them: `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TROUPE_MCP_CONFIG`, `XDG_*`, `APPDATA`, `LOCALAPPDATA` | local-setup.md §7 |

`config.yaml` keys (`provider` … `fake_script`, 27 keys) with defaults and the
`{env:VAR}` rule: local-setup.md §6. There is no `.env.example` (local-setup.md, opening).

## What could not be covered from code

- Whether the operator's cluster suites and the plane's enrolment tests leave CI's
  `check` job green without a cluster (testing.md §3; [../AUDIT.md](../AUDIT.md) §3.14).
- Whether `apps/troupe_protocol`'s suite runs from its own directory given
  `policy_test.exs`'s import of an operator test module (testing.md §2).
- Whether the worker image contains a `reaper` binary, given that the Dockerfile
  installs no Zig (build.md §1).
- Whether CI has ever run, on which forge, and which jobs are required
  ([../AUDIT.md](../AUDIT.md) open questions 1-2; ci-cd.md, opening).
- Which values a live deployment uses, if one exists (deployment.md §1).
