---
number: 907
title: "Per-tool permission rules are `permissions.deny`, `ask` and `allow` in any config file, each a tool with an optional pattern; every scope's are kept together rather than replaced, the most specific inside one file and the strictest across files deciding a call; the harness refuses on a deny, asks on an ask whatever auto_approve or an allow for the session says, and runs an allow unasked unless a person must answer, the branch of a saved comment, or managed_permission_rules_only holds it; an untrusted project's allow is held; an organisation enforces rules as a fourth kind, `rules`, that adds rather than holds"
date: 2026-10-16
status: accepted
issue: 658
supersedes:
  - 869
paths:
  - apps/troupe_protocol/lib/troupe/protocol/permission_rule.ex
  - apps/troupe_core/lib/troupe/config/permissions.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/tools.ex
symbols:
  - Troupe.Protocol.PermissionRule.parse/1
  - Troupe.Config.Permissions.decide/4
  - Troupe.Tools.authorize/4
gist: "Every file's rules kept together: most specific in a file, strictest across; deny refuses, ask asks past auto_approve, allow unless held"
---

Issue #658's last part (slices 1 and 2 were Decisions 887 and 894): per-tool permission
rules as configuration, merged across the organisation, user, project and local scopes
with the strictest winning, applied by the harness and shown with where each came from.

## The shape

```yaml
permissions:
  deny: ["shell(git push)", "read_file(secrets/**)"]
  ask: ["mcp(github.create_*)"]
  allow: ["shell(mix test)", "write_file(lib/**)"]
```

Three lists of strings, one per action, rather than a list of `{tool, pattern, action}`
maps or a map of tool to pattern to action. A rule is a tool's name, alone or with a
pattern in brackets: the form Claude Code's settings use, so a rule copied from there reads
the same, and the strict reader says what to write where it does not (`Bash(npm test)` is
refused with "Troupe's is shell"). Three lists keep each rule one line and fit the schema's
existing types (`{:list, :rule}` under an object), so the JSON Schema, the generated
reference, `--explain` and `troupe config validate` cover them with no new machinery.

A pattern means what the tool's arguments allow (`Troupe.Protocol.PermissionRule`):

- `shell`: a command prefix, on word boundaries (`shell(git push)` matches `git push
  origin`, not `git pushx`); `git push *` the same; `git push*` the characters. `*` may
  only end it, and `:*`, Claude Code's prefix mark, is refused with what to write.
- the file tools (`read_file`, `write_file`, `edit_file`, `list_files`, `grep`, `glob`,
  `git_read`): a path glob against the call's `path` (the workspace where none is given),
  relative to the workspace unless written absolute or from `~`; `*` a name, `**` any
  directories, `?` a character, and a path with no wildcard that path and everything under
  it. `..` is resolved and `session:/` read as the workspace first, so neither walks around
  a rule; on Windows the comparison folds case, as the file system does.
- `mcp`: `server.tool` with `*`, or a server alone. It matches a person's client's own
  servers' tools (`client.<server>.<tool>`) as well as the workspace's and the pod's
  (`mcp.<server>.<tool>`): an organisation's `deny: [mcp(github.*)]` is meant for GitHub
  however it is reached.
- every other tool takes no pattern; one given is refused.

Rules live in `Troupe.Protocol`, not the core, because the plane checks an organisation's
rules when an administrator sets them and does not depend on the core (Decision 894's
reason for `ProviderTypes`). Matching is the core's (`Troupe.Config.Permissions`).

## Merging: kept together, not replaced

Every other key is RFC 7396-merged, a higher file's value replacing a lower one's.
Rules are not: a project's `deny` must not erase the user's, and "strictest wins" is
meaningless once one list has replaced another. `Troupe.Config.Layers` collects each file's
rules with its layer and path into `Layers.Result.rules` (the organisation's `defaults:`
as `org`, its `enforced:` as `enforced`, then `user`, `project`, `local`), beside the
merge; `Troupe.Config` puts those that apply on `config.permissions`.

**Strictest across files; most specific inside one.** For a call, each file gives at most
one verdict: of its rules that match, the most specific (a pattern over none, then the
longer pattern counting what it spells out rather than its wildcards), and of two as
specific the stricter. Across files the strictest verdict holds, `deny` over `ask` over
`allow`, whatever the files, and the rule named is the highest file's of that kind
(`enforced`, `org`, `user`, `project`, `local`). So `deny: [shell]` beside `allow:
["shell(git status)"]` in one file allows `git status` alone, which is the reason for
specificity inside a file, and no file loosens another's rule: an enforced `ask` beats a
person's `allow`. A file is the scope, not the layer: two organisation documents are two
scopes.

