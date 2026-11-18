---
number: 869
title: "An organisation's document, from a plane's cached copy or a managed file at a fixed path, gives a machine defaults below the user file and an enforced set above the command line; only the keys the schema marks can be enforced, each a ceiling, and troupe config pull refreshes the cached copy rather than writing the user file"
date: 2026-10-11
status: accepted
issue: 122
paths:
  - apps/troupe_protocol/lib/troupe/protocol/organisation.ex
  - apps/troupe_core/lib/troupe/config/org.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
symbols:
  - Troupe.Protocol.Organisation
  - Troupe.Config.Org
  - Troupe.Config.Org.hold/2
  - Troupe.Config.Layers.organisation/1
gist: "Org defaults below user, enforced set above cli; only Organisation.keys() enforceable (ceiling/order/fixed); plane copy over managed file, stricter limit holds; pull refreshes the copy"
---

## The ladder

Lowest first: built-in defaults, **`org`** (the organisation's `defaults:`), `user`,
`project`, `local`, `env`, `cli`, **`enforced`** (the organisation's `enforced:`). A pod
(`trust: :never`) reads neither: its configuration is its profile's.

## One format, two places

```yaml
version: 1
defaults: { ... any key a user file takes, but trusted_workspaces ... }
enforced: { ... only the keys below ... }
```

`enforced:` takes a key only if the schema marks it; its value is type-checked the same
way and written out in full: `{env:VAR}` there refuses the load, because the person sets
their own environment. A key outside the two sections warns.

- **The managed file** is at a path fixed per system: `<system drive>\ProgramData\troupe\
  managed.yaml` on Windows, `/Library/Application Support/troupe/managed.yaml` on macOS,
  `/etc/troupe/managed.yaml` elsewhere. Windows's `%ProgramData%` is a variable a person
  can set for their own processes, so the drive is read from the registry's `SystemRoot`
  (`HKLM`, an administrator's), falling back to `C:`.

**No override in a release.** Neither path is moved by a variable or a flag. The
application environment (`:troupe_core, :organisation`) moves them only in a test run,
which is recognised as the `:mix` application started with its environment `test`: a
release carries no Mix, so `ERL_FLAGS`, which can set any application's environment, moves
nothing there either.

## Which source wins when both exist

The plane's, as recommended, for **defaults**: its `org` layer is read after the managed
file's, so it wins key by key and the file's other defaults stay. For **limits** the
choice is not the plane's alone: where both enforce a key, the stricter holds (the lower
ceiling, the tighter end of an order), and where both fix `provider` or `base_url`, the
managed file's holds and the plane's copy warns. Letting the plane's set replace the file's
would let a person on a managed machine lift the file's limits by signing in to any plane,
their own included; the managed file is the one a person cannot change, and the cache is
a file in their own state directory.

## The enforceable keys, and why each

`Troupe.Protocol.Organisation` holds the list, with what enforcing each means and its
type, in the protocol app because the plane (refusing an administrator's set) and the
machine (holding to it) must read it the same way, as Decision 868's `ClientUpdate` is.

| Key | Kind | Why it is on the list |
|---|---|---|
| `approvals` | order `wait` < `deny` | what an unattended call does is the organisation's risk; `deny` may not be loosened |
| `provider`, `base_url` | fixed | where requests and code go is the organisation's data boundary (a gateway that logs and bills) |
| `managed_mcp_servers_only`, `managed_permission_rules_only` | order off < on | the two switches the plane already sets for its pods' sessions (its *sessions* settings); the same word now reaches laptops |
| `max_tokens`, `max_turns`, `wall_clock_ms`, `max_depth` | ceiling | the budget ceilings: what one call, one agent's run and a delegation tree may cost |

A ceiling lets a lower layer be stricter: a lower `max_turns`, `deny` under an enforced
`wait`, a switch on under an enforced off. A fixed value has no stricter end. With
`provider` or `base_url` fixed, a named provider of another type or at another URL is
refused, as a provider whose key is unset is (a `:refusal` naming it): otherwise
`models.default: mine/x` would route around the fix. Nothing else is enforceable; in
particular not `auto_approve`, which the issue's prose mentioned and the maintainer's list
left out.

**Unmarked keys.** On the plane, `client_enforced` naming one is refused at the put with
`Organisation.refusal/1`'s sentence and nothing written. On the machine the key is not
enforced and warns with the same sentence: a newer plane that marks more keys must not
refuse every session of an older client, and the warning says what was skipped.

## Held, said once, shown

Every value a layer gave an enforced key that goes past the limit is marked on the ladder
as ignored ("held to 25 by your organisation (source)") and warned about once, naming that
file (or variable, or "command line"), the key and the organisation's value. A struct
default past the limit is held with no warning: nobody set it.

`config.set` of an enforced key is refused at every scope, whatever the value, with "set
by your organisation".

## Refresh, and `troupe config pull`

The daemon refreshes its copy after every `identity.link` that brings a plane token, once
the handshake has not refused this version (Decision 868), before erasures. A plane that
does not answer leaves the copy. A new copy that changes a key is announced as
`config.changed` with `scope: "org"`.

`troupe config pull` **refreshes the copy** instead of writing the user file, as
recommended: a copy in the user file outranks the organisation's defaults, is never
updated, and cannot carry the enforced set. It fetches `me.client_defaults` with the
terminal's own sign-in, as before, and hands the answer to the daemon's new
`config.organisation`, which keeps it through the same writer as the daemon's own refresh
(so there is no race with the token hand-over). It prints what the machine now takes and
names any key the person's own files set over the organisation's defaults (`shadowed`),
which is how a person who pulled into their file before learns to remove the copy. Not
chosen: the daemon fetching on `pull` itself, which needs the token handed over first and
would race the client's asynchronous hand-over.

## What this is not

The enforced set is the organisation's word honoured by Troupe, not a lock against a person
on a machine they administer: the plane's copy is a file in their own state directory, and
they choose the build they run. A managed file owned by an administrator on a machine its
person does not administer is the strong form. A copy signed by the plane, checked offline
with an expiry, is #66's channel document's job.
