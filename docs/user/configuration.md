# Configuration

Troupe reads its settings from a few YAML files and the environment, checks them against
one key table, and merges them. This page says where the files are, which one wins, what
is checked, and how to see what is in effect. The last section lists every key; it is
generated from the table the loader checks against (`Troupe.Config.Schema`), so it cannot
say something the loader does not do.

## The files

| Layer | Where | What it is for |
|---|---|---|
| user | `~/.config/troupe/config.yaml`; `%APPDATA%\troupe\config.yaml` on Windows; `$TROUPE_CONFIG_HOME/config.yaml` when that is set | this machine: providers, keys, the models you use |
| project | `<workspace>/.troupe/config.yaml` | what a repository wants, committed with it |
| local | `<workspace>/.troupe/config.local.yaml` | one person's settings for one repository, such as a key; add it to `.gitignore` |
| environment | `TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_AUTH`, `TROUPE_AUTH_TOKEN`, `TROUPE_MODEL`, `TROUPE_SMALL_MODEL`, `TROUPE_EXPENSIVE_MODEL`, `TROUPE_MODEL_PRICES` (`models.prices` as JSON), `TROUPE_FAKE_SCRIPT` | a provider for one shell, or for a pod |
| command line | `--auto-approve`, `--watch`, `--full-send`, and what a client asks for | one session |

Each layer beats the ones above it: the defaults, then the user file, the project file,
the local file, the environment, and the command line last. A file that is not there is
not an error.

## How the layers merge

