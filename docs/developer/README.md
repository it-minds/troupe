# Developer track

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> **Re-audited 2026-09-14.** This repository is the remote and ships no client. The
> Kubernetes-only change removed `apps/troupe_tui`, `apps/troupe_ctl`, the `troupe`
> Burrito release, `install.sh`, `install.ps1`, `scripts/build-local`,
> `scripts/test-install.*` and the `build`, `containers`, `installer-sh` and
> `installer-ps1` CI jobs, and moved `clients/python` to
> `apps/troupe_gateway/test/conformance/`. Statements below have been brought in line with
> that; line citations that predate it refer to the tree at commit `20fe871`.

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
| [build.md](build.md) | The four images, the reaper, the three generators — and nothing else, because there is nothing else to build |
| [ci-cd.md](ci-cd.md) | Every job and step of `ci.yml`; the chart published on a tag; no deploy step; no branch protection in the repo |
| [deployment.md](deployment.md) | Images, CRDs, the chart, the migration hook, rollout behaviour, the kind and Scaleway flows, rollback |
| [conventions.md](conventions.md) | The gate, boundaries, the formatter blind spot, credo, stated rules, commit style, naming, recipes |

The other tracks: [../user/README.md](../user/README.md),
[../admin/README.md](../admin/README.md), [../whitepaper.md](../whitepaper.md).

## Self-check: CI coverage

Every job and step of `.github/workflows/ci.yml`, and the section of
[ci-cd.md](ci-cd.md) that covers it.

| Job | Step | `ci.yml` | Covered in |
|---|---|---|---|
| — | triggers and `env` | `:9-18` | ci-cd.md §1 |
| `check` | postgres service | `:31-43` | ci-cd.md §2 `check` |
| `check` | checkout | `:45` | ci-cd.md §2 `check` #1 |
| `check` | setup-beam | `:47-50` | #2 |
| `check` | setup-zig | `:52-54` | #3 |
| `check` | Install inotify-tools | `:56-59` | #4 |
| `check` | cache deps/_build | `:61-67` | #5; §5 |
| `check` | `mix deps.get` | `:69` | #6 |
| `check` | Compile with warnings as errors | `:71-72` | #7 |
| `check` | `mix format --check-formatted` | `:74` | #8; conventions.md §3 |
| `check` | `mix credo --strict` | `:75` | #9 |
| `check` | Boundaries | `:77-80` | #10 |
| `check` | Migrate the plane's test database | `:82-85` | #11 |
| `check` | Test (10 consecutive runs) | `:87-90` | #12; testing.md §7 |
| `chart` | checkout | `:96` | ci-cd.md §2 `chart` #1 |
| `chart` | setup-helm | `:98` | #2 |
| `chart` | Lint, with each values file | `:100-104` | #3 |
| `chart` | The chart refuses unclustered replicas | `:106-113` | #4 |
| `chart` | Render and validate | `:115-128` | #5 |
| `images` | `needs`, `if`, permissions, matrix | `:132-143` | ci-cd.md §2 `images` |
| `images` | checkout | `:145` | #1 |
| `images` | Resolve the registry and the tags | `:153-173` | #2 |
| `images` | setup-buildx | `:175` | #3 |
| `images` | login | `:177-181` | #4 |
| `images` | build-push | `:186-195` | #5 |
| `protocol` | checkout | `:201` | ci-cd.md §2 `protocol` #1 |
| `protocol` | setup-beam | `:203-206` | #2 |
| `protocol` | setup-zig | `:208-210` | #3 |
| `protocol` | setup-python | `:212-214` | #4 |
| `protocol` | cache | `:216-222` | #5 |
| `protocol` | `mix deps.get` | `:224` | #6 |
| `protocol` | Schema compatibility | `:226-230` | #7; build.md §3 |
| `protocol` | Committed schema is current | `:232-236` | #8 |
| `protocol` | Python reference client, end to end | `:238-242` | #9; testing.md §5 |
| `release` | `needs`, `if`, permissions | ci-cd.md §2 `release` |
| `release` | checkout, setup-helm | #1 |
| `release` | Package the chart at this version | #2 |
| `release` | action-gh-release, the chart tarball | #3 |

Nothing in the workflow is left uncovered. What the workflow does not contain — a deploy
step, branch protection, a cluster — is in ci-cd.md §6.

The four columns above became three for the `release` rows: the `ci.yml` line numbers in
this table are from the 2026-09-13 audit, and the workflow has been rewritten twice since
— once to make it green, once to remove the client build. Treat them as a reading order
rather than as coordinates, and read `ci.yml` itself for the lines.

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
