# Troupe

A coding-agent harness built on the actor model, shipped as one self-contained
executable per platform. No Erlang, no Elixir, nothing to install alongside it.

Sessions live in a **daemon**, not in whatever window you happened to open. Close the
TUI and the work carries on; open it again, or a second one, or a script, and you are
looking at the same session. Everything speaks one protocol —
[PROTOCOL.md](PROTOCOL.md), JSON-RPC over a Unix socket — and Troupe's own TUI is
simply the first client of it. There is no private door: if the TUI can do something,
so can a program you write this afternoon, and
[`clients/python/`](clients/python/) is one such program in 220 lines of standard
library.

Troupe runs the agent loop, exposes tools (read, edit, search, shell), streams model
output, enforces permissions and budgets, and persists every session. Three things
shape how it feels to use:

* **Watch mode.** Write `# make this return 42 AI!` in a file, save, and the agent
  acts on it. `AI?` asks a question and cannot edit anything; a bare `AI` comment is
  context that rides along with the next request.
* **Task lists and plan-then-build.** The agent keeps a todo list you can see and
  edit. `plan` investigates and writes the list; Tab switches to `build`, which
  executes it with the same conversation.
* **Named subagents.** `explore`, `general`, or your own, defined as markdown files
  with YAML frontmatter. Independent work runs in parallel.

The defining property is underneath: **every agent is a process, every in-flight
model request is a process, every tool execution is a process, and every subagent is
a child process.** Nothing is shared, everything communicates by message, and failure
is handled by supervision rather than by defensive code.

The session log is the session. Every client view, every restart and every audit is a
fold over it, and each event is hash-chained to the one before, so a client can verify
the history it was handed without trusting the server that handed it over.

[ARCHITECTURE.md](ARCHITECTURE.md) has the supervision tree and the boundaries;
[PROTOCOL.md](PROTOCOL.md) is the client author's document and needs no checkout of
this repository.

## Install

```sh
curl -fsSL https://github.com/objective-mj/troupe/releases/latest/download/install.sh
./install.sh
```

```powershell
irm https://github.com/objective-mj/troupe/releases/latest/download/install.ps1
.\install.ps1
```

Both verify the SHA-256 of the download against the published `SHA256SUMS` before
installing anything, keep the previous binary for rollback, and are safe to re-run.
Set `TROUPE_RELEASE_URL` to install from somewhere other than GitHub — a Forgejo
release, an S3-compatible bucket, a directory on disk.

To remove it: `install.sh --uninstall` (add `--purge` to drop configuration and
session history too), or `install.ps1 -Uninstall`.

### Unsigned binaries

Troupe's binaries are not code-signed, so both desktop platforms will ask about them.

**macOS.** A binary downloaded through a browser gets the `com.apple.quarantine`
attribute and Gatekeeper refuses to run it. The installer uses `curl`, which does not
attach it. If you download by hand:

```sh
xattr -d com.apple.quarantine troupe
```

**Windows.** SmartScreen shows "Windows protected your PC" for unsigned executables;
choose **More info → Run anyway**. Some antivirus products flag self-extracting
binaries generically. The installer uses `Invoke-WebRequest`, which does not attach
the mark-of-the-web.

## Use

```sh
troupe                                  # the TUI, in the current directory
troupe --watch                          # ... acting on AI comments as you save
troupe run "make the tests pass"        # one task, then exit
troupe run "..." --headless             # plain lines, for CI and scripts
troupe resume                           # reattach to the newest session here
troupe sessions                         # what has been run in this workspace
troupe hq                               # every session, and everything waiting on you
troupe daemon                           # run the daemon in the foreground
```

The daemon starts itself the first time a client needs it and shuts down again after a
quiet period with nothing running and nobody attached. Ten terminals starting at once
produce exactly one of it. `troupe daemon` is for running it yourself — under systemd,
in a container, or where you want to watch it.

In the TUI: **Tab** switches between `plan` and `build`, **Esc** cancels the current
turn, **Enter** on an agent in the tree opens its transcript, **Ctrl-C twice** quits —
and quitting leaves the session running. Type `@explore where is auth handled` to
address a subagent directly, or a slash command: `/plan`, `/build`, `/watch`,
`/cancel`, `/agents`, `/sessions`, `/resume`.

Approvals appear inline with a diff for writes and edits and the full command for
shell: **y** allows, **a** allows that tool for the session, **n** denies. A denial
comes back to the model as a readable tool result, not an error.

