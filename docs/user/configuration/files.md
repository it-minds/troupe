# Where your files are

This is the one page that says where Troupe keeps each file. Every other page names a
file by what it is (`config.yaml`, `<config>/mcp.json`) and links here.

## Your own files: one directory

Everything you configure for yourself is in one directory, called `<config>` in these
pages:

| Platform | `<config>` |
|---|---|
| Linux, macOS | `$XDG_CONFIG_HOME/troupe`, or `~/.config/troupe` when that is not set |
| Windows | `%APPDATA%\troupe`, which is usually `C:\Users\<you>\AppData\Roaming\troupe` |
| anywhere | `$TROUPE_CONFIG_HOME`, when it is set, over both |

| File | What it is |
|---|---|
| `<config>/config.yaml` | your settings: providers, keys, models, budgets ([the key reference](../configuration.md#every-key)) |
| `<config>/mcp.json` | your MCP servers, on every workspace ([MCP servers](mcp-agents-skills.md#mcp-servers)) |
| `<config>/agents/<name>.md` | your own agents ([a custom agent](mcp-agents-skills.md#a-custom-agent)) |
| `<config>/skills/<name>/SKILL.md` | your own skills ([a skill](mcp-agents-skills.md#a-skill)) |
| `<config>/commands/<name>.md` | your own slash commands |
| `<config>/credentials.json` | the terminal client's sign-in to a plane, readable by you alone |
| `<config>/models.json` | the model list Troupe last read from your providers, refreshed when it is a day old |

`troupe config` prints the directory as `config dir:`, and the desktop app shows the
settings file's path under **This computer > Models**.

### On Windows, before 0.18

Builds before 0.18 documented, and older ones used, `%USERPROFILE%\.config\troupe` for
`credentials.json` and `mcp.json` while `config.yaml` was under `%APPDATA%\troupe`. Now all
of them are under `%APPDATA%\troupe`. A `credentials.json` or `mcp.json` that is only in
the old place is moved into the new one the first time Troupe needs it, and made readable
by you alone, so your sign-in and your servers keep working. When both places have one,
the one under `%APPDATA%` is read and the other is left as it is, for you to delete.
Nothing is moved when `TROUPE_CONFIG_HOME` is set: it named one directory for all of them
then too.

## A workspace's files

A repository keeps its own settings in `.troupe/` at its root:

| File | What it is |
|---|---|
| `<workspace>/.troupe/config.yaml` | what the repository wants, committed with it ([a team's project file](team-and-personal.md#a-teams-project-file)) |
| `<workspace>/.troupe/config.local.yaml` | one person's settings for one repository; add it to `.gitignore` ([a personal file](team-and-personal.md#a-personal-configlocalyaml)) |
| `<workspace>/.troupe/mcp.json` | the repository's MCP servers |
| `<workspace>/.troupe/agents/`, `skills/`, `commands/` | the repository's agents, skills and commands |

Which file wins when two set the same key is [the ladder](../configuration.md#the-files).

## What Troupe keeps for itself

The state directory holds what Troupe writes and you do not edit: session logs, the
daemon's address, what it remembers for you.

| Platform | The state directory |
|---|---|
| Linux, macOS | `$XDG_STATE_HOME/troupe`, or `~/.local/state/troupe` |
| Windows | `%LOCALAPPDATA%\troupe` |
| anywhere | `$TROUPE_STATE_HOME`, when it is set |

In it: `sessions/`, the logs (`troupe.log`, `daemon.log`), `organisation.json` (your
organisation's settings from its plane), `mcp-oauth.json` (your sign-ins to MCP servers),
`command-trust.json` (a repository's commands you allowed), `onboard.json` (your answers
about onboarding), `setup.json` (that the first run is done) and `identity.json`. On Windows the running
daemon's port and token are in `%LOCALAPPDATA%\troupe\daemon.json`, whatever
`TROUPE_STATE_HOME` says.

An organisation's managed file is outside both, where only an administrator writes:
`C:\ProgramData\troupe\managed.yaml` on Windows, `/Library/Application Support/troupe/managed.yaml`
on macOS, `/etc/troupe/managed.yaml` elsewhere.
