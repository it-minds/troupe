# Troupe Remote

A coding-agent harness that runs on Kubernetes. Teams' agents run on pods this cluster
schedules; a control plane hands out the sessions, endpoints and tokens to reach them,
and an admin console runs the whole fleet from a browser.

**This repository is the remote, and the harness the daemon is built from.** It ships
four container images and a Helm chart. It ships no client and no binary — no installer,
no TUI, no CLI, no Python package — and it is installed on nobody's machine. Three of
its apps, `troupe_core`, `troupe_gateway` and `troupe_protocol`, are also the whole of
the **local daemon**: the [`troupe`](https://github.com/it-minds/troupe) repository pins
them by git ref and packages them as `troupe-daemon`, one binary per platform, and the
clients stand on that. Clients are separate releases from separate repositories that
speak [PROTOCOL.md](PROTOCOL.md) and get no private access to any of this; the plane's
front page links to whichever ones your organisation publishes.

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

| Image | What it is |
|---|---|
| `troupe-plane` | The control plane: the client and admin API as JSON-RPC and MCP, the OIDC relying party, the front page at `/` and the admin console at `/admin`. |
| `troupe-operator` | Turns a `WorkerProfile` into a namespace of pods, and a `TroupePolicy` into what those pods may do. |
| `troupe-worker` | The agent harness itself, running inside one of those pods, reached over a WebSocket through its own Ingress. |
| `troupe-a2a` | The A2A facade: every profile as an agent other agents can call. |

Plus [`charts/troupe`](charts/troupe), which deploys the lot. There is no fifth artifact.
`.github/workflows/ci.yml` has no build matrix, no per-platform runner and no release
binaries, because there is no machine to build for other than a Linux node pool.

## Deploy

```sh
helm upgrade --install troupe charts/troupe \
  --namespace troupe-system --create-namespace \
  --values charts/troupe/values.small.yaml \
  --values my-values.yaml
```

`values.small.yaml` is one plane, one operator and a handful of workers — the shape a
team actually starts with. `values.scaleway.yaml` is the same on a Kapsule cluster with
Scaleway's registry and object storage.
[docs/deploying-on-scaleway.md](docs/deploying-on-scaleway.md) walks a real deployment
end to end; [docs/admin/configuration.md](docs/admin/configuration.md) is every value and
every environment variable.

It needs Postgres for the plane, an S3-compatible bucket for session storage, and an
OIDC provider to sign people in. `scripts/build-images` builds the four images into a
local cluster or pushes them to a registry; `dev/docker-compose.yml` and `scripts/dev-up`
bring up the dependencies for a development run.

## The front door

`/` is the page a person gets when they are handed the URL: what this host is, what runs
where, and the ways in. `/docs` explains the concepts behind it, `/admin` is the console,
`/healthz` is for Kubernetes, and the rest is API.

Two of the ways in are clients this repository does not build and cannot discover, so
each is a URL somebody configures:

* `plane.appUrl` (`TROUPE_APP_URL`) — where the graphical client is mounted, `/app` by
  default, which is where its own chart puts it. Empty means no app is mounted, and the
  page then offers no door to a 404.
* `plane.cliUrl` (`TROUPE_CLI_URL`) — where the terminal client is published. Empty means
  the page tells a reader to ask their administrator rather than linking at a download
  that is not there.

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

Needs Elixir 1.20.4 on OTP 28.5.0.5 and Zig 0.16.0 — see `.tool-versions`. Zig builds
`reaper`, the small helper every shell command runs under; the worker's image builds it
inside the image, for Linux, and nothing here is cross-compiled for anything else.

```sh
mix deps.get
mix check                    # compile --warnings-as-errors, format, credo, boundaries, test
scripts/build-images         # the four images, into kind or a registry
```

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
verifies the hash chain itself. Now that every client is outside this repository, it is
the check that proves the protocol is enough to be one. If it stops working, the protocol
broke.

## The A2A facade

`apps/troupe_a2a` exposes every profile as an agent other agents can call, with an agent
card at `/a2a/<profile>/.well-known/agent-card.json` and `message/send`, `message/stream`,
`tasks/get` and `tasks/cancel` mapped onto sessions, inputs, the event stream and
approvals. It is one more protocol client — it depends on `troupe_protocol` alone, holds
no credential of its own, and exchanges each caller's at the plane.
[docs/a2a.md](docs/a2a.md) has the mapping and the auth.

## Not included

No client of any kind, and no packaged binary for any platform — the daemon binary is
built from this repository's apps, in the `troupe` repository, on its runners. No MCP
client, no git auto-commit or undo, no image signing.

[docs/user/](docs/user/README.md) documents the terminal client that used to live here.
It is deprecated and kept as an artifact: the code it cites is in git history, and the
client's own repository is where that material belongs.

## Licence

MIT.
