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
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/config/explain.ex
  - apps/troupe_core/lib/troupe/config/settings.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - clients/tui/lib/troupe/cli/model_config.ex
  - clients/tui/lib/troupe/settings.ex
  - docs/admin/configuration.md
  - docs/user/configuration.md
  - docs/admin/client-config.md
symbols:
  - Troupe.Protocol.Organisation
  - Troupe.Config.Org
  - Troupe.Config.Org.hold/2
  - Troupe.Config.Layers.organisation/1
gist: "Org defaults below user, enforced set above cli; only Organisation.keys() enforceable (ceiling/order/fixed); plane copy over managed file, stricter limit holds; pull refreshes the copy"
---

#122 slice 2. Slice 1 (Decision 686) made the ladder `default`, `user`, `project`, `local`,
`env`, `cli`, and the plane already answered `me.client_defaults`, which `troupe config
pull` copied into the user file once. There was no organisation layer and nothing a machine
was held to. The maintainer decided the shape on 2026-10-11 (#122's last comment): an
organisation enforces a fixed list of keys, each enforced value is a ceiling, defaults sit
below the user file and the enforced set above the command line, and the document comes
from a plane's cached copy or a managed file. This records how, and the choices the slice
left open.

## The ladder

Lowest first: built-in defaults, **`org`** (the organisation's `defaults:`), `user`,
`project`, `local`, `env`, `cli`, **`enforced`** (the organisation's `enforced:`).
`Troupe.Config.Layers.organisation/1` reads the two sources into `org` layers in front of
the user file's, merged by key as every file is; `Troupe.Config.Org.hold/2`, after the
command line's overrides in `Troupe.Config.resolve/3`, holds the struct to the enforced set.
A pod (`trust: :never`) reads neither: its configuration is its profile's.

## One format, two places

```yaml
version: 1
defaults: { ... any key a user file takes, but trusted_workspaces ... }
enforced: { ... only the keys below ... }
```

`defaults:` is checked by the loader's own walk, as the `:org` layer: types refuse the load
naming the file and the line (`defaults: max_tokens must be ...`), unknown keys warn,
`trusted_workspaces` is dropped with the `:user` scope's reason, and `{env:VAR}` reads the
environment, so a managed file can name a gateway key the machine has. `enforced:` takes a
key only if the schema marks it; its value is type-checked the same way and written out in
full: `{env:VAR}` there refuses the load, because the person sets their own environment. A
key outside the two sections warns.

- **The managed file** is at a path fixed per system: `<system drive>\ProgramData\troupe\
  managed.yaml` on Windows, `/Library/Application Support/troupe/managed.yaml` on macOS,
  `/etc/troupe/managed.yaml` elsewhere. Windows's `%ProgramData%` is a variable a person
  can set for their own processes, so the drive is read from the registry's `SystemRoot`
  (`HKLM`, an administrator's), falling back to `C:`. `troupe config validate PATH` checks a
  file named `managed.yaml` as an organisation's, so a draft is checked before it is placed.
- **The plane's document** is kept by the daemon as `<state>/organisation.json`
  (`version`, `plane_url`, `fetched_at`, `defaults`, `enforced`), written whole (a
  temporary file renamed over it), and only after the loader's check passes, so a document
  the loader would refuse leaves the copy before it in place. Offline it is used as it is.

**No override in a release.** Neither path is moved by a variable or a flag. The
application environment (`:troupe_core, :organisation`) moves them only in a test run,
which is recognised as the `:mix` application started with its environment `test`: a
release carries no Mix, so `ERL_FLAGS`, which can set any application's environment, moves
nothing there either. Started, not loaded: a bare `elixir` VM (the gateway's restart test's
daemon, or the installed TUI's modules loaded into a person's Elixir) can load Mix's modules
without its state, and `Mix.env/0` raises there. Every suite's helper points both at scratch
paths, so no test reads this machine's.

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
`Troupe.Config.Schema` marks the same keys (`enforce: :ceiling | :order | :fixed`), the
generated reference says "an organisation may enforce" beside them, and a test holds the
two lists, kinds and types together.

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
default past the limit is held with no warning: nobody set it. The enforced value goes on
the ladder last, in effect where it held something and shown as the limit where the value
in effect is within it. `troupe config --explain` names `org` and `enforced` with their
source, the plane's URL or the file's path (`Troupe.Paths.display/1` leaves a URL alone),
and the plane's document's header line says when it was fetched and where it is kept;
`--json` adds `enforced` to each key and `limit` to the enforced entry.

`config.get`'s keys carry `layer` `org`/`enforced`, their source, and `enforced: {value,
source}`; an enforced key has no `scopes`. Where the organisation's layer is read from is
`organisation`, beside `files`, which stays each writable scope's file so older clients
read it as before. `config.set` of an enforced key is refused at every scope, whatever the
value, with "set by your organisation". The terminal UI's settings page shows such a key
as "set by your organisation", says where from, and neither edits it nor moves its scope
(TUI side of this decision; no TUI decision of its own, since it follows `config.get`). The
desktop app shows no setting's source today, so nothing changes there: a follow-up.

## The plane: `me.client_defaults` grows, no new method

`me.client_defaults` answers `defaults` (the *client defaults* settings in a config file's
shape, only what is set) and `enforced` (the new `client_enforced` setting, `{}` unset)
beside its old fields, which stay as they were for older clients. One method because it
already is "what an administrator says people's own machines should do", anybody signed in
may read it and nothing in it is a secret; a second method would be a second round trip
for every refresh and a second thing for the console to describe. A machine reading an
answer without `defaults` (a plane from before this) takes the old fields as the defaults.

`client_enforced` is a setting of the *client defaults* group, type `:enforced`: a JSON
object, parsed and checked by `Organisation.check/1` at the put, stored as its JSON, shown
as its JSON. So an administrator sets it through the existing settings path
(`admin.setting.put`, the console's Policy page, `reset`), audited as `setting.put` with the
diff, a key at a time once there is a value. The Policy page shows it as that panel's
field, as the version policy's panel is beside it (#605); the real screen is #56's.

## Refresh, and `troupe config pull`

The daemon refreshes its copy after every `identity.link` that brings a plane token, once
the handshake has not refused this version (Decision 868), before erasures. A client links
on every new connection and at every renewal, so this is at sign-in and at the first
connection after a daemon restart, which has no token until then (Decision 764); "on daemon
start" is that. A plane that does not answer leaves the copy. A new copy that changes a key
is announced as `config.changed` with `scope: "org"`.

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

## Not in this slice

The budget question could still raise `max_turns` or the wall clock past an enforced ceiling
for one run or session (Decision 699's `cap` was the pod's terms alone). Issue #622 made the
enforced ceilings that cap too, the lower of the two holding, with words that name the
organisation and where its limit came from; held `allow` to them as well, which raises
every limit at once; and found a model entry's `max_output` lowering an enforced
`max_tokens`, never raising it. Still follow-ups: a JSON Schema for the managed file, a
desktop settings view that shows where a value came from, defaults beyond the six client
defaults on the plane, and the model panel's
`config.set` (with `provider`), which still writes `provider`/`base_url` into the user file
under a fixed provider (held on load, with the warning).

## Proof

- `apps/troupe_core/test/troupe/config/org_test.exs`: the reproduction (a managed file's
  default reaching `Config.load`, and `max_turns: 500` on the command line held to an
  enforced 50; both failed on the chunk tip); the user file over the managed file; the
  plane's copy naming the plane, recording when, used offline, over the managed file; an
  old plane's answer; a refused document not saved; `trusted_workspaces` dropped; a pod
  reading neither; type, version and YAML refusals with the file, the line and the section;
  unknown and out-of-section keys; `{env:}` in `enforced` refused; `validate managed.yaml`;
  ceilings, the default held silently, `approvals` from a project file and the command line
  each warned once, the switches, a fixed provider and URL refusing a named provider
  elsewhere, an unmarked key not enforced; both sources (stricter ceiling, the file's URL,
  the warning); `--explain` text and JSON; `config.get` and `config.set`; the fixed paths;
  the schema's marks against the protocol's list.
- `apps/troupe_protocol/test/troupe/protocol/organisation_test.exs`: the list, `check/1`'s
  refusals, and each kind's ceiling.
- `apps/troupe_gateway/test/troupe/gateway/organisation_test.exs`: a link with a token
  fetching, keeping and announcing the document, `config.get` showing it and `config.set`
  refusing; a plane that does not answer leaving the copy; `config.organisation` keeping,
  naming `shadowed`, not announcing an unchanged copy, refusing a bad one.
- `apps/troupe_gateway/test/troupe/gateway/restart_test.exs`, unchanged, whose daemon is a
  bare `elixir` VM: it failed every session's start while the guard asked a loaded but
  unstarted Mix for its environment.
- `apps/troupe_plane/test/troupe/plane/client_defaults_test.exs` and the Policy page's test
  in `panel_test.exs`: the old fields unchanged, `defaults` and `enforced` added, the set
  put, audited, refused with the reason for an unmarked key or a bad value.
- `clients/tui/test/troupe/org_settings_test.exs` and `model_config_test.exs`: the page
  showing an enforced key and an organisation's default and not editing the first, and
  `troupe config pull` through the embedded daemon.