Maps merge by key, as [RFC 7396](https://www.rfc-editor.org/rfc/rfc7396) says: a
project file that adds one provider keeps the user file's others, and one that sets
`models.cheap` keeps the user's `models.default`. `null` removes what a lower layer set.
A list replaces the list below it.

```yaml
# ~/.config/troupe/config.yaml
providers:
  gateway:
    type: openai
    base_url: https://llm-gw.example/v1
    api_key: "{env:GATEWAY_KEY}"
models:
  default: gateway/glm-5.2
```

```yaml
# <workspace>/.troupe/config.local.yaml: the workspace is on trusted_workspaces
providers:
  local:
    type: openai
    base_url: http://localhost:11434/v1
models:
  cheap: local/qwen3
```

In that workspace both providers are there, the default model is the gateway's and the
cheap one is local.

## What is checked

A file is refused, and no session starts, when it is not YAML, when a value has the
wrong type, when an enum has a value nobody knows (`approvals`, `auth`, `provider`, a
provider's `type`, an MCP server's `permission`), when it spells one setting two ways,
or when its `version` is newer than this Troupe reads. The message names the file, the
line when it can, the key, and what to write instead.

A key Troupe does not know is ignored with a warning that names it and the key it
probably meant: `max_tokns` is `max_tokens`. Keys that start with `x-` are left alone, for
notes and for other tools. `troupe config validate` exits non-zero on any warning, so CI
can run it on a repository's `.troupe/`.

`yes`, `no`, `on` and `off` are words in the YAML Troupe reads, not booleans. For a
boolean key they are read as the boolean they mean, with a warning, so `auto_approve: no`
is off; write `true` or `false`.

A file without `version` is version 1, the only one there is.

## Secrets from the environment

Any string may read a variable as `{env:VAR}`, which keeps a key out of the file:

```yaml
api_key: "{env:ANTHROPIC_KEY_FOR_TROUPE}"
```

A variable that is not set refuses what uses it and names the variable: a provider is
refused and a request to it fails with that message, an MCP server is not started, and
anywhere else the file is refused. Nothing unset is sent anywhere, as an empty string or
as the placeholder.

`ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are used when a provider has no key of its own,
and only when the provider is the vendor's own endpoint. A gateway configured without a
key is sent none.

## Trusted workspaces

A repository's files come from whoever wrote the repository. Some keys decide what a
session may do without asking, where requests go and with which key, what runs on this
machine and what may be read, and those are read from a workspace's own files only once
you trust the workspace:

- approvals: `auto_approve`, `approvals`, `managed_permission_rules_only`, `managed_mcp_servers_only`
- endpoints and credentials: `provider`, `base_url`, `api_key`, `auth`, `providers`
- commands to run: `mcp`
- paths: `read_roots`, `state_dir`, `fake_script`

Until then they are ignored with a warning that names the command to run, and the rest
of the file applies. Trusting a workspace is a line in the user file:

```yaml
trusted_workspaces:
  - ~/src/my-service
  - ~/src/work            # a directory trusts everything under it
```

```sh
troupe config trust [PATH]     # add the workspace (default: this directory)
troupe config untrust [PATH]   # remove it
troupe config trust --list     # what is on the list
```

`trust` and `untrust` change that one list and leave the rest of the file, comments
included, as it was; the file as it was is kept beside it as `config.yaml.previous`.
A list written in brackets is written out one item a line. A git worktree of a trusted
checkout is trusted too, which is where a branch session works, and `trust` in a
worktree adds the checkout. `untrust` does not remove a directory above the workspace,
which trusts other workspaces too; it says which one still trusts it.
`trusted_workspaces` is read only from the user file. A session on a team's pod
never reads these keys from a project's file, trusted or not: a pod's provider and key
come from its profile.

## Your own MCP servers and skills

Beside `config.yaml` there are two more files a person keeps, in the shape other tools
already use, so what you have for Claude Code, Claude Desktop, Cursor or VS Code comes
over as it is:

```
<config>/mcp.json              your MCP servers, on every workspace
<config>/skills/<name>/SKILL.md   your skills
<workspace>/.troupe/mcp.json   the workspace's servers, for whoever opens the repository
<workspace>/.troupe/skills/    the workspace's skills
```

`mcp.json` is `{"mcpServers": {name: {"command", "args", "env"}}}` — or `{"url"}` —
with one key of Troupe's own: `"include": ["~/.claude/.mcp.json"]` reads another file
in place. `${VAR}` in an imported file becomes `{env:VAR}`, read as the rest of the
configuration reads it. A `skills.json` beside a `skills/` directory does the same for
directories of skills: `{"include": ["~/.claude/skills"]}`.

A `url` server is spoken to as the MCP specification's streamable HTTP transport has it:
`initialize` before the first call, and the session the server hands back, if it keeps
one, carried on every call after, opened again once if the server has forgotten it, and
ended when the Troupe session ends.

The layers stack the way the config files do: the workspace's file over yours over
`config.yaml`'s `mcp:`, an entry of the same name merged key by key, so a workspace can
say `{"fs": {"disabled": true}}` and no more. The TUI's `/mcp` page and the desktop
app's "Servers and skills" panel show every server and skill with the layer and file it
came from, import a file (`/mcp import <path>`, `/skills import <path>`, or `link` to
read it in place), remove one, and try a server before it is kept.

A workspace's servers are commands a cloned repository would run, so a session starts
them only after asking you — once per workspace when you answer `allow`, which is kept
in Troupe's state directory and never in the repository, and asked again when a
server's command changes. A workspace on `trusted_workspaces` is not asked. Your own
skills are offered to every agent; a bundle's stay as its profiles list them.

### A server that wants you to sign in

Some servers act as *you*: they answer a call without a sign-in with `401`, name an
authorization server (your organisation's identity provider, often), and then call what
is behind them as you, or show you only what is yours. A key in `env` will not do for
those. Give the entry an `oauth` with the id of a client registered for it with that
authorization server — whoever runs the server says what it is, since a provider with
no dynamic registration has no other way to know Troupe:

```json
{
  "mcpServers": {
    "wiki": {
      "url": "https://mcp.example.com/mcp",
      "oauth": {"client_id": "00000000-0000-0000-0000-000000000000"}
    }
  }
}
```

The rest is found from the server: where to sign in (its protected-resource metadata
and the authorization server's), and which scopes it wants. `oauth.scopes` overrides
them; `offline_access` is added when the authorization server offers it, so the sign-in
lasts beyond the hour. `oauth.redirect_uri` fixes where the browser comes back, for a
client registered with one port (`http://localhost:33418/callback`); left out, it is
`http://127.0.0.1/callback` on any free port, which a client registered with a loopback
redirect accepts. `oauth.resource: false` leaves out the resource indicator for an
authorization server that refuses it (Microsoft Entra ID's v2.0 endpoint is one; the
scopes say which API the token is for there). `oauth.issuer` names the authorization
server for a server that publishes no metadata of its own.

Then sign in: `/mcp sign-in wiki` in the TUI, or `s` on the server's line of the `/mcp`
page, or **Sign in** on the desktop app's "Servers and skills" panel. Your browser
opens on the provider's page; when you are done it comes back to the daemon, which
listens for it on this machine, so open the URL on the machine the daemon runs on. The
page says "signed in as …", and a session waiting for the server gets its tools at once.
The sign-in is kept in Troupe's state directory (`mcp-oauth.json`, readable by you
alone), never in `mcp.json`, and refreshed when it runs out. When the provider stops
taking it, the server's line says to sign in again, and a tool the model calls answers
`sign_in_required` instead of failing. `/mcp sign-out wiki`, `o`, or **Sign out**
forgets it. A workspace's server is signed in to only after the workspace's servers are
allowed, since its `oauth` came with the repository.

