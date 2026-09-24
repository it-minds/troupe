# Troupe

A coding-agent harness that runs on Kubernetes and on your own machine. Teams' agents run
on pods a cluster schedules; a control plane hands out the sessions, endpoints and tokens
to reach them, and an admin console runs the whole fleet from a browser. The same harness
runs on a laptop as the local daemon.

**This repository is all of it** (Decision 666): the platform, the daemon, and the two
clients that are its defaults — the terminal UI and the graphical app. One `VERSION`
versions everything, and one release ships it: five container images and a Helm chart
for a cluster, and `troupe`, `troupe-daemon` and the desktop app for a machine. The
clients live here and get no private access for it: everything they do goes over
[PROTOCOL.md](PROTOCOL.md), and a client somebody else writes against that document is
as supported as ours.

| directory | what it is |
|---|---|
| [`apps/`](apps/) | The Elixir umbrella: the harness (`troupe_core`, `troupe_gateway`, `troupe_protocol`), the worker, the plane, the operator, the A2A facade, and the daemon (`troupe_daemon`). |
| [`clients/tui`](clients/tui/README.md) | `troupe`, the terminal client. Its own Mix project, built against the harness in `apps/` by path; it embeds the daemon when none is running. |
| [`clients/gui`](clients/gui/README.md) | The graphical client: `@troupe/client` (the protocol in TypeScript), the web app the chart serves at `/app`, and the desktop app that wraps it. A pnpm workspace. |
| [`charts/troupe`](charts/troupe) | The Helm chart for the platform and the GUI. |
| [`docs/`](docs/README.md) | The operator's, developer's and user's documentation; [`docs/program/`](docs/program/README.md) is the plan the repositories were built to. |

Sessions live on a **pod**, not in whatever window you happened to open. Close the
client and the work carries on; open it again, or a second one, or a script, and you are
looking at the same session. Everything speaks one protocol — JSON-RPC, over a WebSocket
to a worker and over `POST /rpc` to the plane — and there is no second path in: if the
admin console can do something, so can a program you write this afternoon.

The defining property is underneath: **every agent is a process, every in-flight model
request is a process, every tool execution is a process, and every subagent is a child
process.** Nothing is shared, everything communicates by message, and failure is handled
by supervision rather than by defensive code.

The session log is the session. Every client view, every restart and every audit is a
fold over it, and each event is hash-chained to the one before, so a client can verify
the history it was handed without trusting the server that handed it over.

[ARCHITECTURE.md](ARCHITECTURE.md) has the supervision tree and the boundaries;
[PROTOCOL.md](PROTOCOL.md) is the client author's document and needs no checkout of this
repository.

## What it ships

On a cluster:

| Image | What it is |
|---|---|
| `troupe-plane` | The control plane: the client and admin API as JSON-RPC and MCP, the OIDC relying party, the front page at `/` and the admin console at `/admin`. |
| `troupe-operator` | Turns a `WorkerProfile` into a namespace of pods, and a `TroupePolicy` into what those pods may do. |
| `troupe-worker` | The agent harness itself, running inside one of those pods, reached over a WebSocket through its own Ingress. |
| `troupe-a2a` | The A2A facade: every profile as an agent other agents can call. |
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
helm upgrade --install troupe charts/troupe \
  --namespace troupe-system --create-namespace \
  --values charts/troupe/values.small.yaml \
  --values my-values.yaml
