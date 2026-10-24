# Which file wins

The part of [configuration](configuration.md) that says whose word a setting is: what your
organisation suggests and what it holds you to, which keys wait until you trust a
workspace, every file Troupe reads, and the ladder that decides between two of them that
say different things. Every key is in [the reference](configuration.md#every-key).

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
| `permissions` | its [per-tool rules](configuration.md#per-tool-permission-rules) are added to yours, and none of yours loosens one of them |

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
[configuration page](../admin/client-config.md#defaults-and-limits-for-peoples-machines).

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
says, and `config.yaml`'s settings have the layers of [the files](configuration.md#the-files) above and
below them.