A session on your team's pod does not get these tools yet: the sign-in stays on your
machine, and the path that offers your own tools to a pod session is the next step.

## Instruction files

A repository that carries an `AGENTS.md` has told coding agents how to work in it, and
Troupe reads it the way the other tools do, with no setup of its own. Every agent's
system prompt opens with these, in this order, each read from disk at every turn so an
edit takes effect on the next one:

1. `<config>/AGENTS.md` — your own, for every repository.
2. `AGENTS.md` at the repository root (the nearest directory with a `.git`; a worktree
   reads its own checkout's).
3. `AGENTS.md` in each directory between the root and the directory the session works
   in, the nearest last.
4. `.troupe/memory.md`, the project brief Troupe's own agents write.

Every file applies. Where two disagree, the nearer wins. In one directory `AGENTS.md`,
`CLAUDE.md`, `GEMINI.md` and `.github/copilot-instructions.md` are the same file under
other tools' names: the first that exists is read and the rest are skipped, and the
session's log and `/context` say which, so nobody debugs a file that was never loaded.
Not read yet: `.cursor/rules/*.mdc`, `@path` imports inside a file, and a nested
`AGENTS.md` below the directory the session works in.

The files share one budget, `instructions_max_chars` (16,000 characters). The nearest is
kept whole first; a file the remainder cannot hold is cut, or left out, and the prompt
says so where it happened. The brief has its own, `memory_max_chars`. `/context` in the
terminal UI, and `context.get` over the protocol, list every file in force with its
scope, its size, what reached the prompt and its share of the budget; the session's
`instructions_loaded` event records the same whenever what was read changed.

## Every file Troupe reads

In one table, in the order each kind is read, and what happens when two say different
things:

| File | Layer | What it is for | On conflict |
|---|---|---|---|
| `<config>/config.yaml`, then `<workspace>/.troupe/config.yaml`, then `.troupe/config.local.yaml`, then the environment, then the command line | settings | every key above | later beats earlier; maps merge by key, `null` removes, a list replaces; trusted keys come from a workspace's files only once it is trusted |
| `~/.config/opencode/opencode.jsonc` and `~/.local/share/opencode/auth.json` | settings | providers and the default model an opencode setup already has | read only when Troupe has no key of its own; never written |
| `<config>/mcp.json`, then `<workspace>/.troupe/mcp.json` | MCP servers | your servers, then the workspace's, over `mcp:` in `config.yaml` | the same name merges key by key, the workspace's file last; a workspace's servers run only once you allow them |
| `<config>/skills/<name>/SKILL.md`, `<workspace>/.troupe/skills/`, a profile's bundle | skills | what a skill tool may read | one name, the nearer layer's |
| Troupe's built-in agents, a profile's bundle, `<config>/agents/*.md`, `<workspace>/.troupe/agents/*.md` | agents | the agents a session may run | a file at a higher layer replaces the same name below it |
| `<workspace>/.troupe/workflows/<name>.json` | workflows | the steps `workflows.list` offers | one name, one file |
| `<config>/AGENTS.md`, the repository root's `AGENTS.md`, one per directory down to the workspace (aliases `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, first found wins) | instructions | what the people who work here wrote for agents | all apply; the nearer wins where two disagree; the nearest kept whole when the budget runs out |
| `<workspace>/.troupe/memory.md` | instructions | the project brief Troupe's agents write | read after the instruction files; never authoritative, `read_file` and `grep` are |

## Old spellings

Each setting has one name. The old ones still load until version 2, each with a warning
that names the new one, and a file that uses both spellings of one setting is refused.

| Old | New |
|---|---|
| `model` | `models.default` |
| `small_model`, `models.small` | `models.cheap` |
| `expensive_model` | `models.expensive` |
| `windows` | `models.windows` |
| `auth_token: KEY` | `api_key: KEY` with `auth: bearer`, top level or in a provider |

Loading never rewrites a file, because a rewrite drops its comments. `troupe config
migrate` prints, for each file, the rewrite that stops the warnings, and `troupe config
migrate --write` makes it and keeps the file as it was beside it as
`config.yaml.previous`.

The terminal UI's settings page, the desktop app's model settings and a budget raised
for a workspace do not rewrite a file: they change the lines of the settings they set,
written by the new names, and leave every other line, comments included, as it was. The
file before the save is kept as `config.yaml.previous` all the same.

## Seeing what is in effect

```sh
troupe config                       # the providers and models, and any warnings
troupe config --explain             # every key, its value and the layer that set it
troupe config --explain max_turns   # one key's ladder: each layer's value, and the one in effect
troupe config --explain --json      # the same for a program
troupe config validate              # every file a session here would read; exits 1 on any problem
troupe config validate .troupe/config.yaml
troupe config migrate [--write]
troupe config trust --list          # the workspaces whose own files set the trusted keys
```

Secrets are masked everywhere. `troupe-daemon config` takes the same arguments.

## Editors

The schema is `protocol/schema/config/v1.json` in the repository. Files Troupe writes
start with a comment an editor with a YAML language server reads:

```yaml
# yaml-language-server: $schema=https://troupe.dev/schema/config/v1.json
version: 1
```

That URL is the schema's id. Until it is served, point the comment at the file in a
checkout, or at its raw URL on GitHub.

## Examples

The smallest useful file, with the key in the environment:

```yaml
version: 1
provider: anthropic
api_key: "{env:ANTHROPIC_KEY_FOR_TROUPE}"
models:
  default: claude-opus-5
  cheap: claude-haiku-4-5
```

A LiteLLM gateway in front of Anthropic, which renames the models and takes a bearer
token:

```yaml
version: 1
providers:
  gateway:
    type: anthropic
    base_url: https://llm-gw.example/anthropic/v1
    api_key: "{env:GATEWAY_TOKEN}"
    auth: bearer
    models:
      claude-opus-5: {id: eu.anthropic.claude-opus-5, context: 400000, max_output: 64000}
      claude-haiku-4-5: {id: eu.anthropic.claude-haiku-4-5, context: 200000}
models:
  default: gateway/claude-opus-5
  cheap: gateway/claude-haiku-4-5
```

A price for a model the catalog does not price, such as one a LiteLLM gateway serves
and streams, in dollars per million tokens by the name the model is addressed with. What
the gateway says a call cost still wins, and then the catalog's price
(`troupe models --refresh`); a call none of the three prices counts as free, and the
daemon's log says so once a session. `troupe models` shows each model's price and where
it came from, or `no price`, and `troupe config --explain models.prices` which file set
it.
`TROUPE_MODEL_PRICES` takes the same map as JSON, which is how a profile's `llm.prices`
reaches its pods.

```yaml
version: 1
provider: openai
base_url: https://llm-gw.example/v1
api_key: "{env:GATEWAY_TOKEN}"
models:
  default: qwen3-235b
  prices:
    qwen3-235b: {input: 0.5, output: 1.5}   # what your gateway charges; these are an example
```

An unattended session that is told no rather than left waiting, on a smaller budget:

```yaml
version: 1
approvals: deny
max_turns: 20
wall_clock_ms: 600000
```

## Every key

`Set by` says which files may set a key. "user; project if trusted" keys are read from a
workspace's files only once it is trusted; every key may also come from the environment
or the command line where one exists for it.

<!-- config-keys:begin -->
### File

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `version` | integer | `1` | any | The version of this format. A file without it is version 1. |
| `$schema` | string |  | any | Where an editor finds this schema. Troupe does not read it. |

### Model and provider

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `provider` | `anthropic` \| `openai` \| `fake` | `anthropic` | user; project if trusted | The session-wide provider's API. |
| `base_url` | string |  | user; project if trusted | The session-wide provider's URL. Unset: the vendor's own endpoint. |
| `api_key` | string |  | user; project if trusted | The session-wide provider's key. `{env:VAR}` reads it from the environment. |
| `auth` | `api_key` \| `bearer` | `api_key` | user; project if trusted | How the key is sent: the vendor's own header, or `Authorization: Bearer`. |
| `providers` | map of name to settings |  | user; project if trusted | Named providers. A model spelled `<provider>/<model>` goes to that provider. |
| `providers.<name>.type` | `openai` \| `anthropic` | `openai` | user; project if trusted | The API it speaks. A gateway such as LiteLLM or vLLM is `openai`. |
| `providers.<name>.base_url` | string |  | user; project if trusted | Where it is. Unset: the vendor's own endpoint. |
| `providers.<name>.api_key` | string |  | user; project if trusted | Its key. `{env:VAR}` reads it from the environment. |
| `providers.<name>.auth` | `api_key` \| `bearer` | `api_key` | user; project if trusted | How the key is sent: the vendor's own header, or `Authorization: Bearer`. |
| `providers.<name>.models` | map of name to settings |  | user; project if trusted | The models it serves, by the name Troupe addresses them with. |
| `providers.<name>.models.<model>.id` | string |  | user; project if trusted | The id that goes on the wire, when the gateway renamed the model. Unset: the name. |
| `providers.<name>.models.<model>.context` | integer ≥ 1 |  | user; project if trusted | The model's context window, in tokens. |
| `providers.<name>.models.<model>.max_output` | integer ≥ 1 |  | user; project if trusted | The most output tokens to ask for. |
| `providers.<name>.models.<model>.reasoning_effort` | string or integer |  | user; project if trusted | How hard the model should think: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or a thinking budget in tokens. |
| `models` | settings |  | any | Which model each role uses. |
| `models.default` | string | `claude-sonnet-5` | any | The model every agent uses unless its definition names one. |
| `models.cheap` | string |  | any | The model for small jobs, compaction summaries among them. Unset: the default model. |
| `models.expensive` | string |  | any | The model an agent asking for `expensive` gets. Unset: the default model. |
| `models.windows` | map of name to integer ≥ 1 |  | any | Context windows for bare model ids, in tokens. |
| `models.prices` | map of name to settings |  | any | Prices for models the provider's catalog does not price, by the name a model is addressed with. What a gateway says a call cost still wins, then the catalog's price. |
| `models.prices.<model>.input` | number ≥ 0 |  | any | Dollars per million input tokens. |
| `models.prices.<model>.output` | number ≥ 0 |  | any | Dollars per million output tokens. |
| `models.prices.<model>.cache_read` | number ≥ 0 |  | any | Dollars per million prompt tokens read from the cache. Unset: the input price. |
| `models.prices.<model>.cache_write` | number ≥ 0 |  | any | Dollars per million prompt tokens written to the cache. Unset: the input price. |
| `max_tokens` | integer ≥ 1 | `8192` | any | The most output tokens one model call asks for. |
| `context_window` | integer ≥ 1 | `200000` | any | The window assumed when neither a provider nor the catalog says. |
| `compact_at` | number, 0 to 1 | `0.75` | any | The share of the window at which an agent summarises older turns. |
| `llm_timeout_ms` | integer ≥ 1 | `300000` | any | How long one model call may take before it is given up on. |

### Budget

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `max_turns` | integer ≥ 1 | `40` | any | Model calls an agent may make. |
| `max_input_tokens` | integer ≥ 1 | `2000000` | any | Input tokens an agent may spend. |
| `max_output_tokens` | integer ≥ 1 | `400000` | any | Output tokens an agent may spend. |
| `wall_clock_ms` | integer ≥ 1 | `1800000` | any | How long an agent may run. |
| `max_depth` | integer ≥ 0 | `3` | any | How deep agents may delegate; 1 means the root alone may. |
| `budget_warn_at` | number, 0 to 1 | `0.8` | any | The share of any limit at which the agent is warned. |
| `full_send` | boolean | `false` | any | No budget warnings. |
| `budget_asks` | boolean | `true` | any | A spent budget asks the person attached, rather than stopping. |

### Approvals

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `auto_approve` | boolean | `false` | user; project if trusted | Run every tool call without asking. |
| `approvals` | `wait` \| `deny` | `wait` | user; project if trusted | What a call that asks does with nobody attached: wait, or be denied. |
| `managed_permission_rules_only` | boolean | `false` | user; project if trusted | A session may not allow a tool for itself. |
| `managed_mcp_servers_only` | boolean | `false` | user; project if trusted | A client may not offer a session its own tools. |

### Tools

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `shell_timeout_ms` | integer ≥ 1 | `120000` | any | How long a shell command may run. |
| `tool_output_limit` | integer ≥ 1 | `60000` | any | Bytes of a tool's output the model sees. |
| `tool_failures_note_at` | integer ≥ 0 | `5` | any | Failures of one tool in a row after which the model is told to stop and reconsider; 0 never. |
| `tool_failures_stop_at` | integer ≥ 0 | `10` | any | Failures of one tool in a row that stop the turn and ask whether it goes on, budget or not; 0 never. |
| `read_roots` | list of strings |  | user; project if trusted | Directories outside the workspace the read tools may reach. |
| `mcp` | map of name to settings |  | user; project if trusted | The workspace's own MCP servers, by name. |
| `mcp.<name>.command` | string |  | user; project if trusted | A server on its standard streams: the program to run. |
| `mcp.<name>.args` | list of strings |  | user; project if trusted | Its arguments. |
| `mcp.<name>.env` | map of name to string |  | user; project if trusted | Variables to set for it. |
| `mcp.<name>.cd` | string |  | user; project if trusted | The directory to run it in. Unset: the workspace. |
| `mcp.<name>.url` | string |  | user; project if trusted | A server over HTTP: its URL. |
| `mcp.<name>.oauth` | settings |  | user; project if trusted | A server over HTTP that wants you signed in: how to sign in. |
| `mcp.<name>.oauth.client_id` | string |  | user; project if trusted | A client registered in advance with the server's authorization server. |
| `mcp.<name>.oauth.scopes` | list of strings |  | user; project if trusted | The scopes to ask for. Unset: what the server says it wants. |
| `mcp.<name>.oauth.redirect_uri` | string |  | user; project if trusted | Where the browser comes back: `http://` on 127.0.0.1, [::1] or localhost. Unset: 127.0.0.1, any free port. |
| `mcp.<name>.oauth.resource` | boolean | `true` | user; project if trusted | Send the resource indicator; `false` for an authorization server that refuses it. |
| `mcp.<name>.oauth.issuer` | string |  | user; project if trusted | The authorization server, for a server that publishes no metadata naming one. |
| `mcp.<name>.permission` | `ask` \| `auto` | `ask` | user; project if trusted | `auto` runs its tools without asking. |
| `mcp.<name>.timeout_ms` | integer ≥ 1 | `30000` | user; project if trusted | How long one call may take. |

### Watching

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `watch` | boolean | `false` | any | Act on `AI!` and `AI?` comments. |
| `watch_debounce_ms` | integer ≥ 0 | `300` | any | How long watch mode waits for writes to settle. |
| `watch_poll_interval_ms` | integer ≥ 1 | `1000` | any | How often watch mode polls where it cannot be told. |
| `fs_events` | boolean | `false` | any | Record every file change in the workspace as an event. |
| `fs_debounce_ms` | integer ≥ 0 | `100` | any | How long file events wait for writes to settle. |

### Sessions

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `default_agent` | string | `build` | any | The agent a session starts with. |
| `resume_on_restart` | boolean | `false` | any | A session that comes back after a restart carries on by itself. |
| `loop_max_iterations` | integer ≥ 1 | `10` | any | Turns `/loop` runs when not told. |
| `loop_max_failures` | integer ≥ 1 | `3` | any | Failed turns in a row that stop a loop. |
| `memory` | boolean | `true` | any | Agents read and write the project brief, `.troupe/memory.md`. |
| `memory_auto_refresh` | boolean | `true` | any | A new session in a git repository refreshes a missing or stale brief, but not within `memory_max_age_days` of a refresh that built nothing; never a headless run. |
| `memory_max_chars` | integer ≥ 1 | `6000` | any | How much of the brief goes into a prompt. |
| `memory_max_age_days` | integer ≥ 1 | `7` | any | How old the brief may be before it counts as stale. |
| `instructions_max_chars` | integer ≥ 1 | `16000` | any | How many characters of instruction files (`AGENTS.md` and its aliases, every scope together) go into a prompt; the nearest are kept whole first. |

### This machine

| Key | Type | Default | Set by | What it does |
|---|---|---|---|---|
| `trusted_workspaces` | list of strings |  | user file only | Workspaces whose own files may set the keys marked trusted. A path trusts everything under it. |
| `state_dir` | string |  | user; project if trusted | Where session logs go. Unset: the platform's state directory. |
| `fake_script` | string |  | user; project if trusted | With `provider: fake`, the file of scripted answers. |
| `mouse` | boolean | `true` | any | The terminal UI captures the mouse. |
<!-- config-keys:end -->
