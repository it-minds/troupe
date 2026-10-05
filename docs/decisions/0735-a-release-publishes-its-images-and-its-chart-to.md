---
number: 735
title: A release publishes its images and its chart to `ghcr.io`, public, and deploys nothing
date: 2026-09-29
status: accepted
issue: 186
supersedes: [669]
paths:
  - .github/workflows/images.yml
  - .github/workflows/release.yml
  - docs/developer/ci.md
  - scripts/release
gist: A release publishes its images and its chart to `ghcr.io`, public, and deploys nothing
---

Issue #186. The images went to whichever registry four repository
secrets named, which was our own cloud's, and `release.yml` ended by rolling our
cluster with a kubeconfig from its `production` environment, as `deploy.yml` did by
hand: the product's repository held a credential for one deployment's
infrastructure and knew which cluster was ours. Now `images.yml` pushes the five
images to `ghcr.io/<owner>/troupe-<name>` with the workflow's own `GITHUB_TOKEN`
(`packages: write`), tagged as before (`sha-<short>`, and the version for a release
or a pre-release), labelled with this repository as their source. There is no
registry to configure and no override for one: a secret naming a registry is a door
into somebody's infrastructure, and a deployment that wants a mirror copies from
`ghcr.io`. The packages are public, so a cluster pulls them with no credential;
GitHub creates a package private, and an organisation owner makes each one public
once, which no workflow can do. A release also pushes its chart as
`oci://ghcr.io/<owner>/charts/troupe` at its version, beside the `.tgz` on the
release page (322), in the job that publishes the release and just before it does,
so a chart version in the registry is a release that finished; the release's notes
show both. A pre-release pushes its chart too, when it built its images, since a
chart whose images were never pushed installs nothing that runs; Helm takes a
pre-release version only when it is named. `release.yml` ends at the published
release and `deploy.yml` is gone: a deployment pins a version, holds its own values
and credentials, and takes the published chart and images from a repository of its
own, which nothing here names, dispatches to or waits for. `charts/troupe/values.yaml`
names the `ghcr.io` images and its policy allows the worker's, and the development
loop (`scripts/build-images`, `scripts/remote-up`, `dev/kind/values.yaml`, the
cluster suite) builds and runs under the same names, so a kind cluster runs the
chart's own defaults. Supersedes the deploying half of 669.