## Configure

`$XDG_CONFIG_HOME/troupe/config.yaml` (or `%APPDATA%\troupe\config.yaml`), overridden
key-wise by `.troupe/config.yaml` in the project, overridden by the environment:

```yaml
provider: anthropic          # anthropic | openai | fake
model: claude-sonnet-5
max_turns: 40
compact_at: 0.75             # summarise when context passes this fraction
max_depth: 3                 # delegation depth cap
shell_timeout_ms: 120000
watch_debounce_ms: 300
```

`TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY` and `TROUPE_MODEL` win over
both files. The OpenAI adapter speaks plain Chat Completions, so `TROUPE_BASE_URL`
points it at LiteLLM, vLLM, Mistral, Ollama, or anything else with that shape:

```sh
export TROUPE_PROVIDER=openai
export TROUPE_BASE_URL=https://your-gateway.example/v1   # with or without /v1
export TROUPE_API_KEY="$YOUR_GATEWAY_KEY"
export TROUPE_MODEL=code-default
```

The base URL may include the `/v1` suffix or omit it — both resolve to the same
endpoint, because every gateway documents it one way and every provider path is
written the other.

Any string in a config file may reference the environment, so a key never has to be
written to disk:

```yaml
provider: openai
base_url: https://your-gateway.example/v1
api_key: "{env:YOUR_GATEWAY_KEY}"
model: code-default
```

Whichever model you point it at needs **tool calling**; a model that can only produce
text will talk about editing files without ever doing it.

`priv/examples/config.gateway.yaml` is a ready-made config file for this shape.

### Agents

An agent is a markdown file whose frontmatter is the configuration and whose body is
the system prompt. The filename is its name. Project `.troupe/agents/` wins over the
config directory's `agents/`, which wins over the built-ins.

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
(subagent, everything), `explore` (subagent, read-only).

Tool allowlists and permissions are enforced by the harness, not by asking the model
nicely: a call outside the allowlist never runs.

## Stopping it

Ctrl-C twice in the TUI, or `Esc` to cancel just the current turn. `kill` and
`kill -9` from outside both work: a watchdog notices the launcher process going away
and halts the VM, which closes every `reaper` pipe and takes down every command the
agent started, including anything those commands spawned.

That last part is the whole point of `reaper`: every OS process Troupe starts runs
under it, owned by a pipe, so no cleanup code has to run — and none can be relied on
when the VM is killed outright.

## Sessions and state

Session logs are JSONL under `$XDG_STATE_HOME/troupe/sessions/<workspace>/<id>/`
(`%LOCALAPPDATA%\troupe\...` on Windows). Nothing is ever written into your
repository.

Every agent's state — conversation, task list, active profile — is a fold over its
own events, so a crashed agent rebuilds itself by replay and a client redraws from the
log.

A session with nothing to do for long enough gives its actor tree back and goes
**dormant**. Its log stays and reading it — listing, replaying, subscribing — starts
nothing; the next thing you ask it to do brings the tree back.

Two behaviours are worth knowing:

* **A crashed agent inside a live session re-runs the tool call it was in the middle
  of.** Reads, searches and edits are safe under that; `shell` is not necessarily.
* **A session that was mid-turn when the whole daemon died comes back interrupted.**
  It makes no model call until you ask it to carry on, and its unfinished tool calls
  are recorded as interrupted rather than repeated — because a crash loop that resumes
  spends money and re-runs commands nobody is watching. Set `resume_on_restart: true`
  to opt back in.

## Building from source

Needs Elixir 1.20.4 on OTP 28.5.0.5 and Zig 0.16.0 — see `.tool-versions`. Zig is
what builds `reaper`, the small helper every shell command runs under, and what
Burrito uses to wrap the release.

```sh
mix deps.get
mix check                    # compile --warnings-as-errors, format, credo, boundaries, test
scripts/build-local          # a binary for this host, in burrito_out/
```

`mix troupe.boundaries` is part of that gate and is not decoration: the TUI and the CLI
may depend on `troupe_protocol` and nothing else, which is what keeps "no private
access" true rather than merely intended.

Cross-building the other targets from one host is deliberately not supported: the
precompiled ExRatatui NIF resolves against the build host, so a macOS binary built on
Linux would carry a Linux `.so`. `.github/workflows/ci.yml` builds each target on a
native runner.