```

`values.small.yaml` is one plane, one operator, the GUI and a handful of workers — the shape
a team actually starts with. `values.scaleway.yaml` is the same on a Kapsule cluster with
Scaleway's registry and object storage.
[docs/deploying-on-scaleway.md](docs/deploying-on-scaleway.md) walks a real deployment
end to end; [docs/admin/configuration.md](docs/admin/configuration.md) is every value and
every environment variable.

It needs Postgres for the plane, an S3-compatible bucket for session storage, and an
OIDC provider to sign people in. `scripts/build-images` builds the five images into a
local cluster or pushes them to a registry; `dev/docker-compose.yml` and `scripts/dev-up`
bring up the dependencies for a development run.

A team that uses its own client sets `gui.enabled: false` and points `plane.appUrl` at it.

## Releasing and deploying

A release is a merged change to `VERSION`, and it deploys itself (Decision 669):

```sh
scripts/release 0.3.1        # opens the pull request that changes VERSION
```

Merging it runs the full suite on that commit — every job, nine soak runs and the cluster
suite — then builds the images at `0.3.1`, tags `v0.3.1`, publishes the chart and the
daemon, TUI and desktop builds, and rolls the release onto the `production` environment
with [`scripts/deploy`](scripts/deploy) — CRDs, `helm upgrade --wait` with rollback, and a
check that `/.well-known/troupe` reports the new version and commit. A release candidate
(`0.4.0-rc.1`) does all of it and deploys as a dry run. The `deploy` workflow rolls back
to, or renders, a named release. Nothing is deployed from a laptop, and the repository's
Deployments page is the record of what ran where.

Pull requests and merges run only what a change can have broken, and a **pre-release** —
any commit, built without the test suite and published as `0.3.1-pre.<n>` for trying
out — is a button in Actions. [`.github/CI.md`](.github/CI.md) has the whole picture.

## The front door

`/` is the page a person gets when they are handed the URL: what this host is, what runs
where, and the ways in. `/docs` explains the concepts behind it, `/admin` is the console,
`/healthz` is for Kubernetes, and the rest is API.

Two of the ways in are the clients, and each is a URL:

* `plane.appUrl` (`TROUPE_APP_URL`) — where the graphical client is. Empty, it is the GUI
  the chart serves at `/app` when `gui.enabled`, and no door at all when not — never a
  link to a 404. A team with its own client points it there.
* `plane.cliUrl` (`TROUPE_CLI_URL`) — where the terminal client is published. The TUI is
  released with the chart, but a private repository's release page is a door most readers
  cannot open, so empty means the page tells a reader to ask their administrator.

## The admin console

Fleet, teams, budgets, worker profiles, policy, bundles, triggers, principals and audit —
in a browser at `/admin`, signed in through the identity provider, with platform admins
and team admins seeing different halves of it.

The console has no private access either. It is a client of `Troupe.Plane.Admin`, the
same context behind the admin JSON-RPC methods and the MCP tools at `/mcp`, and a test
enumerates all three so a button cannot exist without the method under it.
[docs/admin/](docs/admin/README.md) is the operator's tree.

## Configure a worker

An agent is a markdown file whose frontmatter is the configuration and whose body is the
system prompt. The filename is its name; a profile's bundle carries them into the pod.

```markdown
---
description: Reviews a diff and reports problems. Read-only.
mode: subagent          # primary (user-selectable) | subagent (delegatable)
model: claude-sonnet-5
tools: [read_file, grep, list_files, finish]
permissions:
  shell: ask
max_turns: 12
budget_share: 0.2
---
You review code. Report what is wrong and where, and nothing else.
```

Built-ins: `build` (everything), `plan` (read-only, writes the task list), `general`
(subagent, everything), `explore` (subagent, read-only). Tool allowlists and permissions
are enforced by the harness, not by asking the model nicely: a call outside the allowlist
never runs.

`TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY` and `TROUPE_MODEL` choose the
model. The OpenAI adapter speaks plain Chat Completions, so `TROUPE_BASE_URL` points it
at LiteLLM, vLLM, Mistral, Ollama, or anything else with that shape, with or without the
`/v1` suffix. Whichever model you point it at needs **tool calling**; a model that can
only produce text will talk about editing files without ever doing it.

## Sessions and state

Every agent's state — conversation, task list, active profile — is a fold over its own
events, so a crashed agent rebuilds itself by replay and a client redraws from the log.
A session with nothing to do for long enough gives its actor tree back and goes
**dormant**; reading it — listing, replaying, subscribing — starts nothing, and the next
thing you ask it to do brings the tree back.

Two behaviours are worth knowing:

* **A crashed agent inside a live session re-runs the tool call it was in the middle
  of.** Reads, searches and edits are safe under that; `shell` is not necessarily.
* **A session that was mid-turn when the whole worker died comes back interrupted.** It
  makes no model call until you ask it to carry on, and its unfinished tool calls are
  recorded as interrupted rather than repeated — because a crash loop that resumes spends
  money and re-runs commands nobody is watching. Set `resume_on_restart: true` to opt
  back in.

Every OS process a session starts runs under `reaper`, owned by a pipe, so no cleanup
code has to run — and none can be relied on when the VM is killed outright. Kill a pod
and every command the agent started dies with it, including anything those commands
spawned.

## Building from source

Needs Elixir 1.20.4 on OTP 28.5.0.5, Zig 0.16.0 and, for the GUI, Node 24 — see
`.tool-versions`. Zig builds `reaper`, the small helper every shell command runs under;
the worker's image builds it inside the image, and the daemon and the TUI build it for the
machine they are built on.

```sh
mix deps.get
mix check                    # compile --warnings-as-errors, format, credo, boundaries, test
scripts/build-images         # the five images, into kind or a registry

