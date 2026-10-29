# A plane-light: the plane and its own worker on one machine

The rest of this directory assumes a cluster. This page is for one person, or a small
team, with a box in a corner, a NAS or a small VPS, who want Troupe on it from the
published images with no Kubernetes and no Elixir toolchain: one compose file,
`deploy/plane-light/compose.yml`, that runs the plane, a worker registered to it as a
machine, and what the two need. The clients are the same clients and the protocol is the
same protocol; a session on a plane-light is a session, with roles, grants, budgets and
the audit trail that come with the plane.

It is also the developer's whole product on a laptop: the same file with `--build` makes
the plane, the worker and the GUI from the checkout.

> **What you give up is named here, not hidden.** A plane-light is the plane with the
> cluster taken out from under it. Section 1 lists what the cluster was giving you. Read
> it before you put anything on the box that the box is not allowed to lose.

---

## 1. What a plane-light does not give you

Everything [single-machine.md](single-machine.md) says about a worker on a machine holds:
no admission policy, no network policy, no egress by hostname, no disruption budget, and
the team that runs there is allowed to by a platform admin by name (the stack does that
for its one team, section 3). Beyond that:

| | on a cluster | on a plane-light |
| --- | --- | --- |
| the keys to the keys | OpenBao's unseal share is kept outside the cluster | **on the same disk**: the stack initialises OpenBao once and keeps the unseal key and the root token in a volume only its own container mounts, readable by root alone, so it can unseal itself at every start. Whoever has the disk has every session key |
| TLS | the ingress terminates it | **none**: the two published ports speak plain HTTP. A reverse proxy of your own in front of them is where the certificate goes; until then, treat the box's network as the trust boundary |
| the artifacts host | its own hostname behind its own Ingress | its own port and a second hostname you supply (section 2), so a published page still runs in an origin that reaches nothing of the plane's |
| replicas | the plane, the GUI and the proxy each run more than one | one of everything: a restart is a minute of nothing answering |
| backups | managed PostgreSQL, a versioned bucket, OpenBao snapshots | five volumes on one disk, yours to copy (section 6) |
| growing | the operator makes workers; machines are registered beside them | one worker, this box. More machines are [single-machine.md](single-machine.md) by hand, and whether a plane-light should grow into a fleet is an open question |
| identity | the organisation's provider | a bundled Dex with static users; the organisation's provider goes in as a Dex connector, and `TROUPE_PLATFORM_ADMIN_GROUP` is still a group claim |

What stays: the session log, the seal format and the object layout are byte-identical, so
a session sealed here restores on a cluster and the other way round; the console, the
admin API and the audit trail are the plane's own.

---

## 2. Installing on a small server, in five steps

The box needs Docker with compose, bubblewrap's requirements (unprivileged user
namespaces, which every recent Linux kernel has), and a name the laptops reach it by. Get
the directory, with nothing else from the repository:

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/it-minds/troupe
cd troupe && git sparse-checkout set deploy/plane-light && cd deploy/plane-light
```

**1. `.env`.** `cp .env.example .env` and change every value it says to change. Two are
the box's names: `TROUPE_LIGHT_HOST`, the one name a browser, the clients and the plane
itself reach it by (the plane fetches the identity provider's keys at that name, which is
why `localhost` will not do), and `TROUPE_LIGHT_ARTIFACTS_HOST`, another name for the same
box: its IP address beside its hostname works, and so does a second DNS record. The two
have to differ, and the plane refuses to start if they do not, because a published page
on the plane's own origin could read the plane's cookie. The secrets are long and random;
the break-glass token administers the plane, so it is the one to guard.

**2. Who may sign in.** `dex/config.yaml` is the identity provider's configuration and the
file you edit. The first administrator comes from `.env`, in the platform-admin group and
the team group; more people are a line each with a bcrypt hash (`scripts/plane-light
hash`, or `docker run --rm caddy:2.10.2-alpine caddy hash-password --plaintext ...`). An
office with Google Workspace, Entra or GitHub uncomments a connector and names its groups
instead of the static ones: a person a connector signs in carries the groups the provider
says, and the plane reads nothing else.

**3. `docker compose up -d --wait`.** Or, from a checkout, `scripts/plane-light up`. The
first start takes a minute: PostgreSQL, MinIO, OpenBao and Dex come up, the migration
runs, the plane starts, and the `bootstrap` service goes through the break-glass door to
write the profile `local` (its workers are registered machines), register the box as
`this-box`, and put the secret and the control CA where the worker reads them. The worker
then enrols over TLS, as a machine does ([single-machine.md §3](single-machine.md#3-install-the-worker-on-it)).

**4. First sign-in.** Open `http://<TROUPE_LIGHT_HOST>:8080/app` and sign in as the
administrator. That sign-in is what tells the plane the team group exists: the bootstrap
has been waiting for it, and now makes the group a team, allows it where nothing is
enforced, and grants it `local`. `docker compose logs bootstrap` says `done`. From then
on sessions start on the box; the console is at `/console`, and `troupe login
http://<host>:8080` signs the terminal client in.

