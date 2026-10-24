---
number: 936
title: The cluster suite proves N-1 to N on every pull request into main that it runs on, and on every release
date: 2026-10-24
status: accepted
issue: 765
paths:
  - .github/workflows/cluster.yml
  - .github/workflows/ci.yml
  - .github/workflows/dev-check.yml
  - scripts/kind-upgrade-check
  - scripts/remote-up
  - scripts/e2e
  - scripts/dev-restore-rehearsal
  - scripts/dev-restore-rehearsal.exs
  - apps/troupe_operator/test/upgrade/*.exs
  - apps/troupe_operator/test/support/e2e/upgrade.ex
  - docs/admin/upgrading.md
  - docs/developer/ci.md
gist: Beside the fresh install, cluster.yml installs the previous release from the registry, seeds it through the protocol, upgrades with the CRDs and helm upgrade alone and checks every seeded thing; N-1 to N only
---

Issue #765, the path to 1.0, whose second gate is a live plane thirty days on one release
with no hand step the chart, the operator or a checked precondition does not own. The
cluster suite (Decision 889) installed the chart fresh and ran the e2e; nothing anywhere
installed the release before and upgraded it, so a migration that needs a hand step, a CRD
change that breaks an old object, or a row the new code misreads was found by the first
deployment to upgrade.

- **What runs.** `cluster.yml` has a second job, `upgrade`, beside `kind`, on a runner and
  a kind cluster of its own; one after the other would be about an hour. It runs
  `scripts/kind-upgrade-check`, which a developer runs the same way under the plane lock.
- **Which release.** The previous release is the newest `v*` tag at or below `VERSION`
  that does not point at the commit under test: on a chunk branch the release it was cut
  from, on a release commit the one before, and on a re-run of a release after its tag
  exists still the one before. Pre-releases order as releases do (`1.0.0-rc.1` before
  `1.0.0`). `--from` or `TROUPE_UPGRADE_FROM` names another, `TROUPE_UPGRADE_CHART` another
  chart source.
- **As a deployment has it.** The previous release's chart from
  `oci://ghcr.io/it-minds/charts/troupe`, its CRDs (`helm show crds | kubectl apply
  --server-side`), its images from `ghcr.io/it-minds`, and its own tag's
  `dev/kind/values.yaml`, through `scripts/remote-up`, which now takes a chart, a version,
  a values file and pulled images (`TROUPE_CHART`, `TROUPE_CHART_VERSION`,
  `TROUPE_KIND_VALUES`, `TROUPE_IMAGES=pull`, `TROUPE_IMAGE_TAG` for every component).
  The services beside the chart in `dev/kind/dependencies.yaml` are the tree's under both
  releases, because a deployment does not upgrade its database or its OpenBao with Troupe;
  where they changed since the previous release the script says so, as a precondition the
  upgrade page must name.
- **The seed, through the protocol.** `apps/troupe_operator/test/upgrade/seed_test.exs`, on
  the previous release: a team with a profile granted, the profile following the release
  (`image: release`) with the scripted `fake` model so a turn needs no model; a session
  that ran a turn and went dormant; the organisation's memory; a client-version policy and
  the signing key a client pins; a webhook trigger with its key, fired once; and the audit
  rows that wrote. What it made is written to `.e2e/upgrade/seed.json`.
- **The upgrade, and nothing else.** The tree's images built and loaded, the tree's CRDs
  applied server-side, `helm upgrade` to `charts/troupe` with its migrate hook, the
  rollout. There is no step for a person; one needed is a failure of the checks after it.
- **The check.** `test/upgrade/check_test.exs`: `/.well-known/troupe` reports the commit
  under test; the audit chain verifies and still has the seeded rows; the team and profile
  are there; the client policy is served and verifies under the key pinned before; the
  profile is Ready with its pods replaced on the new release by themselves; the dormant
  session wakes there with its old log read back and answers a turn; the memory reaches a
  new session; the trigger fires on its old key.
- **A failure says why.** A hook that fails, a CRD refused, a rollout that does not finish
  or a seeded thing lost fails the job, and `.e2e/upgrade/logs/` is its artifact: the
  migration Job's log (a failed hook is kept), the plane's, the operator's, the workers',
  the release's history, the profiles, pods and events. The seed file with its trigger key
  is not in the artifact.
- **When.** On Decision 889's paths, plus `scripts/kind-upgrade-check`, the plane's
  migrations and `VERSION`, which are added to the one `cluster` filter in `ci.yml` and
  `dev-check.yml`, so a migration also runs the fresh suite; in the nightly; and on every
  release, which runs `cluster.yml` in full.
- **N-1 to N only.** A release skipped on the way is tested nowhere, and
  `docs/admin/upgrading.md` says so: one release at a time, the backup, the CRDs, the chart
  and its migration, what to watch, what the plane checks, `helm rollback` and what the
  migrations allow (no test rolls back), and the restore.
- **The restore, rehearsed.** `scripts/dev-restore-rehearsal` takes a database and a bucket
  of its own on the dev stack (never the suites'), seeds them through the plane's modules,
  dumps them (`pg_dump -Fc`, `mc mirror`) off the servers, drops both, restores both, and
  checks every table's rows, the audit chain, the memory in force, an object's bytes and an
  index rebuilt from the restored bucket, printing each step's time. It is the shape the
  upgrade page's restore follows; it reads no kubeconfig.
