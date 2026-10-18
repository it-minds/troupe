# Configuration

Troupe reads its settings from a few YAML files and the environment, checks them against
one key table, and merges them. This page says which file wins, what is checked, and how
to see what is in effect; the last section lists every key, generated from the table the
loader checks against (`Troupe.Config.Schema`), so it cannot say something the loader
does not do. Where each file is on disk is on [Where your files are](configuration/files.md),
and complete files are in the [cookbook](configuration/cookbook.md).

## The files

| Layer | Where | What it is for |
|---|---|---|
| org | the organisation's `defaults:`, from the plane you are signed in to (kept as `organisation.json` in the state directory) and from a managed file ([where](configuration/files.md#what-troupe-keeps-for-itself)) | what your organisation suggests: a provider, a gateway, the models |
| user | `<config>/config.yaml`: `~/.config/troupe/config.yaml`, `%APPDATA%\troupe\config.yaml` on Windows, `$TROUPE_CONFIG_HOME/config.yaml` when that is set | this machine: providers, keys, the models you use |
| project | `<workspace>/.troupe/config.yaml` | what a repository wants, committed with it |
| local | `<workspace>/.troupe/config.local.yaml` | one person's settings for one repository, such as a key; add it to `.gitignore` |
| environment | `TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_AUTH`, `TROUPE_AUTH_TOKEN`, `TROUPE_MODEL`, `TROUPE_SMALL_MODEL`, `TROUPE_EXPENSIVE_MODEL`, `TROUPE_MODEL_PRICES` (`models.prices` as JSON), `TROUPE_FAKE_SCRIPT`; `TROUPE_THINKING_BINDING` and `TROUPE_SYSTEM_PROMPT`, issue #465's two settings | a provider for one shell, or for a pod; a setting changed for one `troupe bench --live` |
| command line | `--auto-approve`, `--watch`, `--full-send`, and what a client asks for | one session |
| enforced | the organisation's `enforced:`, from the same two places | what your organisation does not let a machine go past |

Each layer beats the ones above it: the defaults, the organisation's defaults, the user
file, the project file, the local file, the environment, the command line, and what the
organisation enforces last. A file that is not there is not an error. `<config>`, the
user file's directory, holds every other file of your own too (`mcp.json`, `agents/`,
`skills/`, `commands/`, the terminal client's `credentials.json`).

## Your organisation's defaults and limits

