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

A session on your team's pod gets them from the desktop app. Open the session and it asks
whether to take your signed-in servers' tools, naming them; **Offer them** registers
each as `client.<server>.<tool>`, and a line at the top says what is offered. When the
agent calls one, the call comes back to the app and the daemon on this machine makes it
with your sign-in: the pod sees the arguments and the answer, never the sign-in, and
everyone in the session can see that it uses tools on your machine. A call goes through
the session's approvals like any other tool's. Closing the session, or the app, takes the tools away;
a connection that drops and comes back offers them again without asking twice. The TUI
does not offer them to a pod session yet.

## Your own commands

A prompt you type often can be a command of its own, written as a markdown file in the
shape other tools' command files have:

```
<config>/commands/<name>.md             your commands, in every workspace
<workspace>/.troupe/commands/<name>.md  the repository's, for whoever opens it
```

The file name is the command, so `.troupe/commands/review.md` is `/review`; a name is
lower-case letters, digits and dashes. The body is the prompt the command sends, and
`$ARGUMENTS` in it stands for whatever is typed after the name. The frontmatter is
optional: `description` is what the palette shows (the prompt's first line without
one), and `argument-hint` what its usage line says follows the name.

```markdown
---
description: Review the change on this branch
argument-hint: <what to look at>
---
Review the change on this branch against main. Look hardest at $ARGUMENTS, and say what
you would change before changing anything.
```

`/review the parser` sends that prompt with `the parser` in place of `$ARGUMENTS`, as if
you had typed it; a prompt without the placeholder gets what you typed as a paragraph
of its own. Both the terminal UI's and the desktop app's palettes list the commands in a
Custom section, each with its description and the file it came from. The repository's
command wins over yours of the same name. A built-in's name, or an agent's, stays
theirs: a file named `merge.md` is skipped, and the daemon's log says so. A repository's
commands are read whether or not the workspace is trusted, since a command only sends a
prompt, which goes through the session's approvals like anything typed.

## Instruction files

A repository that carries an `AGENTS.md` has told coding agents how to work in it, and
Troupe reads it the way the other tools do, with no setup of its own. Every agent's
system prompt opens with these, in this order, each read from disk as a turn begins, so
an edit takes effect on the next turn:

1. `<config>/AGENTS.md` — your own, for every repository.
2. `AGENTS.md` at the repository root (the nearest directory with a `.git`; a worktree
   reads its own checkout's).
3. `AGENTS.md` in each directory between the root and where the session works, parents
   before their children. Where the session works is the directory it was started in
   and the directory of every file its conversation has read, edited or written, so
   `frontend/AGENTS.md` applies from the turn after the agent first opened something
   under `frontend/`.
4. `.troupe/memory.md`, the project brief Troupe's own agents write.

Every file applies. A file in a directory below the root is about the work under that
directory, and where two disagree, the nearer wins. In one directory `AGENTS.md`,
`CLAUDE.md` and `GEMINI.md` are the same file under other tools' names, and at the
repository root so is `.github/copilot-instructions.md`: the first that exists is read
and the rest are skipped, and the session's log and `/context` say which and why, so
nobody debugs a file that was never loaded. So a repository with only a `CLAUDE.md`
works as it is. Copilot reads its file at the repository root and nowhere else, and so
does Troupe: a `.github/copilot-instructions.md` in a directory below the root is not
read, and is listed as skipped, saying so. A file that is a link to somewhere outside
the repository (outside `<config>`, for your own `AGENTS.md`) is not read; `context.get`
and the session's log list it as `outside`. The same goes for `.troupe/memory.md`, which
is then neither read nor written. Every file left out comes with a `reason`, in words,
which `/context` prints: `not read: outside the repository`, `skipped: AGENTS.md is used
in this directory`, `not read: Copilot's file counts only at the root`.

A file can pull in another with `@path/to/file.md` on a line of its own or in a
sentence, as Claude Code's do. The path is taken from the importing file's directory
(`~/` is your home), the imported file is read right after the one that names it, and
an import can import again, five deep. Each file is read once, so a cycle ends where it
comes back round. An `@` inside a code span or a fenced block is not an import. A
repository's files import only from inside the repository, and your own `AGENTS.md`
only from inside `<config>`; an import that is not followed (`missing`, `outside`,
`depth`, `cycle`) is named on the file that asked for it in `context.get` and the
session's log, and `/context` prints it after that file (`@docs/gone.md (root) import not
followed: missing`).

Cursor's rules are read as Cursor reads them. Each `.cursor/rules/*.mdc` at the
repository root, and in a directory on the way to where the session works, comes right
after that directory's own file, in name order, and its front matter says when it
applies: `alwaysApply: true` puts it in every prompt, and so does the legacy
`.cursorrules` at the root; `globs` (`src/**/*.ts, *.tsx`, or a list) put it in the
prompt from the turn after the agent first read, edited or wrote a file one of them
matches, for as long as the conversation holds that call; a rule with only a
`description` is listed in the prompt by it, and the agent reads the file when the
description fits the work; a rule with none of them is not used. A glob is taken from
the directory that holds `.cursor` (the repository root, for the root's rules), and one
without a `/` matches a file's name in any directory. `/context` says of each rule why it
applies (`always applied`, `applied: src/a.ts matches src/**/*.ts`) or why not (`applies
when a file matching src/**/*.ts is read or edited`, `requested by description only:
listed in the prompt, not joined`). Rules share the budget below and are held to the
repository's edge as every other file is; an `@` in a rule is not followed.

The files share one budget, `instructions_max_chars` (16,000 characters), a file and
what it imports counting as one scope. The nearest scope is kept whole first; a file the
remainder cannot hold is cut, or left out, and the prompt says so where it happened. The
brief has its own, `memory_max_chars`. `/context` in the terminal UI, and `context.get`
over the protocol, list every file in force with its scope, its size, what reached the
prompt and its share of the budget; the session's `instructions_loaded` event records
the same, what was cut included, whenever what was read changed.

`troupe instructions check [--workspace DIR] [--json]` checks those files, every one a
session in the workspace would read wherever it worked, nested ones and imports
included. It prints one line for each finding, with the file and the line:

```
frontend/AGENTS.md:3: contradiction: how to run the tests: `pnpm test` here, `npm test` in AGENTS.md:3
AGENTS.md:12: path: `docs/setup.md` does not exist
AGENTS.md:20: command: `mise` is not on the PATH (`mise exec -- mix test`)
frontend/AGENTS.md:9: duplicate: the same rule as AGENTS.md:5
```

- **contradiction**: two files, one of which applies inside the other, name different
  commands for the same job (test, build, lint, format, run) in the same ecosystem, and
  no command in common. A root's `mix test` and `frontend/`'s `pnpm test` are two parts
  of one repository, not a contradiction, and two sibling directories never are.
- **path**: a path in a code span or a link that is not there, from the file's own
  directory or from the repository root, and an `@` import that names no file. A span
  counts as a path when it starts with `./` or `../`, or has a slash and ends in one,
  names a file with an extension, or starts with a directory that is there; a bare file
  name, a branch like `origin/main` and a URL are not checked.
- **command**: a command in a code span, or in a fenced block marked as a shell (or with
  no language), whose program is not on the `PATH`. A span counts as a command when it
  starts with a known build tool (`npm`, `pnpm`, `mix`, `cargo`, `go`, `pytest`, `mise`,
  `make` and their like); the shell's own commands and the platform's package managers
  are not looked for.
- **duplicate**: a paragraph or list item said again in another file.

It would rather miss a finding than make a false one. It exits 0 when it finds nothing, 1
on a finding and 2 when it cannot read the workspace, so a repository can run it in CI on
its own instruction files; `--json` prints the same as one object, with `files` and
`findings`. Your own `<config>/AGENTS.md` is checked with the rest, except for paths,
which it names for every repository.

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
| `<config>/commands/*.md`, `<workspace>/.troupe/commands/*.md` | commands | the slash commands you and the repository define | one name, the workspace's; a built-in's or an agent's name is theirs |
| `<workspace>/.troupe/workflows/<name>.json` | workflows | the steps `workflows.list` offers | one name, one file |
| `<config>/AGENTS.md`, the repository root's `AGENTS.md`, one per directory down to the workspace and to each file the conversation worked on (aliases `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md` at the root only, first found wins), and the files each imports with `@path` | instructions | what the people who work here wrote for agents | all apply; the nearer wins where two disagree; the nearest kept whole when the budget runs out |
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

The terminal UI's settings page, the desktop app's settings and a budget raised
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

## Settings in the desktop app and the terminal

The desktop app and the terminal UI show and change the same settings, and there is no
settings file of their own: a setting is a key of the files above. The daemon serves
them both (`config.get`, `config.set` and `config.changed` in the protocol), so a change
made in one is there in the other at once, while its settings screen is open, and the
next session either of them starts reads it.

- **What each setting is.** Both read every key from the daemon as a session in that
  workspace would: its value, and the layer and file that set it. The terminal UI's
  `/settings` shows the layer beside each value that is not a default; secrets are never
  shown, in either.
- **Where a change goes.** Into one of the files above, named: the desktop app's model
  settings and its theme, light or dark and notifications go into your own
  `config.yaml`. The terminal UI's settings page writes the file the value on screen came
  from, and a default into your own file; its title says which, and `s` picks another.
  A key a file may not hold is refused rather than written where it would be ignored:
  `trusted_workspaces` outside your own file, and, in a workspace that is not trusted, a
  key marked trusted in its project or local file, such as `auto_approve`. The writer is
  the one every settings screen uses: the key's own line changes and the rest of the
  file stays.
- **One name and one help for each.** A key a settings page shows has a name for it, the
  `Shown as` column in the reference below, and its help is the `What it does` there. Both
  clients read them from the same table, so they cannot describe one setting two ways.
  The terminal leaves out the `ui` keys, which only the desktop app acts on.
- **What follows you, and what stays.** The `ui` keys are what should follow you from one
  client to another: the desktop app's theme (`ui.theme`), light or dark
  (`ui.mode`) and notifications (`ui.notifications`). The daemon keeps them and acts on
  none of them, as it does `mouse`. What belongs to one window — its size, which plane the
  desktop app last used, whether it opens on Home — stays in that window.
- **Edited by hand.** A file you edit yourself is read at the next session and the next
  time a settings screen asks; a screen already open does not hear of it.

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
the gateway says a call cost still wins, and then the catalog's price (the provider's
own list, which refreshes itself when it is a day old); a call none of the three prices
counts as free, and the daemon's log says so once a session. `troupe models` shows each
model's price and where it came from, or `no price`, and `troupe config --explain
models.prices` which file set it. The line under each turn in the terminal UI is priced the same way.
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

## What each provider caches

One thing you type can take an agent many model calls, and each call sends the whole
conversation again. A provider that caches the prompt bills what it has seen before at a
fraction of the input price, which on a long turn is most of what was sent. There is
nothing to set; what happens depends on the provider.

- **Anthropic** (`provider: anthropic`, or a provider of `type: anthropic`) caches only
  what a request asks it to, and every call an agent makes asks: the tool definitions,
  the system prompt and the conversation so far are marked, and the next call reads them
  back. The cache lasts five minutes from its last use, so the calls of a turn keep it
  warm and a reply after a long pause starts it again. A prompt shorter than the model's
  minimum (512 to 4096 tokens, by model) is not cached. A gateway that speaks Anthropic's
  API passes the marks on or drops them.
- **OpenAI** caches a long enough prompt by itself, with nothing to ask.
- **An OpenAI-compatible gateway or server** (`provider: openai` with a `base_url`, such as
  LiteLLM, vLLM or Ollama) caches whatever it and the model behind it do, which may be
  nothing. Troupe sends no marks this way; a LiteLLM deployment can be configured to add
  them for the Anthropic models it serves, and then reports what Anthropic wrote to the
  cache as well as what it read.

Whichever it is, the provider's own figures say whether it happened: each model call's
`cache_read` and `cache_write` in the session's log, and the terminal UI's token detail,
which says how much of the prompt came from the cache. A call priced from the catalog or
`models.prices` is priced at its `cache_read` and `cache_write` rates (a LiteLLM gateway's
catalog quotes both), or at the input price where those are not set.

The agent's task list ends the system prompt, as it stood when the turn began. A rewrite
within the turn reaches the model in the `todo_write` call's result and leaves the cached
prompt as it was, whatever the provider. A list the turn before changed is new at the
next turn's first call, which writes the conversation to the cache again; Anthropic still
reads the tools and the system prompt in front of the list.

## How hard a model thinks

`reasoning_effort` on a model's `models:` entry asks a model that reasons to think before
it answers: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or a number of
tokens. An OpenAI-compatible provider is sent the word as it is, and the model decides
what it means.

Anthropic's models take it in one of two forms, and refuse the other:

- **Claude Opus 4.7 and later, Sonnet 5 and later, Fable and Mythos** take adaptive
  thinking with an effort level, and refuse a budget. A word is the level of that name
  (`minimal` is `low`); a number is the level whose budget below would hold it, and
  more than 32768 is `max`.
- **The models before them** (Opus 4.6, Sonnet 4.6, Haiku 4.5 and older) are sent a
  thinking budget: 1024 tokens for `minimal`, 4096 for `low`, 8192 for `medium`, 16384
  for `high`, 32768 for `xhigh` and `max`, or the number given.

Which form a model takes is what Anthropic's model list says of it (`troupe models`
fetches it), else what its name says, found inside a gateway's renaming such as
`eu.anthropic.claude-opus-5`. A model neither describes is sent adaptive thinking for a
word and a budget for a number. Either way the output cap is raised to hold the thinking.
A model that refuses what it was sent fails the call with a message that names
`reasoning_effort` and what to set it to.

Claude Opus 5 and later, Sonnet 5 and later, Fable and Mythos think whether or not
`reasoning_effort` is set. With none (or `none`) they are sent no thinking settings and
think at their own default effort, and what they thought is handed back to them on the
next call, as it is when an effort is set, so a turn of tool calls goes on from the
reasoning it started with.

## What Troupe tells the provider

Every model call names the software that made it, so whoever runs the gateway can see
which of their spend is Troupe's, from which client and on which version:

- **Everywhere**, a User-Agent such as `troupe/0.8.4-beta (tui; windows/x86_64)`. The
  client is `tui`, `headless` (`troupe run --headless`), `desktop`, `acp` (an editor over
  ACP), `worker` (a session on a plane's pod) or `other`.
- **To a gateway** (a `base_url` that is neither Anthropic's nor OpenAI's own API, nor
  OpenRouter), LiteLLM's `x-litellm-tags` (`troupe`, `troupe-<client>`,
  `troupe-<version>`) and `x-litellm-spend-logs-metadata` with the session's id. An
  OpenAI-compatible request's `metadata` carries the session's id, the client and the
  version too. A server that is not LiteLLM ignores them.
- **To OpenRouter**, `HTTP-Referer` (the project's page) and `X-Title: Troupe`.

A session on your machine names nobody: no person, no path, no repository, no host name.
A session on a plane's pod also carries what the plane attributes it with (its owner, its
team, its worker profile and the agent), as it always has.

`identify: false` turns all of it off, and the User-Agent is the HTTP client's own.
`troupe doctor` prints, on its `identify` line, exactly the headers the default model's
provider is sent, or `off`.

## Every key

`Set by` says which files may set a key. "user; project if trusted" keys are read from a
workspace's files only once it is trusted; every key may also come from the environment
or the command line where one exists for it. `Shown as` is the name a settings page
shows a key by, in the desktop app and the terminal UI alike.

<!-- config-keys:begin -->
### File

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `version` | integer | `1` | any |  | The version of this format. A file without it is version 1. |
| `$schema` | string |  | any |  | Where an editor finds this schema. Troupe does not read it. |

### Model and provider

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `provider` | `anthropic` \| `openai` \| `fake` | `anthropic` | user; project if trusted |  | The session-wide provider's API. |
| `base_url` | string |  | user; project if trusted |  | The session-wide provider's URL. Unset: the vendor's own endpoint. |
| `api_key` | string |  | user; project if trusted |  | The session-wide provider's key. `{env:VAR}` reads it from the environment. |
| `auth` | `api_key` \| `bearer` | `api_key` | user; project if trusted |  | How the key is sent: the vendor's own header, or `Authorization: Bearer`. |
| `providers` | map of name to settings |  | user; project if trusted |  | Named providers. A model spelled `<provider>/<model>` goes to that provider. |
| `providers.<name>.type` | `openai` \| `anthropic` | `openai` | user; project if trusted |  | The API it speaks. A gateway such as LiteLLM or vLLM is `openai`. |
| `providers.<name>.base_url` | string |  | user; project if trusted |  | Where it is. Unset: the vendor's own endpoint. |
| `providers.<name>.api_key` | string |  | user; project if trusted |  | Its key. `{env:VAR}` reads it from the environment. |
| `providers.<name>.auth` | `api_key` \| `bearer` | `api_key` | user; project if trusted |  | How the key is sent: the vendor's own header, or `Authorization: Bearer`. |
| `providers.<name>.models` | map of name to settings |  | user; project if trusted |  | The models it serves, by the name Troupe addresses them with. |
| `providers.<name>.models.<model>.id` | string |  | user; project if trusted |  | The id that goes on the wire, when the gateway renamed the model. Unset: the name. |
| `providers.<name>.models.<model>.context` | integer ≥ 1 |  | user; project if trusted |  | The model's context window, in tokens. |
| `providers.<name>.models.<model>.max_output` | integer ≥ 1 |  | user; project if trusted |  | The most output tokens to ask for. |
| `providers.<name>.models.<model>.reasoning_effort` | string or integer |  | user; project if trusted |  | How hard the model should think: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or a thinking budget in tokens. An Anthropic model gets it in the form it takes. |
| `models` | settings |  | any |  | Which model each role uses. |
| `models.default` | string | `claude-sonnet-5` | any | model | The model every agent uses unless its definition names one. A bare id goes to the session-wide provider; `<provider>/<model>` goes to a named one, from `providers` or opencode. `troupe models` lists what this machine can address. |
| `models.cheap` | string |  | any | cheap model | The model for small jobs, compaction summaries among them. Unset: the default model. |
| `models.expensive` | string |  | any | expensive model | The model an agent asking for `expensive` gets. Unset: the default model. |
| `models.windows` | map of name to integer ≥ 1 |  | any |  | Context windows for bare model ids, in tokens. |
| `models.prices` | map of name to settings |  | any |  | Prices for models the provider's catalog does not price, by the name a model is addressed with. What a gateway says a call cost still wins, then the catalog's price. |
| `models.prices.<model>.input` | number ≥ 0 |  | any |  | Dollars per million input tokens. |
| `models.prices.<model>.output` | number ≥ 0 |  | any |  | Dollars per million output tokens. |
| `models.prices.<model>.cache_read` | number ≥ 0 |  | any |  | Dollars per million prompt tokens read from the cache. Unset: the input price. |
| `models.prices.<model>.cache_write` | number ≥ 0 |  | any |  | Dollars per million prompt tokens written to the cache. Unset: the input price. |
| `max_tokens` | integer ≥ 1 | `8192` | any |  | The most output tokens one model call asks for. |
| `context_window` | integer ≥ 1 | `200000` | any | context window | The window, in tokens, assumed when neither a provider nor the catalog says; compaction is planned against it. |
| `compact_at` | number, 0 to 1 | `0.75` | any | compact at | The share of the window at which an agent summarises older turns. A tool result over 16 KiB it read before then is sent from then on as a stub `read_output` expands. |
| `llm_timeout_ms` | integer ≥ 1 | `300000` | any |  | How long one model call may take before it is given up on. |
| `identify` | boolean | `true` | user; project if trusted |  | Every model call names Troupe: a User-Agent with the version and the client, LiteLLM's tags and the session's id to a gateway, OpenRouter's app headers to OpenRouter; never a person, a path or a repository. `false` sends none of it. `troupe doctor` prints what goes out. |

### Budget

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `max_turns` | integer ≥ 1 | `40` | any | max turns | Model calls an agent may make before its budget stops it. |
| `max_input_tokens` | integer ≥ 1 | `2000000` | any |  | Input tokens an agent may spend. |
| `max_output_tokens` | integer ≥ 1 | `400000` | any |  | Output tokens an agent may spend. |
| `wall_clock_ms` | integer ≥ 1 | `1800000` | any |  | How long an agent may run. |
| `max_depth` | integer ≥ 0 | `3` | any | delegation depth | How deep agents may delegate; 1 means the root alone may. |
| `budget_warn_at` | number, 0 to 1 | `0.8` | any |  | The share of any limit at which the agent is warned. |
| `full_send` | boolean | `false` | any | full send | No budget warnings: an agent nearing a limit says nothing until the limit stops it. `troupe --full-send` sets it for one run. |
| `budget_asks` | boolean | `true` | any |  | A spent budget asks the person attached, rather than stopping. |

### Approvals

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `auto_approve` | boolean | `false` | user; project if trusted | auto approve | Run every tool call without asking. Off, a write, an edit or a shell command waits until a person allows it, once or for the rest of the session, or denies it. |
| `approvals` | `wait` \| `deny` | `wait` | user; project if trusted |  | What a call that asks does with nobody attached: wait, or be denied. |
| `managed_permission_rules_only` | boolean | `false` | user; project if trusted |  | A session may not allow a tool for itself. |
| `managed_mcp_servers_only` | boolean | `false` | user; project if trusted |  | A client may not offer a session its own tools. |

### Tools

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `shell_timeout_ms` | integer ≥ 1 | `120000` | any | shell timeout (ms) | How long a shell command may run before it, and everything it started, is stopped. |
| `tool_output_limit` | integer ≥ 1 | `32768` | any | tool output limit | Bytes of a tool's output the model sees; the rest is kept, and read_output pages it back. |
| `tool_failures_note_at` | integer ≥ 0 | `5` | any |  | Failures of one tool in a row after which the model is told to stop and reconsider; 0 never. |
| `tool_failures_stop_at` | integer ≥ 0 | `10` | any |  | Failures of one tool in a row that stop the turn and ask whether it goes on, budget or not; 0 never. |
| `read_roots` | list of strings |  | user; project if trusted |  | Directories outside the workspace the read tools may reach. |
| `mcp` | map of name to settings |  | user; project if trusted |  | The workspace's own MCP servers, by name. |
| `mcp.<name>.command` | string |  | user; project if trusted |  | A server on its standard streams: the program to run. |
| `mcp.<name>.args` | list of strings |  | user; project if trusted |  | Its arguments. |
| `mcp.<name>.env` | map of name to string |  | user; project if trusted |  | Variables to set for it. |
| `mcp.<name>.cd` | string |  | user; project if trusted |  | The directory to run it in. Unset: the workspace. |
| `mcp.<name>.url` | string |  | user; project if trusted |  | A server over HTTP: its URL. |
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
| `watch` | boolean | `false` | any | watch mode | Act on `AI!` and `AI?` comments in the workspace's files. |
| `watch_debounce_ms` | integer ≥ 0 | `300` | any |  | How long watch mode waits for writes to settle. |
| `watch_poll_interval_ms` | integer ≥ 1 | `1000` | any |  | How often watch mode polls where it cannot be told. |
| `fs_events` | boolean | `false` | any |  | Record every file change in the workspace as an event. |
| `fs_debounce_ms` | integer ≥ 0 | `100` | any |  | How long file events wait for writes to settle. |

### Sessions

| Key | Type | Default | Set by | Shown as | What it does |
|---|---|---|---|---|---|
| `default_agent` | string | `build` | any |  | The agent a session starts with. |
| `resume_on_restart` | boolean | `false` | any |  | A session that comes back after a restart carries on by itself. |
| `loop_max_iterations` | integer ≥ 1 | `10` | any |  | Turns `/loop` runs when not told. |
| `loop_max_failures` | integer ≥ 1 | `3` | any |  | Failed turns in a row that stop a loop. |
| `memory` | boolean | `true` | any | project brief | Agents read the project brief, `.troupe/memory.md`, into every prompt and write it with `remember`. `/memory` shows it. |
| `memory_auto_refresh` | boolean | `true` | any | refresh the brief | A new session in a git repository refreshes a missing or stale brief, but not within `memory_max_age_days` of a refresh that built nothing; never a headless run. |
| `memory_max_chars` | integer ≥ 1 | `6000` | any |  | How much of the brief goes into a prompt. |
| `memory_max_age_days` | integer ≥ 1 | `7` | any |  | How old the brief may be before it counts as stale. |
| `instructions_max_chars` | integer ≥ 1 | `16000` | any |  | How many characters of instruction files (`AGENTS.md` and its aliases, every scope together) go into a prompt; the nearest are kept whole first. |

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
<!-- config-keys:end -->
