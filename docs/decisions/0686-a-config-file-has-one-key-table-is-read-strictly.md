---
number: 686
title: A config file has one key table, is read strictly, and says where each value came from; a workspace's own files set the keys that decide what may run only once the workspace is trusted
date: 2026-09-25
status: accepted
issue: 122
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/lib/troupe/config/settings.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - apps/troupe_core/lib/troupe/mcp/trust.ex
  - apps/troupe_core/lib/troupe/session.ex
gist: A config file has one key table, is read strictly, and says where each value came from
---

`Troupe.Config.Schema` is the table: every key's type, default, which files may set it,
whether it is a secret, and what it does. `Troupe.Config.Layers` reads and merges the
files against it, and `mix troupe.config.schema` writes `protocol/schema/config/v1.json`
and the key reference in `docs/user/configuration.md` from it, which CI checks with
`--check`.
- **Version.** `version: 1`; a file without it is version 1, and a higher one is
  refused as written for a newer Troupe.
- **Strict.** A file that is not YAML, a value of the wrong type, or an enum value nobody
  knows (`provider`, `auth`, `approvals`, a provider's `type`, an MCP server's
  `permission`) refuses the load, naming the file, the line, the key and what to write;
  `session.create` answers with that. Nothing loads as `%{}` and no enum falls back.
  `yes`/`no`/`on`/`off`, which YAML 1.2 reads as words, are read as the booleans they mean
  for a boolean key, with a warning, and the approval gate takes only `true` as on.
  Options a client or the command line passes are checked against the same table.
- **Unknown keys warn**, with the file, the line and the nearest key; `x-` keys pass and
  land in `extra`. `mouse` and `llm_timeout_ms` are keys of their own, and
  `llm_timeout_ms` is now the request's timeout.
- **One spelling.** `models.{default,cheap,expensive,windows}`, and `api_key` with `auth:
  bearer`. `model`, `small_model`, `expensive_model`, `windows`, `models.small` and
  `auth_token` load until version 2, each with a warning; both spellings of one setting in
  one file refuse it. Every writer — the daemon's `config.set` and `config.import`, the
  terminal UI's settings page, `troupe config migrate --write` — goes through
  `Troupe.Config.Migrate.write/2`, which writes the new spellings, `version: 1`, a
  `yaml-language-server` header naming the schema, and keeps the file it replaced as
  `.previous`. Loading never rewrites a file, since a rewrite drops comments. `troupe
  config trust` and `untrust` (#161) change one list and nothing else, so they edit the
  file's own lines instead (`Troupe.Config.Yaml.edit_list/4`), keep `.previous` all the
  same, and change nothing when the edit does not read back as that one change.
- **Maps merge by key** (RFC 7396): a map merges, `null` removes, a list replaces.
- **`{env:VAR}` that is not set** refuses the provider or MCP server that reads it, naming
  the variable, and anywhere else refuses the load. A refused provider's target carries
  `{:refused, why}` as its key, which both adapters answer with that error and no request.
  `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are used only with the vendor's own endpoint
  (`Troupe.LLM.Endpoint.vendor?/2`).
- **Scopes and trust.** A key is `:any`, `:trusted` or `:user`. The trusted keys change
  approvals (`auto_approve`, `approvals`, the two `managed_*`), endpoints and credentials
  (`provider`, `base_url`, `api_key`, `auth`, `providers`), commands to run (`mcp`), or
  readable paths (`read_roots`, `state_dir`, `fake_script`). A workspace's
  `.troupe/config.yaml` and `config.local.yaml` set them only when the workspace, or a
  directory above it, is on `trusted_workspaces` in the user file, the one `:user` key;
  otherwise they are ignored with a warning that names the command to trust it, `troupe
  config trust`. A git worktree of a trusted checkout is trusted when the checkout's
  `.git/worktrees/<name>/gitdir` names it back, and `troupe config trust` in a worktree
  writes the checkout, which trusts them all. A session on a pod (`kind: :team`) resolves
  with `trust: :never`.
- **Precedence** is unchanged, with `.troupe/config.local.yaml` between the project
  file and the environment.
- **Seeing it.** `troupe config --explain [KEY] [--json]` shows every value, secrets
  masked, with the layer and file that set it, and for one key its whole ladder,
  ignored entries and why included. `troupe config validate [PATH]` exits 1 on any
  error, refusal or warning. `troupe config migrate [--write] [PATH]` prints each
  file's rewrite. `troupe-daemon config` takes the same arguments.
- **Choices made here.** The trust list is a list of paths in the user file, a directory
  trusting what is under it, and not a per-workspace prompt, which #60 adds.
  `config.local.yaml` is gated like the project file: it lives in the workspace, and
  nothing but `.gitignore` keeps it out of a repository. The schema's `$id`, and the
  header writers add, is `https://troupe.dev/schema/config/v1.json`, the protocol schema's
  pattern; until it is served, an editor points at the file.
