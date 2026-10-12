---
number: 889
title: The cluster suite runs on a pull request that changes what it deploys, into main and into a chunk alike, and applies the CRDs and admission policy before it builds anything
date: 2026-10-12
status: accepted
issue: 679
supersedes: [676]
paths:
  - .github/workflows/cluster.yml
  - .github/workflows/ci.yml
  - .github/workflows/dev-check.yml
  - docs/developer/ci.md
  - apps/troupe_operator/test/e2e/egress_test.exs
  - apps/troupe_operator/test/e2e/isolation_test.exs
gist: A PR touching charts/, docker/, dev/kind/, the kind scripts or the operator runs cluster.yml; CRDs reach the API server first; the suite proves isolation
---

Issue #679, and #670 for what the suite then proves. Decision 676 put the cluster suite in
the nightly and the release only, "where it is owed". The 0.16.0 release run then failed
ten minutes into its cluster job: the API server refused a TroupePolicy CRD rule (a
`x-kubernetes-validations` rule over several lines with no `message`), fixed by #678.
Nothing before the release had applied that CRD to an API server. The chart job's
kubeconform checks a CRD's shape against a schema, and only an API server compiles its
CEL; `ci.yml` ran the cluster suite only when `inputs.cluster` was set, which no pull
request does; `dev-check.yml` had no cluster at all; and the fixer had no kind cluster.
This replaces 676's sentence about the cluster suite and nothing else of it.

- **When.** A pull request that changes what the cluster runs: `charts/**` (the CRDs and
  the admission policy template among it), `docker/**`, `dev/kind/**`, `scripts/kind-up`,
  `scripts/remote-up`, `scripts/build-images`, `apps/troupe_operator/**` (the operator and
  the suite) and `cluster.yml` itself. Into `main` through `ci.yml`'s `changes` (output
  `cluster`), and into a `development-*` chunk through `dev-check.yml`, with the same list.
  The nightly and a release still run it whatever changed. Not on a push to `main`, whose
  pull request ran it, and not for any change under `.github/workflows/`, which runs every
  other job: twenty-five minutes for a change to the GUI's workflow would be a cost with
  nothing behind it.
- **Into a chunk too.** A chunk's fixer may have no cluster, and the chunk's pull request
  into `main` comes once every fix is in, which is where #678 would have been found. The
  light check stays light everywhere else.
- **One job, two callers.** The job moved into `cluster.yml`, a reusable workflow both
  call, so the chunk's and `main`'s are the same steps. Each caller runs it after the
  checks that see the same change for less (`lint`, the test legs and `chart` in `ci.yml`;
  the compile in `dev-check.yml`), counting one skipped because its part did not change as
  passed, so a change they refuse spends no cluster.
- **The CRDs first.** Right after `scripts/kind-up`, before the images are built (nine of
  the job's twenty-five minutes), the CRDs are applied and the admission policy and the
  kind values' TroupePolicy go through a server-side dry run, so the chart still owns them
  when it installs. A refused rule fails in about a minute. Reproduced against a kind API
  server (v1.34): the CRD before #678 is refused, "message must be specified if rule
  contains line breaks", and the tip's is accepted.
- **What the suite proves of a worker's isolation (#670).** A worker reaches no other
  namespace's pod and no pod but the ingress's reaches it; it cannot reach 169.254.169.254
  even where another policy admits it, against a stand-in the job puts on the runner (an
  address on the node is the node's to Cilium, which no egress rule speaks of); the IPv6
  and NAT64 forms are denied as the Cilium agent holds the policy, since kind has neither;
  a command a session runs on a pod runs in bubblewrap and sees neither the pod's BEAM nor
  its OpenBao token; and a profile's own OpenBao role, `Troupe.KMS.Policy.worker/2` bound
  to its namespace, reaches its own teams' keys, no other team's or person's, deletes
  none, and is refused to another profile's ServiceAccount. Each refusal is set beside a
  pod or a role for which the same thing succeeds, so it fails when its rule goes.
- **Not chosen.** The CRD step alone on a pull request (a few minutes): it would catch #678
  and nothing the suite catches, such as an admission policy that refuses the dev profile.
  The worker and plane apps in the list: their own suites run on every change to them, and
  the cluster suite on each would put twenty-five minutes on most pull requests.
- **What it costs.** The job takes what it took in the nightly, about twenty-five minutes,
  plus the new tests; on a pull request it runs beside the rest, so a change to the chart
  or the operator waits for it.
