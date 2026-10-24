# The config.yaml a session reads

Part F of the [configuration reference](configuration.md): what an administrator needs
from the `config.yaml` files every session reads, and the defaults and limits an
organisation gives the machines of the people in it, from a plane or from a managed file.

Every session, on a pod or on a laptop, also reads settings from files and the `TROUPE_*`
variables, merged by key and checked against one key table. The layers and every key are
in [docs/user/configuration.md](../user/configuration.md); the schema is
`protocol/schema/config/v1.json`. What an administrator needs from them:

- **A pod's provider is its profile's.** The operator writes the provider, model and key
  into the pod as `TROUPE_*` ([configuration A.3](configuration.md#a3-worker-troupe_worker)). A session on a pod never takes the keys that change
  approvals, endpoints and credentials, commands to run or readable paths from the
  project's own file; the rest of that file (models, budgets, the project brief) applies.
- **A file Troupe refuses fails the session's start**, and says which file, which key and
  what to write: one that is not YAML, a value of the wrong type, an enum value nobody
  knows, both spellings of one setting, or a file written for a newer Troupe.
- **On a laptop**, a workspace's files set those keys only once the workspace is trusted
  ([trusted workspaces](../user/configuration.md#trusted-workspaces)). The organisation's
  defaults sit below the user's file and what it enforces above everything (next section).
- **A repository can check its own file** in CI: `troupe config validate
  .troupe/config.yaml` exits non-zero on any problem, an unknown key included.

## Defaults and limits for people's machines

An organisation can give the laptops of the people in it defaults, which a person's own
settings win over, and limits, which nothing on the machine goes past (Decision 869). Both
are in one document, a `defaults:` section and an `enforced:` section, and it reaches a
machine in one of two ways.

**From a plane.** The *client defaults* settings ([configuration Part C](configuration.md#part-c--platform-settings)) are the defaults: provider, URL,
how the key is sent, and the three models; never a key. `client_enforced` is the enforced
set, a JSON object such as `{"approvals": "deny", "max_turns": 100}`, set on the console's
**Organisation** screen or with `admin.setting.put`, audited like every setting. The plane answers both
in `me.client_defaults` (as `defaults` and `enforced`, beside the fields older clients
read). A signed-in machine's daemon fetches it whenever a client connects with a plane
token, keeps a copy in its state directory (`organisation.json`, with which plane and
when), and uses that copy as it is while the plane cannot be reached; `troupe config pull`
fetches it at once. The copy is the person's own file, so it is a default the person is
held to, not a lock against them: see below.

**From a managed file**, for an organisation without a plane: one file at a fixed path,
which no variable or flag moves.

| System | Path |
|---|---|
| Windows | `%ProgramData%\troupe\managed.yaml`, on the system drive (read from the registry, not from the variable) |
| macOS | `/Library/Application Support/troupe/managed.yaml` |
| Linux and others | `/etc/troupe/managed.yaml` |

Write it so only an administrator can change it. Its format:

```yaml
version: 1
defaults:
  provider: openai
  base_url: https://llm-gw.example.com/v1
  auth: bearer
  api_key: "{env:ORG_GATEWAY_KEY}"
  models:
    default: glm-5.2
    cheap: qwen3.6-35b
enforced:
  approvals: deny
  base_url: https://llm-gw.example.com/v1
  max_turns: 100
  wall_clock_ms: 3600000
  permissions:
    deny: ["shell(git push --force)", "read_file(~/.ssh/**)"]
    ask: ["mcp(tracker)"]
```

`defaults:` takes any key a user's `config.yaml` takes except `trusted_workspaces`, and is
checked the same way: a value of the wrong type refuses every session's start, naming the
file and the line, and an unknown key warns. `enforced:` takes only these, each a ceiling:

| Key | Enforced, a machine may |
|---|---|
| `max_tokens`, `max_turns`, `wall_clock_ms`, `max_depth` | set a lower number, not a higher one |
| `approvals` | tighten `wait` to `deny`, not loosen `deny` |
| `managed_mcp_servers_only`, `managed_permission_rules_only` | turn one on, not turn it off |
| `provider`, `base_url` | nothing else: the session's provider is this one, and a named provider of another type or at another URL is refused |
| `permissions` | add rules of its own, not loosen these: every file's per-tool rules are added together and the strictest that matches a call holds, so an enforced `ask` beats a person's `allow` ([per-tool rules](../user/configuration.md#per-tool-permission-rules)) |

A rule under `defaults:` is added and holds the same way, since no rule is a default a
person's file replaces; the two differ for rules only in how `--explain` names them (`org`
and `enforced`), and `managed_permission_rules_only` keeps both. On a plane,
`client_enforced` takes them as `{"permissions": {"deny": ["shell(git push --force)"]}}`,
each checked when set; the console's **Organisation** page edits them as rules (a tool and a
pattern, checked as typed) rather than JSON.

Any other key under `enforced:` is not enforced and warns, with the list; the plane refuses
it when it is set. An enforced value is written out in full: `{env:VAR}` is refused there,
since a person sets their own environment. `troupe config validate managed.yaml` checks a
draft before it is put in place.

**Both.** Where a machine has both, the plane's defaults win over the file's, the stricter
of two limits on one key holds, and a provider or URL both fix is the managed file's, with
a warning: the managed file is the one a person cannot change.

**What a person sees**, and what a ceiling bounds (the question a session asks at an
enforced `max_turns` or `wall_clock_ms`, and the room an enforced `max_tokens` leaves a
model's thinking), are on the user's page:
[your organisation's defaults and limits](../user/configuration.md#your-organisations-defaults-and-limits).

**What it is not.** It is the organisation's word honoured by Troupe on the machine, not a
control a person cannot get round on a machine they administer: the plane's copy is in
their own state directory, and they choose which build they run. A managed file an
administrator owns, on a machine its person does not administer, is the strong form.
