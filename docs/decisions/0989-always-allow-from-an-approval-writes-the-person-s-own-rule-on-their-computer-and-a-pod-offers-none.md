---
number: 989
title: "Always allow from an approval is approval.respond's allow_always: a daemon writes the person's own allow rule for the whole tool into their config.yaml or the workspace's config.local.yaml and allows the call; refused under managed_permission_rules_only and where an allow would change nothing; a pod offers none, its rules being its worker profile's"
date: 2026-11-15
status: accepted
issue: 920
supersedes: [986]
paths:
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - apps/troupe_core/lib/troupe/config/settings.ex
  - apps/troupe_protocol/lib/troupe/protocol/relay.ex
  - clients/gui/apps/desktop/src/views/Approval.tsx
symbols:
  - Troupe.Config.Settings.allow_rule/3
  - Troupe.Session.Approvals.lasting/2
gist: "allow_always: daemon writes the person's allow rule for the tool, then allows; managed rules only, must-ask calls and pods refuse; capability approval_allow_always"
---

Issue #920's second part. The approval card offers Allow once, Always allow and Deny
(Decision 986). A lasting allowance is a per-tool rule (Decision 907), a line of a config
file; nothing let a client write one from the approval.

**A third decision, not a `rules.put`.** `approval.respond` with `decision: "allow_always"`
and `scope`. The rule and the answer are one act for the person, and one call keeps them
together: the rule is checked against the request it answers before anything is written,
and the call is answered only once the rule is there. A general rule writer the session's
scope could call would be a second way to edit configuration, and `config.set` already is
the one, taking `admin`.

**What is written.** The rule for the whole tool, as the button names it: `shell`,
`write_file`, and an MCP tool as `mcp(server.tool)` however it is reached (`mcp.` or
`client.`), which `PermissionRule.parse/1` checks. Not a pattern from the call's arguments:
"Always allow shell" is what the person pressed. Into `permissions.allow` of `everywhere`,
the user's `config.yaml` (the default, what the desktop sends), or `workspace`, the
workspace's `.troupe/config.local.yaml`, which is the person's own and not the repository's
`config.yaml`, so a rule of theirs is never committed for others. Through the writer every
settings screen uses (`Settings.allow_rule/3`, `Migrate.write`), announced as `config.changed`
so the Rules panel shows it at once with its file. A rule already there is not written twice.

**This session too.** A session reads its configuration once, as it starts (Decision 907's
rules are on `config.permissions`). So the tool is also let through for the rest of this
session as `allow_session` lets it; later sessions read the rule. `approval_decided` carries
`decision: "allow_always"` and `always: {rule, scope, path}`, with the person as actor: that
is the audit of the rule change, in the session's log beside the call it answered, and the
file keeps its `.previous`.

**Refused, with the request still waiting.**
- `managed_permission_rules_only`: `forbidden` with that `setting`. Under it a person's
  `allow` is held (Decision 907), so a rule written would be one that does nothing.
- A delegation or a publication: their answers are about one call's agent or audience.
- A call that must be asked, a rule's `ask` or a tool that always asks (Decision 823): the
  strictest rule holds, so an `allow` would not loosen it.
- `workspace` in an untrusted workspace, where a project's `allow` is held, with how to
  trust it or to allow it everywhere.
- Without `admin`, as `config.set` is: a collaborator's `control` does not write the
  person's file.

**On the platform.** The brief asked whether the plane could relay it as a rule on the
session's profile for that person. Its rules model does not have one: a pod's rules are its
worker profile's `spec.permissions` (Decision 913), a scope an administrator sets in the
console or a repository, the same for everyone the profile serves, and nothing in it is a
person's. A per-person rule on a profile would be a new layer in the activation, the CRD and
the console for every profile; the approval is not the place to invent it. So a pod does
not name `approval_allow_always`, and asked anyway answers `forbidden`, "rules on the
platform are the worker profile's, which an administrator sets; allow it once or for this
session". A laptop's session steered through the plane refuses it at the relay as it refuses
`allow_session` (`Troupe.Protocol.Relay`): the laptop's file is its person's at the laptop.

**The client.** The daemon names `approval_allow_always` at `initialize`; the desktop draws
Always allow where it is named and sends `scope: "everywhere"`. Where it is not, the button
is not drawn: this replaces Decision 986's void (disabled, "not yet"), since the answer is
now real where it can be and will not be on a pod, and DESIGN.md §8 removes what cannot be
done. The record says "Always allowed".

**What an older client sees.** A capability it does not know, and `approval_decided` with a
decision word it shows as an allow. An older daemon answers `allow_always` with
`invalid_params` naming `decision`, and names no capability, so no client offers it there.

## Proof

`allow_always_test.exs` (daemon, over its socket): the capability; `everywhere` writing
`permissions.allow: [write_file]` into the user's file, the decision carrying the rule and
the actor, the turn's second write running unasked, `config.changed` and `config.get`'s
rules listing it; an MCP tool kept as `mcp(github.create_issue)` from either prefix, once;
`managed_permission_rules_only` refused with nothing written and the call then allowed once;
`workspace` in an untrusted workspace refused; a scope that is neither. `relay_test.exs`:
refused over the relay. `harness_auth_test.exs` (a pod): no capability, and `forbidden` with
the profile's sentence. All failed on the chunk's tip, where `allow_always` was an unknown
decision. Desktop: `session-chat.test.tsx`, the button absent without the capability, sent
with its scope with it, and the rule written through the fake daemon and recorded.
