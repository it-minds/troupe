---
number: 734
title: This repository names no deployment of Troupe, and a check in CI keeps it so
date: 2026-09-29
status: accepted
issue: 186
paths:
  - .github/workflows/ci.yml
  - docs/developer/deployment.md
  - scripts/check-neutral.exs
gist: This repository names no deployment of Troupe, and a check in CI keeps it so
---

Issue #186. The repository is the product: the chart, the images, the clients and
how to build them. The deployment its maintainers run lives in a repository of its
own, which consumes the published chart and images as any adopter's would, so its
cloud, cluster, domain, registry, identity tenant and deploy account are not named
here. A reader used to learn one cluster's topology from this repository, and an
adopter had to guess which parts of an example were somebody's own.

*What stays.* `values.example.yaml` is the one worked example: a managed cluster,
PostgreSQL and object store, ingress-nginx, cert-manager, OpenBao in the cluster,
the chart's own images (735), and every value that has to be the reader's marked
`CHANGE ME`. `values.small.yaml` is the same shape turned down. What the provider
walkthrough knew that holds anywhere — the two DNS names, the ingress settings, the
HTTP-01 issuer, how to run OpenBao, sizing — is in `docs/admin/installing.md` §6.
`authentik.md` is a guide to any Authentik instance.

*What went.* The provider's own values and cluster extras, the deploy account's
manifest and the script that made it a kubeconfig, and `scripts/deploy`, whose
only callers left with the deploy (735). An upgrade is the steps in
`routine-tasks.md`, which now say what the script knew: CRDs server-side, a
rollback on failure, the version at `/.well-known/troupe`, and the digests actually
running. `scripts/remote-up` has no default model gateway: a placeholder under
`example.test` that resolves nowhere, with the host of `TROUPE_GATEWAY_URL` put
first in the kind policy's egress list (`--set` on that index keeps the rest), and
the key in `TROUPE_GATEWAY_KEY`. CI's cluster job names a public host, so the
egress suite still has a model endpoint a pod can dial.

*The check.* `scripts/check-neutral.exs`, in the `versions` job, reads every file
git knows and fails on a line that names one. The names are kept as SHA-256 digests
of their lowercase spelling, so the file that keeps them out does not name them;
each run of letters, digits, dots and hyphens is checked whole, by label, by word
and by dotted suffix, which catches a host under any subdomain. A file that must
keep a name for a while is allowed with the reason, and an allowed file that names
nothing fails too, so the list only shrinks; it is empty. Git history keeps every
old name, and nothing here rewrites it. Proof: the check names 161 lines in 39
files at 0.6.3-beta and none here, and CI lints and renders the chart with both
remaining values files, one of them with a pull secret.