An organisation speaks at both ends of the ladder. Its **defaults** sit below your own
file: they are what a machine starts with, and anything you set wins over them. What it
**enforces** sits above everything, the command line included. That is a guardrail, not a
lock: a plane's copy is a file in your own state directory, and only the managed file is
out of your reach ([security](../admin/security.md#7-an-organisations-limits-are-a-guardrail-not-a-lock)).

Only these keys can be enforced, and each but the rules is a ceiling:

| Key | Enforced, it means |
|---|---|
| `max_tokens`, `max_turns`, `wall_clock_ms`, `max_depth` | the most it may be: you may set a lower number, not a higher one |
| `approvals` | `deny` may not be loosened to `wait` |
| `managed_mcp_servers_only`, `managed_permission_rules_only` | on may not be turned off |
| `provider`, `base_url` | what it is; a named provider at another URL, or of another type, is refused too |
| `permissions` | its [per-tool rules](#per-tool-permission-rules) are added to yours, and none of yours loosens one of them |

A file, a variable or a flag that tries to go past an enforced value is held to it, with
one warning naming the file, the key and the organisation's value, and `config.set`
refuses it from either client. When a session reaches an enforced `max_turns` or
`wall_clock_ms`, the question whether to go on offers only what stays under it, says the
limit is your organisation's and where it came from, and turns away a larger amount,
`no limit` and an `allow` past it. A model entry's own `max_output` can lower an enforced `max_tokens` for
its model, not raise it. An enforced `max_tokens` bounds the whole of every model call, a
compaction's summary and a model's thinking included
([how thinking is fitted under it](models.md#how-hard-a-model-thinks)).

`troupe config --explain KEY` shows both ends with where they came from:

```text
max_turns = 25
  default  40
  user     80                             /home/me/.config/troupe/config.yaml
           ignored: held to 25 by your organisation (https://plane.example.com)
  enforced 25                             https://plane.example.com  <- in effect
```

The organisation's word comes from two places. Signed in to a plane (`troupe login`), the
daemon fetches its document whenever a client connects and keeps a copy, used as it is
when the plane cannot be reached; `troupe config pull` fetches it now, and writes nothing
into `config.yaml`. What a pull before 0.14 wrote there is your own setting and wins over
the organisation's defaults; `pull` names those keys, and taking the lines out follows the
organisation again. Without a plane, an administrator writes a managed file. Where both
say something, the plane's defaults win over the file's, the stricter of two limits holds,
and a provider or URL both fix is the managed file's. The format, and how an administrator
sets either, is on the administrator's
[configuration page](../admin/configuration.md#defaults-and-limits-for-peoples-machines).

## How the layers merge

Maps merge by key, as [RFC 7396](https://www.rfc-editor.org/rfc/rfc7396) says: a project
file that adds one provider keeps the user file's others, and one that sets
`models.cheap` keeps the user's `models.default`. `null` removes what a lower layer set. A
list replaces the list below it, except `permissions`, where every file's rules are kept
together ([per-tool permission rules](#per-tool-permission-rules)).

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
    type: ollama
models:
  cheap: local/qwen3
```

In that workspace both providers are there, the default model is the gateway's and the
cheap one is local.

## What is checked

A file is refused, and no session starts, when it is not YAML, when a value has the wrong
type, when an enum has a value nobody knows (`approvals`, `auth`, `provider`, a provider's
`type`, an MCP server's `permission`), when it spells one setting two ways, or when its
`version` is newer than this Troupe reads. The message names the file, the line when it
can, the key, and what to write instead.

A key Troupe does not know is ignored with a warning that names it and the key it probably
meant: `max_tokns` is `max_tokens`. Keys that start with `x-` are left alone, for notes and
for other tools. `troupe config validate` exits non-zero on any warning, so CI can run it
on a repository's `.troupe/`.

`yes`, `no`, `on` and `off` are words in the YAML Troupe reads, not booleans. For a
boolean key they are read as the boolean they mean, with a warning, so `auto_approve: no`
is off; write `true` or `false`. A file without `version` is version 1, the only one there
is.

## Secrets from the environment

Any string may read a variable as `{env:VAR}`, which keeps a key out of the file:

```yaml
api_key: "{env:ANTHROPIC_KEY_FOR_TROUPE}"
```

A variable that is not set refuses what uses it and names the variable: a provider is
refused and a request to it fails with that message, an MCP server is not started, and
anywhere else the file is refused. Nothing unset is sent anywhere, as an empty string or
as the placeholder.

`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` and `GEMINI_API_KEY` are used
when a provider of that type has no key of its own, and only when the provider is the
vendor's own endpoint. A gateway configured without a key is sent none.

## Trusted workspaces

A repository's files come from whoever wrote the repository. The keys that decide what a
session may do without asking, where requests go and with which key, what runs on this
machine and what may be read are read from a workspace's own files only once you trust
the workspace:

- approvals: `auto_approve`, `approvals`, `delegation`, `managed_permission_rules_only`, `managed_mcp_servers_only`, `watch`, `watch_auto_approve`
- endpoints and credentials: `provider`, `base_url`, `api_key`, `auth`, `providers`, `identify`
- commands to run: `mcp`
- paths: `read_roots`, `state_dir`, `fake_script`

Until then they are ignored with a warning that names the command to run, and the rest of
the file applies. Trusting a workspace is a line in the user file, and
`trusted_workspaces` is read only from there:

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

`trust` and `untrust` change that one list, keep the rest of the file and its comments,
and keep the file as it was beside it as `config.yaml.previous`; a list written in
brackets is written out one item a line. A git worktree of a trusted checkout is trusted
too, which is where a branch session works, and `trust` in a worktree adds the checkout.
`untrust` does not remove a directory above the workspace, which trusts other workspaces
too; it says which one still does. A session on a team's pod never reads these keys from a
project's file, trusted or not: its provider and key come from its profile.

A workspace's agents and MCP servers wait for the same answer. A `.troupe/agents/<name>.md`
whose `permissions:` sets a tool to `auto` runs it unasked only once the workspace is
trusted; until then the tool asks as it would without the file, and `agents.list` gives
the agent a note naming the command. Its `ask` and `deny` apply either way, and your own
`<config>/agents/` and the built-ins are not the workspace's. Its servers' `auto`, and
what its `mcp.json` or `skills.json` includes from outside the repository, wait too
([MCP servers and skills](mcp.md#a-workspaces-servers-wait-for-you)).

Trusted or not, a workspace's `.troupe/agents`, `commands`, `workflows` and `skills` are
read only where they really are inside it: a file there, or the whole directory, that
links elsewhere on the machine is not read, and is listed with why in `agents.list`,
`skills.list` and the session's log. Reaching outside the repository is what a trusted
`skills.json` is for.

## Agents, MCP servers and instructions

Beside `config.yaml` are files with pages of their own:

- **Agents, commands and workflows** (`agents/`, `commands/`, a repository's
  `.troupe/workflows/`), and a delegation shown before it runs (`delegation.ask`):
  [agents, commands and workflows](agents.md).
- **MCP servers and skills** (`mcp.json`, `skills/`, and `.agents/skills`), how they are
  imported, the addresses the daemon may call, and signing in: [MCP servers and skills](mcp.md).
- **Instruction files** (`AGENTS.md`, `.troupe/rules/`, the project brief), and `troupe
  onboard`, which brings other tools' files into them once:
  [instruction files and onboarding](instructions.md).

### Your own commands

`<config>/commands/<name>.md` and `<workspace>/.troupe/commands/<name>.md` are slash
commands, each sending the prompt its body holds ([your own commands](agents.md#your-own-commands)).

### A server that wants you to sign in

It is given an `oauth` entry and signed in to from either client
([a server that wants you to sign in](mcp.md#a-server-that-wants-you-to-sign-in)).

## Per-tool permission rules

`permissions:` answers a tool's question before it is asked: each rule names a tool, alone
or with a pattern (a command prefix for `shell`, a path glob for the file tools,
`server.tool` for `mcp`), under `deny`, `ask` or `allow`. Every file's rules, your
organisation's included, are added together, and of those that match a call `deny` beats
`ask` beats `allow`. A project's `allow` applies only in a trusted workspace. The
[recipe](configuration/permissions.md) is a complete file, and says what a pattern
matches, how a shell line is read, which rule holds and what each does.

```yaml
permissions:
  deny: ["shell(git push)", "read_file(secrets/**)"]
  ask: ["mcp(github.create_*)"]
  allow: ["shell(mix test)", "write_file(lib/**)"]
```

`troupe config --explain permissions` lists them with their files, and the TUI's
`/settings` and the desktop app's **This computer** page show them.

## Every file Troupe reads

In the order each kind is read, and what happens when two say different things:

| File | Layer | What it is for | On conflict |
|---|---|---|---|
| the organisation's `defaults:` (the managed file, then the plane's `organisation.json`), `<config>/config.yaml`, `<workspace>/.troupe/config.yaml`, `.troupe/config.local.yaml`, the environment, the command line, the organisation's `enforced:` | settings | every key below | later beats earlier; maps merge by key, `null` removes, a list replaces; trusted keys come from a workspace's files only once it is trusted |
| `<config>/mcp.json`, then `<workspace>/.troupe/mcp.json` | MCP servers | your servers, then the workspace's, over `mcp:` in `config.yaml` | the same name merges key by key, the workspace's file last; a workspace's servers run only once you allow them |
| a profile's bundle, `~/.agents/skills/`, each `.agents/skills/` from the repository root down to the workspace, `<config>/skills/<name>/SKILL.md`, `<workspace>/.troupe/skills/` | skills | what a skill tool may read | one name, the highest on [the ladder](#which-one-wins); the others listed as skipped |
| Troupe's built-in agents, a profile's bundle, `<config>/agents/*.md`, `<workspace>/.troupe/agents/*.md` | agents | the agents a session may run | a file at a higher layer replaces the same name below it |
| `<config>/commands/*.md`, `<workspace>/.troupe/commands/*.md` | commands | the slash commands you and the repository define | one name, the workspace's; a built-in's or an agent's name is theirs |
| `<workspace>/.troupe/workflows/<name>.json` | workflows | the steps `workflows.list` offers | one name, one file |
| `<config>/AGENTS.md`, the repository root's `AGENTS.md`, one per directory down to the workspace and to each file the conversation worked on, each directory's `.agents/AGENTS.md` before its own and its `.troupe/rules/*.md` after it, and the files each imports with `@path` | instructions | what the people who work here wrote for agents | all apply; the nearer wins where two disagree; the nearest kept whole when the budget runs out. Other tools' files are not read: `troupe onboard` brings them in once ([instruction files](instructions.md)) |
| `<workspace>/.troupe/memory/facts.jsonl`, and its view `.troupe/memory.md` | instructions | the project brief Troupe's agents write, as facts | its commands and conventions read after the instruction files, the rest through `recall`; never authoritative, `read_file` and `grep` are; an edit to the view is read back as facts |

## Which one wins

Where two places say different things, Troupe takes it from the one higher on this
ladder, lowest first:

1. **Troupe's built-ins**: the agents that ship with it.
2. **A profile's bundle**, on a team's pod. There the bundle's agents and skills beat the
   repository's `.agents/` and `.troupe/` unless the profile allows the repository's.
3. **`.agents/`**: `~/.agents/skills`, then each `.agents/skills` from the repository root
   down to where the session was started, the nearest highest; and each directory's
   `.agents/AGENTS.md`.
4. **`AGENTS.md`**: the repository root's, then each directory's on the way to the work,
   the nearest highest.
5. **Your `<config>/`**: `config.yaml`, `mcp.json`, `skills/`, `agents/`, `commands/`.
6. **The repository's `.troupe/`**: the same files, `rules/` and `memory.md`.

The last two are Troupe's own files, so they beat what a convention shared with other
tools says. What has a name (an agent, a skill, a command, an MCP server) comes from the
highest step that has the name, and the ones below it are not used: `skills.list` lists
each skill a higher one hid as `skipped`, naming the one that is used. Instruction files
have no name to lose: every one applies, and the higher comes later in the prompt, wins
where two disagree, and is kept whole first when the budget runs out. Your own
`<config>/AGENTS.md` is the exception, read first and so below the repository's files: it
is about every repository, and theirs is about this one.

Beside the ladder, a built-in command's name, or an agent's, stays theirs whatever a file
says, and `config.yaml`'s settings have the layers of [the files](#the-files) above and
below them.

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
migrate` prints, for each file, the rewrite that stops the warnings, and `--write` makes
it, keeping the file as it was beside it as `config.yaml.previous`. The settings pages
and a budget raised for a workspace do not rewrite a file either: they change the lines
of the settings they set, by the new names, leave every other line as it was, and keep
`config.yaml.previous` all the same.

## Seeing what is in effect

```sh
troupe config                       # the providers and models, and any warnings
troupe config --explain             # every key, its value and the layer that set it
troupe config --explain max_turns   # one key's ladder: each layer's value, and the one in effect
troupe config --explain permissions # every per-tool rule, with its file, and those held back with why
troupe config --explain --json      # the same for a program
troupe config --explain --session SESSION_ID   # what is in force in a running session, here or on a pod
troupe config validate              # every file a session here would read; exits 1 on any problem
troupe config validate .troupe/config.yaml
troupe config migrate [--write]
troupe config trust --list          # the workspaces whose own files set the trusted keys
troupe config pull                  # your organisation's defaults and limits, from the plane, now
```

A running session's configuration was read as it started, so `--session` asks where it
runs: this machine's daemon, or for a session on your team's pod the pod itself, through
the plane you are signed in to, without waking it. A pod adds `profile` (the provider and
models its worker profile gave it), `session` (the terms the session was created with),
`enforced` (what the platform enforces) and the profile's per-tool rules, each named by its
profile; a repository's own files count as on any pod, no trusted key taken from them. The
TUI's `/settings` in a pod session, and the desktop app's **Settings** pane beside a team
session, show the same and change none of it. A session that is asleep has nothing in
force: open it, and ask again.

Secrets are masked everywhere. `troupe-daemon config` takes the same arguments but `pull`
and `--session`, and one more: `import-opencode` copies opencode's providers and default
model into `config.yaml` once, since Troupe does not read opencode's settings
([from opencode](configuration/providers.md#from-opencode)).

## Settings in the desktop app and the terminal

The desktop app and the TUI show and change the same settings, and neither has a settings
file of its own: a setting is a key of the files above. The daemon serves both
(`config.get`, `config.set` and `config.changed` in the protocol), so a change made in one
shows in the other at once, and the next session either starts reads it.

- **What each shows.** Every key as a session in that workspace would read it: its value,
  and the layer and file that set it (the TUI shows the layer beside each value that is
  not a default; the desktop app does not show where a setting came from yet). Secrets
  are never shown. A key's name on the page is the `Shown as` column of the reference
  below, and its help the `What it does` there. The terminal leaves out `ui.mode` and
  `ui.notifications`, which only the desktop app acts on.
- **Where a change goes.** The desktop app's model settings, theme, light or dark and
  notifications go into your own `config.yaml`. The TUI's page writes the file the value
  on screen came from, and a default into your own; its title says which, and `s` picks
  another. A key a file may not hold is refused rather than written where it would be
  ignored: `trusted_workspaces` outside your own file, and a key marked trusted in the
  project or local file of a workspace that is not trusted, such as `auto_approve`. Only
  the key's own line changes.
- **Your organisation's.** A value from its defaults is shown as the organisation's, and
  a change you make wins over it. A key it enforces is shown as set by your organisation,
  with where from, and is not changed.
- **What follows you.** The `ui` keys: the theme both clients draw in (`ui.theme`), the
  desktop app's light or dark (`ui.mode`) and notifications (`ui.notifications`), and
  whether the terminal blinks what waits on you (`ui.blink`). The daemon keeps them and
  acts on none, as with `mouse` and `transcript.detail`. What belongs to one window (its
  size, the plane the desktop app last used, whether it opens on Home) stays there.
- **The provider.** Every place you pick one offers the same [provider types](#provider-types),
  from one list the daemon serves: `troupe setup`, `troupe config`, the TUI's `/settings`,
  the desktop app's first run and its **Models** panel. Each asks only what its type
  needs: no key for Ollama, whose address may be left to its default, and the resource's
  own address for Azure OpenAI. On a plane, a profile's `llm.provider` and the provider
  people's own machines are offered take the same names.
- **Edited by hand.** A file you edit is read at the next session and the next time a
  settings screen asks; a screen already open does not hear of it.

```yaml
version: 1
models:
  default: gateway/glm-5.2
ui:
  theme: signal
  mode: dark
  notifications: false
```

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

The [cookbook](configuration/cookbook.md) has a complete, tested file for each provider
type, a team's project file and a personal `config.local.yaml`, MCP servers, an agent, a
skill, an unattended session and per-tool rules. One more, a LiteLLM gateway in front of
Anthropic, which renames the models and takes a bearer token:

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

## Provider types

The session-wide `provider`, and a named provider's `type`, is one of the types below. A
name that is none of them refuses the file, naming the file, the key and these. A Troupe
before 0.5 read any such name as `openai`; `troupe config migrate` rewrites one that is
another's name (`litellm`, `vllm` and `lmstudio` are `openai`, `google` is `gemini`,
`azure` is `azure_openai`) and says what to write for any other. A gateway that speaks one
of these APIs, such as LiteLLM, is that type with its `base_url`.

<!-- provider-types:begin -->
| Type | Endpoint | Key | Keys that apply | Model list | Thinking | Caching |
|---|---|---|---|---|---|---|
| `anthropic` | Anthropic's Messages API at `https://api.anthropic.com`, or a gateway that speaks it at its `base_url`. | `x-api-key`, or `Authorization: Bearer` with `auth: bearer`. Without a key, `ANTHROPIC_API_KEY`, sent only to Anthropic's own endpoint. | `base_url`, `api_key`, `auth`, `models`, `binds_thinking` | `/v1/models`: each model's window, output cap and the thinking it takes; no prices. | `reasoning_effort` becomes adaptive thinking or a budget, whichever the model takes; the output cap is raised to hold it, no further than an enforced `max_tokens`. Thinking is handed back. | Troupe marks the tools, the system prompt and the conversation for Anthropic's cache; what it read and wrote is reported. |
| `openai` | OpenAI's Chat Completions at `https://api.openai.com`, or any server that speaks it (LiteLLM, vLLM, LM Studio) at its `base_url`. | `Authorization: Bearer`. Without a key, `OPENAI_API_KEY`, sent only to OpenAI's own endpoint; a server elsewhere is sent only a key of its own, and may need none. | `base_url`, `api_key`, `models` | A LiteLLM gateway's `/model_group/info`, with windows and prices, else `/v1/models`; asked only with a `base_url`. | `reasoning_effort` is sent as written, with the output cap as `max_completion_tokens`, which the reasoning spends from. Reasoning is handed back. | Whatever the server does by itself; Troupe sends no marks. What it read from its cache, and through LiteLLM what Anthropic wrote, is reported. |
| `ollama` | Ollama's OpenAI-compatible endpoint, at `http://localhost:11434` unless `base_url` says. | None. A key that is set is sent as `Authorization: Bearer`, for a proxy in front of the server. | `base_url`, `api_key`, `models` | The server's `/v1/models`, asked with no key: the models pulled there. Nothing is priced. | `reasoning_effort` is sent as written, beside `max_tokens`; the reasoning a model streams is shown. | The server keeps a loaded model's last prompt in memory by itself; nothing is billed or reported. |
| `openrouter` | OpenRouter's Chat Completions at `https://openrouter.ai/api/v1`. A model is OpenRouter's id after the provider's name: `openrouter/anthropic/claude-sonnet-4.5`. | `Authorization: Bearer`. Without a key, `OPENROUTER_API_KEY`, sent only to openrouter.ai. `HTTP-Referer` and `X-Title` name Troupe there, unless `identify: false`. | `base_url`, `api_key`, `models` | `/models`: each model's window, output cap and prices, its cache rates included. | `reasoning_effort` is sent as OpenRouter's `reasoning`: `effort`, or `max_tokens` for a number, beside `max_tokens`, which the reasoning spends from. | Whatever the model's own provider does by itself; Troupe sends no marks, so an Anthropic model there is not cached. What it read is reported. |
| `azure_openai` | Your Azure OpenAI resource, which `base_url` names: `https://<resource>.openai.azure.com`. A call goes to `/openai/deployments/<model>/chat/completions?api-version=<api_version>`, so a model's name, or its `id`, is the deployment's. | `api-key`, or `Authorization: Bearer` with `auth: bearer`, for a Microsoft Entra token. No variable stands in for a key. | `base_url` (required), `api_key`, `auth`, `api_version` (`2024-10-21` unless set), `models` | None: Azure lists deployments only through its management API, so name them under `models:`. | As `openai`: `reasoning_effort` as written, with `max_completion_tokens`. A reasoning model may need a later `api_version`. | Azure caches a long enough prompt by itself, and reports what it read. |
| `gemini` | The Gemini API's OpenAI-compatible endpoint, `https://generativelanguage.googleapis.com/v1beta/openai`. | `Authorization: Bearer`. Without a key, `GEMINI_API_KEY`, sent only to Google's endpoint. | `base_url`, `api_key`, `models` | `/models` on that endpoint: the ids, without windows or prices. | `reasoning_effort` is sent as written, beside `max_tokens`, which the thinking spends from. The thought signature Gemini puts on a tool call is handed back with it. | Gemini caches a repeated prefix by itself on the models that do; what the endpoint says it read is counted. |
| `fake` | None: scripted answers, for a packaged binary's smoke test. The session-wide `provider` only. | None. | `fake_script` | None. | None. | None. |
<!-- provider-types:end -->

An `azure_openai` provider without a `base_url` is refused, as one whose key is not set
is, and says so; so is a session-wide `provider: azure_openai`, which takes the default
`api_version`. Bedrock and Vertex are not types: each signs its requests with its own
cloud's credentials rather than taking a key, and a gateway in front of either is the type
of the API it speaks. A file for each type is in the
[provider recipes](configuration/providers.md); what each caches, how hard a model thinks
and what each call tells the provider are on [models and providers](models.md).

## Every key

`Set by` says which files may set a key. "user; project if trusted" keys are read from a
workspace's files only once it is trusted; every key may also come from the environment
or the command line where one exists for it. `Shown as` is the name a settings page shows
a key by, in the desktop app and the TUI alike.

<!-- config-keys:begin -->
### File

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `version` | integer | `1` | any |  | The version of this format. A file without it is version 1. |
| `$schema` | string |  | any |  | Where an editor finds this schema. Troupe does not read it. |

### Model and provider

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `provider` | `anthropic` \| `openai` \| `ollama` \| `openrouter` \| `azure_openai` \| `gemini` \| `fake` | `anthropic` | user; project if trusted; an organisation may enforce | provider | The session-wide provider's API; the table under Provider types says what each one does. |
| `base_url` | string |  | user; project if trusted; an organisation may enforce |  | The session-wide provider's URL. Unset: the vendor's own endpoint. |
| `api_key` | string |  | user; project if trusted |  | The session-wide provider's key. `{env:VAR}` reads it from the environment. |
| `auth` | `api_key` \| `bearer` | `api_key` | user; project if trusted |  | How the key is sent: the vendor's own header, or `Authorization: Bearer`. |
| `providers` | map of name to settings |  | user; project if trusted |  | Named providers. A model spelled `<provider>/<model>` goes to that provider. |
| `providers.<name>.type` | `anthropic` \| `openai` \| `ollama` \| `openrouter` \| `azure_openai` \| `gemini` | `openai` | user; project if trusted |  | The API it speaks; the table under Provider types says what each one does. A gateway such as LiteLLM or vLLM is `openai`. |
| `providers.<name>.base_url` | string |  | user; project if trusted |  | Where it is. Unset: the type's own, as the table under Provider types says; `azure_openai` needs one. |
| `providers.<name>.api_key` | string |  | user; project if trusted |  | Its key. `{env:VAR}` reads it from the environment. |
| `providers.<name>.auth` | `api_key` \| `bearer` | `api_key` | user; project if trusted |  | How the key is sent: the vendor's own header, or `Authorization: Bearer`. |
| `providers.<name>.api_version` | string |  | user; project if trusted |  | `azure_openai` only: the `api-version` each call names. Unset: `2024-10-21`. |
| `providers.<name>.models` | map of name to settings |  | user; project if trusted |  | The models it serves, by the name Troupe addresses them with. |
| `providers.<name>.models.<model>.id` | string |  | user; project if trusted |  | The id that goes on the wire, when the gateway renamed the model. Unset: the name. |
| `providers.<name>.models.<model>.context` | integer ≥ 1 |  | user; project if trusted |  | The model's context window, in tokens. |
| `providers.<name>.models.<model>.max_output` | integer ≥ 1 |  | user; project if trusted |  | The most output tokens to ask for. |
| `providers.<name>.models.<model>.reasoning_effort` | string or integer |  | user; project if trusted |  | How hard the model should think: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or a thinking budget in tokens. An Anthropic model gets it in the form it takes. |
| `providers.<name>.models.<model>.binds_thinking` | boolean |  | user; project if trusted |  | Whether the model binds its thinking to the conversation it was made in, as Claude Fable 5.1, Opus 5.5 and Sonnet 5.5 do, so its tools stay the same all session: for a name that hides the model. Unset: the provider's, else what its model list says, else its name. |
| `providers.<name>.binds_thinking` | boolean |  | user; project if trusted |  | Whether the models it serves bind their thinking to the conversation, unless a model's entry says. Unset: what its model list says, else each model's name. |
| `models` | settings |  | any |  | Which model each role uses. |
| `models.default` | string | `claude-sonnet-5` | any | model | The model every agent uses unless its definition names one. A bare id goes to the session-wide provider; `<provider>/<model>` goes to a named one, from `providers`. `troupe models` lists what this machine can address. |
| `models.cheap` | string |  | any | cheap model | The model for small jobs, compaction summaries among them. Unset: the default model. |
| `models.expensive` | string |  | any | expensive model | The model an agent asking for `expensive` gets. Unset: the default model. |
| `models.windows` | map of name to integer ≥ 1 |  | any |  | Context windows for bare model ids, in tokens. |
| `models.prices` | map of name to settings |  | any |  | Prices for models the provider's catalog does not price, by the name a model is addressed with. What a gateway says a call cost still wins, then the catalog's price. |
| `models.prices.<model>.input` | number ≥ 0 |  | any |  | Dollars per million input tokens. |
| `models.prices.<model>.output` | number ≥ 0 |  | any |  | Dollars per million output tokens. |
| `models.prices.<model>.cache_read` | number ≥ 0 |  | any |  | Dollars per million prompt tokens read from the cache. Unset: the input price. |
| `models.prices.<model>.cache_write` | number ≥ 0 |  | any |  | Dollars per million prompt tokens written to the cache. Unset: the input price. |
| `max_tokens` | integer ≥ 1 | `8192` | any; an organisation may enforce |  | The most output tokens one model call asks for. |
| `context_window` | integer ≥ 1 | `200000` | any | context window | The window, in tokens, assumed when neither a provider nor the catalog says; compaction is planned against it. |
| `compact_at` | number, 0 to 1 | `0.75` | any | compact at | The share of the window at which an agent summarises older turns. A tool result over 16 KiB it read before then is sent from then on as a stub `read_output` expands. |
| `llm_timeout_ms` | integer ≥ 1 | `300000` | any |  | How long one model call may take before it is given up on. |
| `identify` | boolean | `true` | user; project if trusted |  | Every model call names Troupe: a User-Agent with the version and the client, LiteLLM's tags and the session's id to a gateway, OpenRouter's app headers to OpenRouter; never a person, a path or a repository. `false` sends none of it. `troupe doctor` prints what goes out. |
| `thinking_binding` | `default` \| `drop_block` \| `error` | `default` | any |  | Anthropic only. `drop_block` sends the `thinking-binding-controls-2026-08-01` beta and asks the API to drop a thinking block whose conversation changed since it was made, instead of refusing the call: the fallback for an account that refuses one, on what a stable system prompt cannot keep the same (a compaction, an `AI?` turn's plan prompt, the task list's tools). `error` asks for the refusal an enforced account gets, on any account, so it can be measured; Troupe sends the call again without its thinking. |
| `system_prompt` | `stable` \| `per_turn` | `stable` | any |  | `stable` keeps the system prompt the same for the whole session, and sends the instruction files, the brief, the goal and the task list with the turn instead, each again only when it changed. `per_turn` puts them in the system prompt, rewritten as each turn begins. |

### Budget

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `max_turns` | integer ≥ 1 | `40` | any; an organisation may enforce | max turns | Model calls an agent may make before its budget stops it. |
| `max_input_tokens` | integer ≥ 1 | `2000000` | any |  | Input tokens an agent may spend. |
| `max_output_tokens` | integer ≥ 1 | `400000` | any |  | Output tokens an agent may spend. |
| `wall_clock_ms` | integer ≥ 1 | `1800000` | any; an organisation may enforce |  | How long an agent may run. |
| `max_depth` | integer ≥ 0 | `3` | any; an organisation may enforce | delegation depth | How deep agents may delegate; 1 means the root alone may. |
| `budget_warn_at` | number, 0 to 1 | `0.8` | any |  | The share of any limit at which the agent is warned. |
| `full_send` | boolean | `false` | any | full send | No budget warnings: an agent nearing a limit says nothing until the limit stops it. `troupe --full-send` sets it for one run. |
| `budget_asks` | boolean | `true` | any |  | A spent budget asks the person attached, rather than stopping. |

### Approvals

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `auto_approve` | boolean | `false` | user; project if trusted | auto approve | Run every tool call without asking. Off, a write, an edit or a shell command waits until a person allows it, once or for the rest of the session, or denies it. |
| `approvals` | `wait` \| `deny` | `wait` | user; project if trusted; an organisation may enforce |  | What a call that asks does with nobody attached: wait, or be denied. |
| `delegation` | settings |  | user; project if trusted |  | Delegating to subagents. |
| `delegation.ask` | list of strings |  | user; project if trusted |  | The subagents a `delegate` to asks you first, by name: you see the brief, the tools and the budget the child would get, and run it, edit the brief, send it to another agent, deny it with a word back, or let that agent run unasked for the session. `auto_approve` does not answer it. An agent's own definition asks too with `delegation: ask`. Unset: every delegation runs at once. |
| `managed_permission_rules_only` | boolean | `false` | user; project if trusted; an organisation may enforce |  | A session may not allow a tool for itself. |
| `managed_mcp_servers_only` | boolean | `false` | user; project if trusted; an organisation may enforce |  | A client may not offer a session its own tools. |
| `permissions` | settings |  | any; an organisation may add to |  | Per-tool rules: a tool, or a tool with a pattern in brackets: a command prefix for `shell`, a path glob for the file tools, `server.tool` for `mcp`. Every scope's rules are added together, not replaced, and of those that match a call `deny` beats `ask` beats `allow`; inside one file the more specific pattern decides. `troupe config --explain` lists them with where each came from. |
| `permissions.deny` | list of rules |  | any |  | Calls refused, with a sentence naming the rule: `shell(git push)`, `read_file(secrets/**)`. |
| `permissions.ask` | list of rules |  | any |  | Calls that ask a person first, even under `auto_approve` or an earlier "allow for the session". |
| `permissions.allow` | list of rules |  | user; project if trusted |  | Calls that run without asking. From a project's file only in a trusted workspace; with `managed_permission_rules_only` on, only the organisation's. |

### Tools

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `shell_timeout_ms` | integer ≥ 1 | `120000` | any | shell timeout (ms) | How long a shell command may run before it, and everything it started, is stopped. |
| `tool_output_limit` | integer ≥ 1 | `32768` | any | tool output limit | Bytes of a tool's output the model sees; the rest is kept, and read_output pages it back. |
| `scratch_max_bytes` | integer ≥ 1 | `262144` | any |  | Bytes one document `show` puts on the session's scratchpad may hold. |
| `scratch_max_documents` | integer ≥ 1 | `50` | any |  | Documents one session's scratchpad may hold. |
| `tool_failures_note_at` | integer ≥ 0 | `5` | any |  | Failures of one tool in a row after which the model is told to stop and reconsider; 0 never. |
| `tool_failures_stop_at` | integer ≥ 0 | `10` | any |  | Failures of one tool in a row that stop the turn and ask whether it goes on, budget or not; 0 never. |
| `read_roots` | list of strings |  | user; project if trusted |  | Directories outside the workspace the read tools may reach. |
| `mcp` | map of name to settings |  | user; project if trusted |  | The workspace's own MCP servers, by name. |
| `mcp.<name>.command` | string |  | user; project if trusted |  | A server on its standard streams: the program to run. |
| `mcp.<name>.args` | list of strings |  | user; project if trusted |  | Its arguments. |
| `mcp.<name>.env` | map of name to string |  | user; project if trusted |  | Variables to set for it. |
| `mcp.<name>.cd` | string |  | user; project if trusted |  | The directory to run it in. Unset: the workspace. |
| `mcp.<name>.url` | string |  | user; project if trusted |  | A server over HTTP: its URL. |
| `mcp.<name>.headers` | map of name to string |  | user; project if trusted |  | Headers sent with every request to a server over HTTP. `{env:VAR}` reads a value from the environment. |
| `mcp.<name>.oauth` | settings |  | user; project if trusted |  | A server over HTTP that wants you signed in: how to sign in. |
| `mcp.<name>.oauth.client_id` | string |  | user; project if trusted |  | A client registered in advance with the server's authorization server. |
| `mcp.<name>.oauth.scopes` | list of strings |  | user; project if trusted |  | The scopes to ask for. Unset: what the server says it wants. |
| `mcp.<name>.oauth.redirect_uri` | string |  | user; project if trusted |  | Where the browser comes back: `http://` on 127.0.0.1, [::1] or localhost. Unset: 127.0.0.1, any free port. |
| `mcp.<name>.oauth.resource` | boolean | `true` | user; project if trusted |  | Send the resource indicator; `false` for an authorization server that refuses it. |
| `mcp.<name>.oauth.issuer` | string |  | user; project if trusted |  | The authorization server, for a server that publishes no metadata naming one. |
| `mcp.<name>.permission` | `ask` \| `auto` | `ask` | user; project if trusted |  | `auto` runs its tools without asking. |
| `mcp.<name>.timeout_ms` | integer ≥ 1 | `30000` | user; project if trusted |  | How long one call may take. |

### Watching

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `watch` | boolean | `false` | user; project if trusted | watch mode | Act on `AI!` and `AI?` comments in the workspace's files. |
| `watch_debounce_ms` | integer ≥ 0 | `300` | any |  | How long watch mode waits for writes to settle. |
| `watch_poll_interval_ms` | integer ≥ 1 | `1000` | any |  | How often watch mode polls where it cannot be told. |
| `watch_auto_approve` | boolean | `false` | user; project if trusted | watch auto approve | A branch an `AI!` or `AI?` comment starts runs its writes, edits, shell commands and MCP servers' tools without asking. Off, each asks, whatever `auto_approve`, the agent's own permissions and a server's `permission` say. |
| `fs_events` | boolean | `false` | any |  | Record every file change in the workspace as an event. |
| `fs_debounce_ms` | integer ≥ 0 | `100` | any |  | How long file events wait for writes to settle. |

### Sessions

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `default_agent` | string | `build` | any |  | The agent a session starts with. |
| `resume_on_restart` | boolean | `false` | any |  | A session that comes back after a restart carries on by itself. |
| `loop_max_iterations` | integer ≥ 1 | `10` | any |  | Turns `/loop` runs when not told. |
| `loop_max_failures` | integer ≥ 1 | `3` | any |  | Failed turns in a row that stop a loop. |
| `memory` | boolean | `true` | any | project brief | The project brief: facts about the repository, kept in `.troupe/memory/facts.jsonl` and written with `remember`. Its commands and conventions are in every prompt, the rest comes through `recall`. `/memory` lists them. |
| `memory_auto_refresh` | boolean | `true` | any | refresh the brief | A new session in a git repository refreshes a missing or stale brief, but not within `memory_max_age_days` of a refresh that built nothing; never a headless run. |
| `memory_max_chars` | integer ≥ 1 | `6000` | any |  | How much of the brief goes into a prompt. |
| `memory_max_age_days` | integer ≥ 1 | `7` | any |  | How old the brief may be before it counts as stale. |
| `instructions_max_chars` | integer ≥ 1 | `16000` | any |  | How many characters of instruction files (`AGENTS.md`, `.agents/AGENTS.md` and `.troupe/rules`, every scope together) go into a prompt; the nearest are kept whole first. |

### This machine

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `trusted_workspaces` | list of strings |  | user file only |  | Workspaces whose own files may set the keys marked trusted. A path trusts everything under it. |
| `state_dir` | string |  | user; project if trusted |  | Where session logs go. Unset: the platform's state directory. |
| `fake_script` | string |  | user; project if trusted |  | With `provider: fake`, the file of scripted answers. |

### Clients

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `mouse` | boolean | `true` | any | mouse | The terminal UI captures the mouse: a click activates a window and the wheel scrolls. Off keeps the terminal's own click-and-drag selection; `troupe --no-mouse` turns it off for one run. |
| `ui` | settings |  | any |  | What follows a person from one client to the other. The daemon keeps it and acts on none of it. |
| `ui.theme` | string | `afterglow` | any | theme | The palette the desktop app and the terminal UI draw in: `afterglow`, `signal`, `footlight` or `limelight`. One a client does not know reads as `afterglow`. |
| `ui.blink` | boolean | `true` | any | blink | What waits on you blinks: the terminal UI's mark and border of a window that needs you. Off holds them lit. |
| `ui.mode` | `system` \| `light` \| `dark` | `system` | any | light or dark | Light or dark in the desktop app, or `system` to follow the computer. |
| `ui.notifications` | boolean | `true` | any | notifications | The desktop app says when a session nobody is reading finishes a turn or waits for you. |
| `transcript` | settings |  | any |  | How the clients draw a transcript. The daemon keeps it and acts on none of it. |
| `transcript.detail` | `quiet` \| `tools` \| `everything` | `quiet` | any | transcript detail | How much of a turn the clients draw open: `quiet`, its answer with its working one strip above it; `tools`, its tool calls open and its reasoning collapsed; `everything`, nothing collapsed. A failed call, an approval, a question and what follows a budget stop are open at every level. `/detail` changes it for one session. |
<!-- config-keys:end -->
