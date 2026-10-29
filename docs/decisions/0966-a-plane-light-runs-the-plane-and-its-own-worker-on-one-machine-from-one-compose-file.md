---
number: 966
title: "A plane-light runs the plane, a worker registered to it as a machine, and what the two need on one box from one compose file, with the bundled Dex as the sign-in where there is no provider, OpenBao's unseal key on the same disk, and the gaps named on its own page"
date: 2026-10-29
status: accepted
issue: 600
paths:
  - deploy/plane-light/compose.yml
  - deploy/plane-light/.env.example
  - deploy/plane-light/bootstrap/bootstrap.py
  - deploy/plane-light/openbao/entrypoint.sh
  - deploy/plane-light/caddy/Caddyfile
  - deploy/plane-light/dex/config.yaml
  - scripts/plane-light
  - scripts/plane-light-check
  - clients/gui/packages/client/test/e2e.plane-light.test.ts
  - config/runtime.exs
  - docs/admin/plane-light.md
  - docs/admin/single-machine.md
symbols:
  - TROUPE_WORKER_ENDPOINT
gist: "One compose file is a supported plane: published images, Dex bundled, OpenBao persistent and self-unsealing, the worker a registered machine; one box by design"
---

## What was there

A plane ran on Kubernetes, with the chart and the operator, and nowhere else. A machine
could be a worker of a plane (`admin.host.register`, [single-machine.md](../admin/single-machine.md)),
but the plane itself still wanted a cluster. The development stack
(`dev/docker-compose.yml`) and the GUI's end-to-end stack (`clients/gui/dev/plane-stack.yml`)
ran the plane's dependencies, and the latter the plane too, unhardened and without a
worker: nothing a person could put on a server and keep. Issue #600 named the case:
an office, or one person, with a box in a corner and no cluster.

## What changes

`deploy/plane-light/compose.yml` is a plane a person runs from the published images with
`docker compose up`, and that a developer builds from the checkout with `--build`:

- **The plane and a worker on the same box.** The worker is a registered machine, not a
  pod: a one-shot `bootstrap` goes through the break-glass door, puts the profile `local`
  with `provisioner: ssh`, registers the box, and writes the secret and the control
  port's CA where the worker mounts them. The control port has a self-signed certificate
  made once on a volume, and takes TLS only, as a machine's enrolment demands.
- **`TROUPE_WORKER_ENDPOINT`.** A registered machine has no ordinal and no workers domain,
  so until now it enrolled with no endpoint and a session placed on it was handed nowhere
  to dial. The worker's enrolment takes the whole WebSocket URL where that is set; the
  composed `<ordinal>-<profile>.<domain>` stays for pods. This is the one change to the
  plane's and the worker's code, and it holds for any registered machine.
- **One port.** Caddy publishes one port and routes `/console` and `/app` to the GUI
  image, `/dex` to Dex, `/v1/socket` to the worker and the rest to the plane; the
  artifacts host has a second port and needs a second hostname, since the plane refuses
  an artifacts address on its own host (origin isolation, Decision 948) and cookies are
  not port-scoped. Plain HTTP: a certificate is the person's own proxy's.
- **Dex bundled.** Where there is no identity provider, Dex with password users the
  person edits in a file is the sign-in, with commented Google and GitHub connectors for
  one that exists. The issuer is the same name from the box's browser and from the
  plane's container (`extra_hosts` to the Docker host).
- **OpenBao persistent and self-unsealing.** File storage on a volume, initialised once
  with one share; the unseal key and the root token are kept in a volume only OpenBao's
  own container mounts, readable by root alone, and it unseals itself at every start.
  Whoever has the disk has every session key. That is the weaker guarantee this trades
  for a box that comes back after a power cut with nobody at a keyboard, and the page
  says so first.
- **The team is enabled at the first sign-in.** A group is known to the plane only from a
  sign-in or SCIM, so the bootstrap waits for a member of the configured group to sign
  in, then enables the team, allows it on unenforced workers and grants it the profile.
- **One box by design.** The stack registers one machine; more machines are
  [single-machine.md](../admin/single-machine.md)'s by hand. Growing a plane-light into
  a fleet is an open question of #600, not answered here.

## The choices not taken

- A multi-user daemon in place of a small plane: identity, access control and audit would
  have to be rebuilt inside it, and that is what the plane is (#600 says why).
- OpenBao in dev mode, as the development stacks run it: every restart would lose the
  signing key and every session key with it; a server cannot.
- A port-only artifacts origin: cookies would cross it; the plane's rule stays.
- A pairing sign-in for a box with no provider (#600's slice 2) and a filesystem object
  store and local signer (slice 3): later, each named as a weaker guarantee when it comes.
- HTTPS in the stack: a certificate belongs to the proxy the person already has.

## Proof

`scripts/plane-light-check`, on this machine with images built from the checkout and in
CI (`clients/gui/packages/client/test/e2e.plane-light.test.ts`): the administrator signs
in through the bundled Dex as a platform admin; the team is granted the box's profile at
that first sign-in; a session runs on the box's own worker with a command in bubblewrap
inside the container, answered by the fake model; an artifact is published and read back
from the artifacts port; the app, the console and `/admin`'s redirect answer where the
index points; then the whole stack is stopped and started and OpenBao is unsealed and
the session still readable. The check runs on a pull request that touches the stack and
nightly for everything else, because three images from scratch is most of half an hour.