(cd clients/tui && mix deps.get && mix check)                  # the TUI
(cd clients/gui && pnpm install && pnpm build && pnpm test)    # the GUI
(cd apps/troupe_daemon && MIX_ENV=prod mix release)            # the daemon, for this machine
```

`elixir scripts/locks-agree.exs` checks the TUI's lock and the umbrella's agree on the
packages both lock, and `elixir scripts/version.exs check` that every copy of the version
agrees with `VERSION`. CI runs both.

`mix troupe.boundaries` is part of that gate and is not decoration: the A2A facade may
depend on `troupe_protocol` and nothing else, the plane does not run agents, and the
operator knows about neither — which is what keeps the architecture a fact rather than an
intention.

## Testing without a model

The `fake` provider replays a JSON script and records every request, which is how the
suite exercises the whole harness with nothing behind it. A script is a list of steps:

```json
{"steps": [
  {"tools": [{"name": "write_file", "input": {"path": "hello.txt", "content": "hi"}}]},
  {"text": "Done."}
]}
```

```sh
TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=script.json mix test
```

## Writing a client

[PROTOCOL.md](PROTOCOL.md) is the whole surface. Machine-readable JSON Schema for every
message and event is committed under [`protocol/schema/v1/`](protocol/schema/v1/),
generated from the same definitions the server uses, and `mix troupe.schema.diff` fails
the build on a change older clients could not survive.

```python
from troupe import Troupe

with Troupe.connect_unix("/run/user/1000/troupe/daemon.sock") as client:
    fleet = client.call("fleet.get")
    client.subscribe("session:" + fleet["sessions"][0]["id"], from_seq=0)

    for envelope in client.events(timeout=30):
        print(envelope["event"]["type"])
```

That is `apps/troupe_gateway/test/conformance/troupe.py`, 220 lines of standard library
and a **test fixture rather than a deliverable** — this repository publishes no Python
package. `conformance.py` beside it runs in CI against a real daemon: it initializes,
lists the fleet, replays a session from `seq` 0, sends input, answers an approval, and
verifies the hash chain itself. The TUI and the GUI live in this repository, so this is
the check that proves the protocol alone is enough to be a client — the one a client of
your own relies on. If it stops working, the protocol broke.

## The A2A facade

`apps/troupe_a2a` exposes every profile as an agent other agents can call, with an agent
card at `/a2a/<profile>/.well-known/agent-card.json` and `message/send`, `message/stream`,
`tasks/get` and `tasks/cancel` mapped onto sessions, inputs, the event stream and
approvals. It is one more protocol client — it depends on `troupe_protocol` alone, holds
no credential of its own, and exchanges each caller's at the plane.
[docs/a2a.md](docs/a2a.md) has the mapping and the auth.

## Not included

No MCP client, no git auto-commit or undo, no image signing, and no signed desktop or
Windows builds until the signing secrets exist.

[docs/user/](docs/user/README.md) documents the terminal client as it was when it last
lived in `apps/`, before 2026-09-14. It is kept as an artifact; the TUI's own
documentation is [`clients/tui`](clients/tui/README.md), and the GUI's is
[`clients/gui/docs`](clients/gui/docs/README.md).

## Licence

MIT.
