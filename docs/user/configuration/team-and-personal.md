# Recipes: a team's file and your own

A repository can carry the settings its team agrees on, and each person can add their
own for that repository without committing them. Both are loaded by a test, together,
in a workspace the user file trusts. Where each file goes is on
[Where your files are](files.md).

## A team's project file

Committed at the repository's root, as `.troupe/config.yaml`. Some keys decide where
requests go, with which key, and what runs without asking; those are read from a
repository's file only once you trust the workspace (`troupe config trust`, in it), and
until then are ignored with a warning that says so ([trusted
workspaces](../configuration-layers.md#trusted-workspaces)). The rest applies at once.

<!-- recipe: team -->
```yaml title=".troupe/config.yaml"
version: 1
# The team's gateway. A named provider is read once you trust this workspace; each
# person brings their own key in config.local.yaml, so none is committed here.
providers:
  team:
    type: openai
    base_url: https://llm-gw.example.com/v1
models:
  default: team/glm-5.2
  cheap: team/qwen3.6-35b
# What a session here may spend. These apply in any workspace, trusted or not.
max_turns: 60
wall_clock_ms: 3600000
context_window: 128000
# Notes for people and other tools: keys that start with x- are left alone.
x-owner: platform-team@example.com
```

## A personal config.local.yaml

Beside it, as `.troupe/config.local.yaml`, and in `.gitignore`. It wins over the team's
file, and maps merge key by key, so this adds a key to the team's provider and keeps the
rest of it.

<!-- recipe: personal -->
```yaml title=".troupe/config.local.yaml"
version: 1
# My key for the team's gateway, from my own environment.
providers:
  team:
    api_key: "{env:MY_GATEWAY_KEY}"
  # The small jobs on my own machine, through Ollama, which takes no key.
  local:
    type: ollama
models:
  cheap: local/qwen3:8b
```