**5. A key for a real model.** The stack starts with `TROUPE_PROVIDER=fake`, which answers
every prompt from `worker/fake.json` and calls nothing, so everything above works before
anybody has a key. A real model is `TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`
and `TROUPE_MODEL` in `.env` ([the user guide's provider table](../user/configuration.md)),
and `docker compose up -d` again, which restarts the worker alone.

### What is where

| | |
| --- | --- |
| `http://<host>:8080` | the plane: its index, `/rpc`, `/.well-known/troupe`, the console at `/console`, the app at `/app`, Dex at `/dex`, the worker's WebSocket at `/v1/socket` |
| `http://<artifacts host>:8081` | published artifacts |
| `plane:4001`, inside the compose network | the control port the worker dials, TLS only |

One proxy (Caddy, `caddy/Caddyfile`) publishes the first port and routes by path as the
chart's Ingresses do; nothing else is published.

---

## 3. What the stack decided for you

- **A profile `local` on `provisioner: ssh`**, on the worker image of this release
  (`image: release`), so an update moves it. Its settings are the console's to change.
- **The team is the group `TROUPE_LIGHT_TEAM_GROUP`**, enabled at its first member's
  sign-in, with `allow_unenforced_workers` set: the box gives none of a cluster's
  guarantees, and the plane refuses the grant until a platform admin says so by name,
  which the bootstrap does for this one team. A second team is yours to enable and allow,
  on **Teams**, knowing the same.
- **The worker container runs without Docker's default seccomp and AppArmor profiles and
  with `/proc` unmasked** (`security_opt` in the compose file). Bubblewrap builds every
  command's sandbox from user, mount and PID namespaces of its own, and Docker's defaults
  refuse all three; on a cluster the chart's seccomp profile, AppArmor profile and user
  namespaces say the same thing more narrowly. The container is still an unprivileged
  user with no capability, and no variable turns the sandbox off.
- **OpenBao's tokens are files, not `.env` lines**: the plane's and the worker's tokens
  are made by the init, carrying the policies [openbao.md](openbao.md) lists and the
  shared worker policy, and read from a volume at start.
- **The identity provider's issuer is `http://<host>:8080/dex`**, the same string for a
  browser and for the plane, which reaches it through the Docker host. HTTPS in front
  changes the issuer: Dex's clients and the plane's `TROUPE_OIDC_*` both follow
  `TROUPE_LIGHT_HOST` and `TROUPE_LIGHT_PORT`, so a proxy that terminates TLS on another
  port is a change to those two and a restart.

---

## 4. For a developer: the product from the checkout

```sh
cp deploy/plane-light/.env.example deploy/plane-light/.env   # the defaults work on one machine
scripts/plane-light up --build
```

`--build` makes the plane and the worker with `docker/Dockerfile` and the GUI with
`clients/gui/Dockerfile`, as CI publishes them, and runs them in place of the release's.
`plane.localtest.me` and `artifacts.localtest.me`, the example's defaults, resolve to
127.0.0.1 from public DNS, which is what lets one URL mean the same thing to a browser and
to the plane's container. `scripts/plane-light-check` is the proof: the stack on ports of
its own, a sign-in through Dex, a session on the box's worker answered by the fake model,
an artifact read from the artifacts host, the app and the console, then a stop and a
start to show OpenBao unseals itself and the session is still there. CI runs it on a
change to the stack, the images or the server apps.

---

## 5. Updating

Change `TROUPE_VERSION` in `.env` and `docker compose up -d --wait` (or
`scripts/plane-light up`). Compose pulls the three images, runs the release's migration
before the plane serves, and replaces the plane, the worker and the GUI. A running session
on the worker ends with it: drain first on **Workers** if that matters, as
[upgrading.md](upgrading.md) says for a pod. The profile `local` follows, since its image
is `release`. Going back is the previous `TROUPE_VERSION` and the database restored from
before the migration ([backup-restore.md](backup-restore.md#a-bad-migration)).

---

## 6. Backups

Everything is in named volumes of the compose project `troupe-light`, on the box's disk:

| volume | holds | and without it |
| --- | --- | --- |
| `postgres-data` | the session index, teams, grants, principals, the audit trail, settings | the index comes back from object storage; nothing else does |
| `minio-data` | every sealed session: the primary copy | the sessions are gone |
| `openbao-data`, `openbao-keys` | the session keys, the signing key; the unseal key and root token | **every sealed session is unreadable forever** |
| `worker-state` | live working copies and caches | at most the last minute of a live session |
| `dex-data` | Dex's refresh tokens and device codes | everybody signs in again |

A backup is the first four, taken together and often, with `docker compose stop` first or
with the tools each store has: `pg_dump` for PostgreSQL, `mc mirror` for MinIO, and for
OpenBao a copy of both volumes while it is stopped, since the file backend has no
snapshot. [backup-restore.md](backup-restore.md) says what a restore of each means and in
which order; what it says of OpenBao's Raft volume holds for the file backend here, with
the unseal key in the second volume rather than outside. Nothing in the stack schedules a
backup for you, as nothing in the chart does.

`scripts/plane-light reset` removes every volume, keys included, and asks you to type the
word first.