**A shell line is its commands.** Split at `&&`, `||`, `;`, `|`, `&` and new lines outside
quotes, leading `NAME=value` assignments dropped: a `deny` or `ask` holds when it matches
any command, so `ls && git push` is refused; an `allow` covers the line only when it
covers every command. A line that substitutes (`$(...)`, backticks, `<(...)`, a subshell)
is never covered by an `allow`, since what it runs is not readable in advance, and the
commands inside it are read too, so a `deny` reaches `echo $(git push)`. This is a reading
of the line, not a sandbox: `sh -c`, a script or an alias runs what no rule sees, and the
documentation says so. Not chosen: a shell parser, whose last mile (`eval`, functions,
`xargs`) is the same gap.

## Trust, and the switches

- **A project's `allow`** (`.troupe/config.yaml`, `config.local.yaml`) applies only in a
  trusted workspace and never on a pod, as every key that lets something run unasked
  (Decision 686, the gate-check's first row): a clone must not grant itself `shell`.
  Its `deny` and `ask` apply everywhere, since narrowing is what any file may do (as
  Decision 825 holds a workspace agent's `auto` and not its `ask`). The held rule is kept
  and marked with the same reason a gated key is (`ignored: a project's file sets it only
  in a trusted workspace ...`), so `--explain` shows it. The schema marks `permissions.allow`
  `trusted` for the reference; the hold is where rules are read, not the key's gate, which
  would drop the file's `deny` with it.
- **`managed_permission_rules_only`**, already a switch an organisation enforces ("a
  session may not allow a tool for itself"), now also holds every `allow` rule but the
  organisation's (`org`, `enforced`), with that reason. It is Claude Code's
  `allowManagedPermissionRulesOnly` narrowed to what loosens: a person's own `deny` and
  `ask` still apply.

## The harness

`Troupe.Tools.authorize/4` takes the call's arguments and refuses a call a `deny` matches,
for every tool, a `todo_write` or a `delegate` that runs inside the agent included, with
`Result.describe({:denied_by_rule, tool, rule})`: "This call to shell was refused by the
rule deny shell(git push), from what your organisation enforces (/etc/troupe/managed.yaml).
It did not run. ...". `run_task/4` then combines the rules with what was there:

- the agent definition's `deny` still denies (the tool is not the agent's at all);
- a rule's `deny` refuses with its sentence;
- a rule's `ask` asks as a must-answer call does (`always: true`, Decision 823): neither
  `auto_approve` nor an earlier `allow_session` answers it, so an organisation's `ask:
  [shell(git push)]` is not answered by "allow shell for the session" given to `ls`. The
  request carries the rule (`approval_requested`'s `rule`) for the clients to show;
- a must-answer call still asks whatever an `allow` says;
- a rule's `allow` runs the call unasked, over the tool's default `ask` and an agent's
  `ask`;
- with no rule, the call goes as before.

**`approvals: deny`.** An `allow` runs under it, as an agent's `auto` does: `approvals`
says what a call that asks does with nobody attached, and an allowed call does not ask.
An `ask` rule's call is refused there for want of anyone to ask, like every other asking
call. This is how an unattended session is given exactly the commands it may run.

**A branch a saved comment started** (`hold_auto`, Decision 844) holds every `allow`, as
it holds an agent's own `auto` and a server's `permission: auto`: any process that writes
a file can write a comment. `Troupe.Session.build_opts/1` drops them from that branch's
configuration.

**An `ask` or `allow` for a tool that runs inside the agent** (`todo_write`, `finish`,
`show`) does nothing, since those never ask; the reader warns so, and a name near a
built-in's that is none (`shel`) warns "did you mean shell?". Both are kept: a host may add
a tool of that name. A rule names no `{env:VAR}`: rules are written out.

## The organisation: a fourth kind, `rules`

Decision 869 allowed three kinds of enforced key, each a limit a value is held to. Rules
are not held to anything: they are added. `Troupe.Protocol.Organisation` lists
`permissions` with kind `:rules` and type `:rules`, after `managed_permission_rules_only`;
`check/1` checks each rule with `PermissionRule.check_set/1` and refuses with the rule's own
sentence; `exceeds?/3` is never true for it, so `Troupe.Config.Org.hold/2` holds nothing,
and the reader takes the enforced `permissions` out of the enforced set into the rules,
with the document's path or the plane's URL as their source. That is the part of 869 this
replaces: "only `:ceiling`, `:order` and `:fixed`" is now four kinds. Rules under an
organisation's `defaults:` are read the same way and hold the same, since no rule can be a
default a person replaces; the two differ in how `--explain` names them. On a plane,
`client_enforced` takes them as JSON (`admin.setting.put`), and the console's enforced-set
editor, which builds its fields from the plane's `enforceable` list, writes an object-typed
key as JSON text: a few lines in `Organisation.tsx`, the console's page.
