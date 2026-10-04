# Troupe documentation

Four kinds of reader come here, and each has a track and an order to read it in. The
tracks do not lean on each other: an operator never needs the contributor's pages, and a
client author needs nothing but the protocol. The same pages are published as a site at
<https://it-minds.github.io/troupe/>, built from this directory by `mkdocs.yml`.

New here: the [quick start](quick-start.md) goes from nothing to a first session, what it
cost and a cap on the next one in ten minutes; [why Troupe](why-troupe.md) says who it is
for and when you do not need it; the [glossary](glossary.md) has every word Troupe uses.

## Using Troupe

You run agents, on your own machine or on your team's plane.

1. [user/](user/README.md) — what a session is, the first run in five steps, the ways in,
   and the words you will meet.
2. [The terminal client](../clients/tui/README.md) — installing `troupe`, a model
   provider, using it, and sessions on a plane; [in VS Code](user/vscode.md), opened in
   its terminal at the workspace folder.
3. [Configuration](user/configuration.md) — every key in `config.yaml`, and which file
   set it.
4. [The daemon](../apps/troupe_daemon/README.md) — `troupe-daemon`, what runs your
   sessions, and how long it stays up.
5. [The desktop app](../clients/gui/docs/install.md) — installing the builds while they
   are unsigned.

## Running a deployment

You operate the platform: the chart, the services beside it, and the teams, profiles,
bundles and triggers on top.

1. [admin/](admin/README.md) — the tree, and nine things to know before the first
   `helm install`.
2. [Installing](admin/installing.md) — from a cluster with nothing on it to a first team
   in the console. The shape of what you are installing is
   [ARCHITECTURE.md §6](../ARCHITECTURE.md#6-remote).
3. [Roles and permissions](admin/roles-and-permissions.md) and
   [integrations](admin/integrations.md) — identity, what each surface accepts, and what
   the identity provider, OpenBao, PostgreSQL and object storage must provide;
   [Authentik](admin/authentik.md) step by step.
4. [Profiles and policy](admin/profiles-and-policy.md), then
   [bundles, triggers and budgets](admin/bundles-and-triggers.md).
5. Day two: [monitoring](admin/monitoring.md), [backup and restore](admin/backup-restore.md),
   [routine tasks](admin/routine-tasks.md).
6. For reference: [configuration](admin/configuration.md) (every variable, value,
   setting, Secret and port), [what Troupe dials](egress-allowlist.md) (generated), the
   [A2A facade](a2a.md), and [a worker on your own machine](admin/single-machine.md).

## Changing the code

You contribute to Troupe itself.

1. [CONTRIBUTING.md](../CONTRIBUTING.md) — before you start, the sign-off, a first
   contribution.
2. [A tour](developer/tour.md) — where things live, running the suite, adding a tool,
   and how the event log works.
3. [ARCHITECTURE.md](../ARCHITECTURE.md) — the design, and why the log is the session.
4. [developer/](developer/README.md) — setup, testing, conventions, the build, CI and
   releases, and the code's own map.
5. [DECISIONS.md](../DECISIONS.md) — the judgment calls that still hold, by number, as
   the code cites them.

## Writing a client

You write a program that talks to a daemon or a worker pod, in any language.

1. [PROTOCOL.md](../PROTOCOL.md) — the whole surface, normative, written to need no
   checkout of this repository.
2. [`protocol/schema/v1/`](../protocol/schema/v1/) — JSON Schema for every command and
   event, add-only within version 1.
3. [The conformance client](../apps/troupe_gateway/test/conformance/) — a client in
   Python's standard library that CI runs against a real daemon.
4. [The graphical client](../clients/gui/README.md) — `@troupe/client`, a TypeScript
   implementation, and what it learned that the protocol does not say loudly.

## Also here

[third-party-licences.md](third-party-licences.md) (generated): what Troupe depends on,
under which licences. [design/admin/](design/admin/DESIGN.md): the console's design.
[plans/admin-surface.md](plans/admin-surface.md) and
[program/control-panel.md](program/control-panel.md): the plans the console's open work
(#56) builds on. [SECURITY.md](../SECURITY.md): reporting a vulnerability.