If Zig aborts with `programmer bug caused syscall error: INVAL`, its cache is on a
filesystem that rejects `renameat2` flags — ecryptfs and some network mounts do.
`scripts/build-local` already redirects `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` for that reason.

Burrito caches the extracted payload under `<app>_erts-<erts>_<version>`, so
rebuilding without bumping `version:` re-runs the **cached** copy and hides your
changes. `scripts/build-local` clears it; by hand it is
`./burrito_out/troupe-... maintenance uninstall`.

## Testing without a model

The `fake` provider replays a JSON script and records every request, which is how a
packaged binary is smoke-tested with nothing behind it:

```sh
cat > script.json <<'JSON'
{"steps": [
  {"tools": [{"name": "write_file", "input": {"path": "hello.txt", "content": "hi\n"}}]},
  {"text": "Done."}
]}
JSON

TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=script.json \
  troupe run "smoke" --headless --auto-approve
```

## Writing a client

[PROTOCOL.md](PROTOCOL.md) is the whole surface: JSON-RPC 2.0, newline-delimited over
`$XDG_RUNTIME_DIR/troupe/daemon.sock`. Machine-readable JSON Schema for every message
and event is committed under [`protocol/schema/v1/`](protocol/schema/v1/), generated
from the same definitions the server uses, and `mix troupe.schema.diff` fails the build
on a change older clients could not survive.

```python
from troupe import Troupe                      # clients/python/troupe.py

with Troupe.connect_unix("/run/user/1000/troupe/daemon.sock") as client:
    fleet = client.call("fleet.get")
    client.subscribe("session:" + fleet["sessions"][0]["id"], from_seq=0)

    for envelope in client.events(timeout=30):
        print(envelope["event"]["type"])
```

`clients/python/conformance.py` runs in CI against a real daemon: it initializes,
lists the fleet, replays a session from `seq` 0, sends input, answers an approval, and
verifies the hash chain itself. If it stops working, the protocol broke.

## Embedding

```elixir
{:ok, session} = Troupe.start_session(workspace: ".", agent: "plan")
Troupe.subscribe(session.id)
Troupe.send_input(session.id, "where is the retry logic?")
# => {:troupe_event, session_id, %Troupe.Protocol.Event{type: "llm_delta", ...}}
```

`Troupe.start_session/1`, `send_input/4`, `subscribe/1`, `cancel/1`, `resume/2`,
`activate/1`, `snapshot/2`, `agent_tree/1`. Telemetry is emitted at
`[:troupe, :llm, :start | :stop]`, `[:troupe, :tool, :stop]` and
`[:troupe, :agent, :transition]`.

## The remote

Remote workers and the control plane are in this repository too. `apps/troupe_plane`
is the plane — the harness API, the admin panel, the OIDC relying party;
`apps/troupe_operator` turns a `WorkerProfile` into a namespace of pods; and
`apps/troupe_worker` is the same daemon running inside one of them. The same JSON-RPC
runs over a WebSocket to a worker, `troupe --remote` speaks it, and `troupe hq` is
built on `fleet` and `session.list` rather than on anything local, so it shows remote
sessions beside local ones without changing.

`charts/troupe` deploys the lot;
[docs/deploying-on-scaleway.md](docs/deploying-on-scaleway.md) says how, including
`values.small.yaml` for one plane, one operator and a handful of workers.

`apps/troupe_a2a` is the A2A facade: every profile as an agent other agents can call,
with an agent card at `/a2a/<profile>/.well-known/agent-card.json` and `message/send`,
`message/stream`, `tasks/get` and `tasks/cancel` mapped onto sessions, inputs, the
event stream and approvals. It is one more protocol client — it depends on
`troupe_protocol` alone, holds no credential of its own, and exchanges each caller's at
the plane — and [docs/a2a.md](docs/a2a.md) has the mapping and the auth.

The TUI in this repository is now the protocol's test harness rather than the product's
face. It exercises every method a client needs, it is what CI drives, and `mix
troupe.boundaries` holds it to `troupe_protocol` alone — which is what keeps "no private
access" true for the clients people actually use, which live in their own repositories
and speak the same protocol.

## Not included

No MCP client, no git auto-commit or undo, no auto-update, no code signing, no native
Windows-on-ARM build (the x86_64 binary runs under emulation).

## Licence

MIT.
