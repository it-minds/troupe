# Troupe

A coding-agent harness that runs on Kubernetes and on your own machine. Teams' agents run
on pods a cluster schedules; a control plane hands out the sessions, endpoints and tokens
to reach them, and an admin console runs the whole fleet from a browser. The same harness
runs on a laptop as the local daemon.

**This repository is all of it** (Decision 666): the platform, the daemon, and the two
clients that are its defaults — the terminal UI and the graphical app. One `VERSION`
versions everything, and one release ships it: five container images and a Helm chart
for a cluster, and `troupe`, `troupe-daemon` and the desktop app for a machine. The
clients get no private access for living here: everything they do goes over
[PROTOCOL.md](PROTOCOL.md), and a client somebody else writes against that document is
as supported as ours.

| directory | what it is |
|---|---|
| [`apps/`](apps/) | The Elixir umbrella: the harness (`troupe_core`, `troupe_gateway`, `troupe_protocol`), the worker, the plane, the operator, the A2A facade, and the daemon (`troupe_daemon`). |
| [`clients/tui`](clients/tui/README.md) | `troupe`, the terminal client. Its own Mix project, built against the harness in `apps/` by path; it embeds the daemon when none is running. |
| [`clients/gui`](clients/gui/README.md) | The graphical client: `@troupe/client` (the protocol in TypeScript), the web app the chart serves at `/app`, and the desktop app that wraps it. |
| [`charts/troupe`](charts/troupe) | The Helm chart for the platform and the GUI. |
| [`docs/`](docs/README.md) | The administrator's, developer's and user's documentation. |

Sessions live on a **pod** or in the **daemon**, not in whatever window you happened to
open. Close the client and the work carries on; open it again, or a second one, or a
script, and you are looking at the same session. Every agent, model request, tool run and
subagent is a process, failure is handled by supervision, and the session's hash-chained
log *is* the session: every view, restart and audit is a fold over it.
[ARCHITECTURE.md](ARCHITECTURE.md) is the design; [PROTOCOL.md](PROTOCOL.md) is the client
author's document and needs no checkout of this repository.

## What it ships

| Image | What it is |
|---|---|
| `troupe-plane` | The control plane: the client and admin API as JSON-RPC and MCP, the OIDC relying party, the front page at `/`, `/docs`, and the admin console at `/admin`. |
| `troupe-operator` | Turns a `WorkerProfile` into a namespace of pods, and a `TroupePolicy` into what those pods may do. |
| `troupe-worker` | The agent harness itself, in one of those pods, reached over a WebSocket through its own Ingress. |
| `troupe-a2a` | The A2A facade: every profile as an agent other agents can call ([docs/a2a.md](docs/a2a.md)). |
| `troupe-gui` | The graphical client, served at `/app` on the plane's host. |

Plus [`charts/troupe`](charts/troupe), which deploys the lot.

On a machine, from the same release: `troupe` (the TUI) and `troupe-daemon` for Linux,
macOS and Windows, and the desktop app's installers. Each release attaches `install.sh`
and `install.ps1`, which install that release: the daemon always, and they ask about the
TUI and the desktop app. Download one, read it if you like, run it:

```sh
curl -fsSLO https://github.com/it-minds/troupe/releases/latest/download/install.sh
sh install.sh
```

```powershell
irm https://github.com/it-minds/troupe/releases/latest/download/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

No questions: `--tui --gui -y` (`-Tui -Gui -Yes`). Start over: `--clean-install`
(`-CleanInstall`). Remove: `--uninstall [--purge]` (`-Uninstall [-Purge]`).

## Deploy

```sh
kubectl apply -f charts/troupe/crds/
helm upgrade --install troupe charts/troupe \
  --namespace troupe-system --create-namespace \
  --values charts/troupe/values.small.yaml \
  --values my-values.yaml
```

It needs PostgreSQL, an S3-compatible bucket with versioning, OpenBao and an OIDC
provider. `values.small.yaml` is one plane, one operator, the GUI and a handful of workers;
`values.scaleway.yaml` is the same on Kapsule. [docs/admin/installing.md](docs/admin/installing.md)
starts from an empty cluster, [docs/deploying-on-scaleway.md](docs/deploying-on-scaleway.md)
walks Scaleway, and [docs/admin/](docs/admin/README.md) is the operator's tree. A team with
its own client sets `gui.enabled: false` and points `plane.appUrl` at it.

## Releasing and deploying

A release is a merged change to `VERSION`, and it deploys itself (Decision 669):

```sh
scripts/release 0.3.1        # opens the pull request that changes VERSION
```

Merging it runs the full suite on that commit, builds the images at `0.3.1`, tags
`v0.3.1`, publishes the chart and the daemon, TUI and desktop builds, and rolls the release
onto the `production` environment with [`scripts/deploy`](scripts/deploy), which checks
that `/.well-known/troupe` then reports the new version and commit. A release candidate
(`0.4.0-rc.1`) does all of it and deploys as a dry run; the `deploy` workflow rolls back to
or renders a named release; a **pre-release** of any commit, untested, is a button in
Actions. Nothing is deployed from a laptop. [`.github/CI.md`](.github/CI.md) has the whole
picture.

## The front door and the console

`/` is the page a person gets when they are handed the URL: what this host is and the
ways in. `/docs` explains the concepts, `/admin` is the console, `/healthz` is for
Kubernetes, and the rest is API. `plane.appUrl` says where the graphical client is (the
chart's own at `/app` by default) and `plane.cliUrl` where the terminal client is published
(empty: the page says to ask an administrator).

The console — fleet, teams, budgets, worker profiles, policy, bundles, triggers,
principals, audit — has no private access either: it is a client of
`Troupe.Plane.Admin`, the same context behind the `admin.*` JSON-RPC methods and the MCP
tools at `/mcp`, and a test enumerates them so a button cannot exist without the method
under it.

## Building from source

Needs Elixir 1.20.4 on OTP 28.5.0.5, Zig 0.16.0 (for `reaper`, the helper every shell
command runs under) and, for the GUI, Node 24 — see `.tool-versions`.

```sh
mix deps.get
mix check                    # compile --warnings-as-errors, format, credo, boundaries, test
scripts/build-images         # the five images, into kind or a registry

(cd clients/tui && mix deps.get && mix check)                  # the TUI
(cd clients/gui && pnpm install && pnpm build && pnpm test)    # the GUI
(cd apps/troupe_daemon && MIX_ENV=prod mix release)            # the daemon, for this machine
```

On Windows, `scripts/setup-windows-toolchain.ps1` and `scripts/install-local.ps1`. The
`fake` provider replays a JSON script (`{"steps": [{"text": "Done."}]}`) and records every
request, which is how the suite exercises the whole harness with no model behind it.
[docs/developer/](docs/developer/README.md) is the developer's tree.

## Writing a client

[PROTOCOL.md](PROTOCOL.md) is the whole surface, and JSON Schema for every message and
event is committed under [`protocol/schema/v1/`](protocol/schema/v1/); `mix
troupe.schema.diff` fails the build on a change an older client could not survive.
`apps/troupe_gateway/test/conformance/` holds a client in the Python standard library that
CI runs against a real daemon — initialize, list, replay from `seq` 0, send input, answer
an approval, verify the hash chain. It is a test fixture, not a package, and the check that
the protocol alone is enough to be a client.

## Licence

MIT.
