# Agents, commands and workflows

An agent is what talks to the model; a command is a prompt you send often; a workflow is
the steps an orchestrating agent hands to subagents. Each is a file, yours in `<config>`
([where that is](configuration/files.md)) or a repository's in its `.troupe/`, and which
one wins where two share a name is [the ladder](configuration.md#which-one-wins).

## Agents

An agent is a Markdown file whose front matter says what it is and what it may do, and
whose body is its instruction; the [recipe](configuration/mcp-agents-skills.md#a-custom-agent)
is a complete one. The file name is the agent's name, and every `mode: primary` agent is a
command in the clients. One in `<workspace>/.troupe/agents/` or `<config>/agents/`
replaces an agent of that name lower on the ladder: a profile's bundle's, or a built-in:
`build`, `plan`, `orchestrate`, `ask`, `librarian`, watch mode's `quick` and `answer`, and
the subagents `general`, `explore`, `implementer` and `reviewer`.

- **`model:`** is `default`, `cheap`, `expensive` or a model named outright. `expensive`
  is `models.expensive`, else the default model, so an agent that asks for it still runs
  on a provider with no premium tier; set it in `config.yaml`, on the settings page, or
  with `TROUPE_EXPENSIVE_MODEL`. How hard a model thinks is the model's, not the agent's
  ([`reasoning_effort`](models.md#how-hard-a-model-thinks)).
- **`tools:`** names them from `read_file`, `write_file`, `edit_file`, `list_files`,
  `glob`, `grep`, `git_read`, `read_output`, `shell`, `web_fetch`, `todo_write`,
  `todo_read`, `delegate`, `read_branch`, `stop_child`, `remember`, `recall`, `show`,
  `patch`, `publish`, `import`, `onboard_write`, `ask_user` and `finish`; `tools: all` is
  all of them but `onboard_write`. With `tools: all` the task list's two are offered once
  a turn has made ten model calls, or while there is a list, so a small task spends no
  calls on one; a definition that names them, as `plan` and `orchestrate` do, has them on
  every call. `web_fetch` is a GET that returns a page as text, HTML reduced to readable
  text with its links kept, so an agent reads the documentation it is pointed at instead
  of guessing.
- **What asks.** `write_file`, `edit_file`, `shell`, `web_fetch`, `publish`, `import` and
  `onboard_write` ask before they run, and the rest run unattended; a `permissions:` block
  changes either. A repository's agent that sets a tool to `auto` waits until you trust the
  workspace ([trusted workspaces](configuration.md#trusted-workspaces)), and
  [per-tool rules](configuration.md#per-tool-permission-rules) answer across agents.

A client saves an agent through the daemon (`agents.put`), into `<config>/agents/` or the
repository's `.troupe/agents/`, and it is checked as it is saved: a key no agent has, a
missing `mode`, a tool that does not exist, a permission for a tool its `tools` leaves
out, or a model your provider does not serve is refused with the reason, and nothing is
written. A built-in is changed by saving a copy of it, under its name or another. A file
edited by hand that does not load is not read, and is listed with why in `agents.list` and
the session's log.

In the desktop app, **Agents** in the rail lists a workspace's agents with where each
comes from, its model, its tools, whether it can write and the windows running it; opens
one whole; and saves a new one, a copy (a built-in into the repository is one press) or an
edit into the layer you choose, with what the daemon finds shown at the field. Before a
save it names every `auto`, and asks once when the save lets a tool run unasked that did
not before: an `auto` in your own agents applies in every workspace, with no trust asked.
A profile bundle's agent is changed in the console. A session's head shows the agent it
runs and switches it from the next turn, the conversation kept, and the transcript records
the switch. The TUI's `/agents` page does the same
([the terminal client](../../clients/tui/README.md#agents)).

### Seeing a delegation before it runs

An agent hands work to a subagent with a brief, and by default the subagent starts at
once. To see the brief first for some agents, name them in `config.yaml`:

```yaml
delegation:
  ask: [general, implementer]
```

An agent's own definition can ask too, with `delegation: ask` in its front matter, which is
how a profile's bundle makes a pod's sessions ask; either is enough. Such a delegation
waits in the TUI's approval box or the desktop app's approval panel, showing the agent and
where its definition is, the brief's five parts, the tools and permissions the subagent
will hold, its share of the budget and how deep it is. You run it; edit the brief's parts;
send the same brief to another subagent; deny it, with a word back that the delegating
agent reads as the answer; or let that agent run unasked for the rest of the session.
`auto_approve` does not answer it: you asked to see these. With nobody attached,
`approvals: deny` denies it at once and `wait` keeps it waiting, as any approval.

## Workflows

`/workflow <task>` runs an orchestration rather than one agent doing everything, on
`orchestrate`, the one agent that orchestrates: `model: expensive`, and it cannot write a
file, edit a file or run a command. It decides: it writes the step list as its task list,
hands each step to the subagent that owns it, judges what comes back, and carries each
result into the next step's brief. The steps run in its own git worktree, which is
committed on `finish` and reviewed with `/merge` or `/discard`, as `/worktree` is. A
workflow is `orchestrate` with its plan written down in advance; `/orchestrate <prompt>`
is the same agent on your own words, with no step list.

Which to use: `build` for a change you would make yourself; `/workflow` when a repository
has written down the steps a change goes through and wants each owned by a subagent, with
a reviewer at the end; `orchestrate` for that shape on work nobody wrote steps for. On the
live bench's three small tasks (a test fixed, a function renamed across three files, three
steps from a file), five runs each on Claude Sonnet 5.5, both agents got every one done,
and `orchestrate` cost 2.5 to 3.1 times as much ($0.027 to $0.039 a run against $0.010 to
$0.013), made two to two and a half times the model calls and took 2.4 to 2.8 times as
long. `build` is the default for that reason, and `troupe bench --live --scenario
rename_symbol,rename_symbol_orchestrate` measures it on your own setup
([what a task costs](bench.md)).

The bundled pipeline is `understand` (`explore`), `plan` (the orchestrator itself),
`implement`, `test` and `document` (`implementer`), then `verify` (`reviewer`, which runs
the build, tests and lint, reads the diff and reports problems, and may not fix them).
Those subagents delegate further themselves, up to `max_depth`; the TUI's `/observer`
shows the whole tree.

A repository defines its own pipelines as `.troupe/workflows/<name>.json`, and `/workflow
<name> <task>` runs one:

```json
[
  {"name": "research", "agent": "explore", "prompt": "Find every call site of ..."},
  {"name": "decide", "prompt": "Pick the approach and write the todo list."},
  {"name": "port", "agent": "implementer", "prompt": "Apply the change ...", "parallel": true},
  {"name": "docs", "agent": "implementer", "prompt": "Update the guide ...", "parallel": true},
  {"name": "verify", "agent": "reviewer", "prompt": "mix test && mix credo --strict"}
]
```

`agent` is the subagent responsible for the step; without it the orchestrator does the
step itself. `parallel` marks steps that may be delegated in one turn, which runs them
concurrently: only for steps that write disjoint files. A file that is missing or does not
parse falls back to the bundled pipeline rather than failing the run.

## Your own commands

A prompt you type often can be a command of its own, a Markdown file in the shape other
tools' command files have:

```
<config>/commands/<name>.md             your commands, in every workspace
<workspace>/.troupe/commands/<name>.md  the repository's, for whoever opens it
```

The file name is the command, so `.troupe/commands/review.md` is `/review`; a name is
lower-case letters, digits and dashes. The body is the prompt the command sends, and
`$ARGUMENTS` in it stands for whatever is typed after the name. The front matter is
optional: `description` is what the palette shows (the prompt's first line without one),
and `argument-hint` what its usage line says follows the name.

```markdown
---
description: Review the change on this branch
argument-hint: <what to look at>
---
Review the change on this branch against main. Look hardest at $ARGUMENTS, and say what
you would change before changing anything.
```

`/review the parser` sends that prompt with `the parser` in place of `$ARGUMENTS`, as if
you had typed it; a prompt without the placeholder gets what you typed as a paragraph of
its own. In the TUI's command mode, with no window open, a command is work like any line
typed there: it starts a branch in your checkout on the agent its front matter's `agent`
names (`agent: plan`), or on the default agent, and the prompt goes to that branch. Both
clients' palettes list the commands in a Custom section, each with its description, the
file it came from and what it sends (the prompt's first lines, and how many more the file
holds), since a description is only what the file says of itself.

The repository's command wins over yours of the same name. A built-in's name, or an
agent's, stays theirs: a file named `merge.md` is skipped, and the daemon's log says so. A
repository's commands are read whether or not the workspace is trusted, since a command
only sends a prompt, which goes through the session's approvals like anything typed.

With `auto_approve` on, nothing asks before the tools a prompt leads to run, so a
repository's command asks once before it is first sent: the session shows the question
with the prompt under it, in either client, and you answer `deny` (nothing is sent, and
the next `/review` asks again), `once` (send it this time) or `allow` (send it, and do not
ask again in this workspace until the file changes). `allow` is kept in the daemon's state
directory (`command-trust.json`), never in the repository, beside a hash of the prompt, so
an edited command asks again and what you type after its name does not. Your own commands
never ask, and neither does a repository on `trusted_workspaces`, whose config could turn
`auto_approve` on by itself.
