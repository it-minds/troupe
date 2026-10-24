# Seeing and changing settings

The part of [configuration](configuration.md) about a file once it is written: what is
checked when it is read, the old spellings that still load, how to see what is in effect,
the settings pages of the desktop app and the terminal, and an editor's schema. Every key
is in [the reference](configuration.md#every-key).

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
file of its own: a setting is a key of [the files](configuration.md#the-files). The daemon serves both
(`config.get`, `config.set` and `config.changed` in the protocol), so a change made in one
shows in the other at once, and the next session either starts reads it.

- **What each shows.** Every key as a session in that workspace would read it: its value,
  and the layer and file that set it (the TUI shows the layer beside each value that is
  not a default; the desktop app does not show where a setting came from yet). Secrets
  are never shown. A key's name on the page is the `Shown as` column of
  [the reference](configuration.md#every-key), and its help the `What it does` there. The terminal leaves out `ui.mode` and
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
- **The provider.** Every place you pick one offers the same [provider types](configuration.md#provider-types),
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
