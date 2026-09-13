# Conventions

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

Only what is enforced by a tool or visible in the code and history. Where a convention
is stated but not enforced, this says so.

## 1. The gate

`mix check` (`mix.exs:32-42`) runs, in order:

| Step | Enforces | Where configured |
|---|---|---|
| `compile --force --warnings-as-errors` | no compiler warnings, in the test environment (`mix.exs:18-21`) | — |
| `format --check-formatted` | formatting of the files the root `.formatter.exs` names | `.formatter.exs` |
| `credo --strict` | the checks enabled in `.credo.exs`, including low-priority ones | `.credo.exs` |
| `troupe.boundaries` | the app and module rules in [architecture.md](architecture.md) §2 | `apps/troupe_core/lib/mix/tasks/troupe.boundaries.ex:29-51` |
| `test` | the suite; CI runs it ten times (`.github/workflows/ci.yml:87-90`) | — |

CI's `check` job runs the same five commands as separate steps (`ci.yml:71-90`).

## 2. Boundaries

The rules and their reasons are quoted in [architecture.md](architecture.md) §2. In
practice, when adding code:

- A client app (`troupe_tui`, `troupe_ctl`, `troupe_a2a`) may call `Troupe.Protocol.*`,
  `Troupe.KMS.*`, `Troupe.ObjectStore`, `Troupe.MCP.*`, `Troupe.Policy`,
  `Troupe.WorkerProfile` and `Troupe.Sessions.Storage` — whatever lives under
  `apps/troupe_protocol/lib` — and nothing from the other apps. Needing a server module
  means the protocol is missing a method, not that the boundary is wrong
  (`troupe.boundaries.ex:4-14`).
- A `Troupe.Plane.Web.Live.*` module may call `Troupe.Plane.Admin` and other LiveViews,
  and no other `Troupe.Plane.*` module (`:41-51`).
- Every cross-app call must appear as `{:troupe_x, in_umbrella: true}` in the caller's
  `mix.exs`, or the task reports "not declared in mix.exs" (`:128-139`).
- A test-only dependency in the reverse direction is allowed and used three times
  (`apps/troupe_tui/mix.exs:34`, `apps/troupe_ctl/mix.exs:39`, `apps/troupe_plane/mix.exs:65`,
  `apps/troupe_worker/mix.exs:38`); each carries a comment saying why and that the task
  would still catch a call from `lib/`.

## 3. Formatting, and its blind spot

`.formatter.exs:3` at the umbrella root lists `inputs: ["{mix,.formatter}.exs",
"{config,lib,test}/**/*.{ex,exs}"]`. Those globs are relative to the root, where there is
no `lib/` and `test/` holds only fixtures. There is no `apps/*/.formatter.exs`
(`ls apps/*/.formatter.exs` finds none) and no `subdirectories:` entry, so
`mix format --check-formatted` inspects `mix.exs`, `.formatter.exs` and
`config/*.exs` and never opens a file under `apps/`. Discrepancy: `mix check` and
`README.md:220` present `format` as covering the code; it does not. Credo does include
`apps/*/lib/` and `apps/*/test/` (`.credo.exs:24-33`), and several of its enabled
checks — `SpaceAroundOperators`, `TabsOrSpaces`, `TrailingWhiteSpace`,
`RedundantBlankLines`, `MaxLineLength` at 120 (`.credo.exs:72-117`) — cover part of
what the formatter would. Run `mix format` in an app directory by hand before committing;
nothing will tell you if you do not. Adding `subdirectories: ["apps/*"]` to the root file
and a `.formatter.exs` per app is the usual fix and is not in the repository.

Line endings: there is no `.gitattributes`. `Credo.Check.Consistency.LineEndings` is
enabled (`.credo.exs:73`), so each file must be internally consistent. On the Windows
machine this audit ran from, `core.autocrlf=true` is set locally; that is not a
repository convention.

## 4. Credo

`.credo.exs` has `strict: false` (`:49`) but the gate passes `--strict`, which promotes
low-priority checks to failures. Notable enabled checks:

| Check | Effect | Line |
|---|---|---|
| `Design.TagTODO` with `exit_status: 2` | a `TODO` comment fails the gate | `:92` |
| `Design.TagFIXME` | so does `FIXME` | `:87` |
| `Readability.ModuleDoc` | every module has a `@moduledoc` — which is why every module in the tree opens with a paragraph of reasons | `:102` |
| `Readability.MaxLineLength` 120 | | `:100` |
| `Warning.WrongTestFilename` | test files end in `_test.exs` | `:164` |
| `Warning.IoInspect`, `Warning.Dbg`, `Warning.IExPry` | none left in | `:144-147` |
| `Refactor.Apply` | `apply/3` is flagged; the one deliberate use is marked `credo:disable-for-next-line` with the reason (`apps/troupe_core/lib/troupe/release.ex:21-25`) | `:122` |
| `Warning.UnsafeToAtom` | disabled — and `String.to_atom/1` on a provider name is in the audit's caveats ([../AUDIT.md](../AUDIT.md) §3.18) | `:209` |

## 5. Rules the code states and tests check

| Rule | Stated | Checked by |
|---|---|---|
| `Session.Log` is the sole publisher of durable events; the agent publishes ephemerals only | `apps/troupe_core/lib/troupe/session/log.ex:2-17`; `ARCHITECTURE.md:157-161`; `DECISIONS.md` #7 | structure: `Troupe.Events` is internal to core (`events.ex:2-9`) |
| Ephemerals are never persisted and may be dropped | `apps/troupe_protocol/lib/troupe/protocol/event.ex:5-11` | `apps/troupe_gateway/test/troupe/gateway/backpressure_test.exs` |
| The response is an acknowledgement, never the effect | `apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:7-10`; `apps/troupe_a2a/lib/troupe/a2a/tasks.ex:217` | conformance client checks `input.send` returns `accepted` (`clients/python/conformance.py:56-60`) |
| Every state-changing command carries a `command_id`; replay is a no-op returning the first acknowledgement | `dispatch.ex:12-14`; `apps/troupe_gateway/lib/troupe/gateway/commands.ex:1-31` | `apps/troupe_gateway/test/troupe/gateway/commands_test.exs` |
| Schema changes are add-only within version 1 | `apps/troupe_protocol/lib/troupe/protocol/schema.ex:9-12` | `mix troupe.schema.diff` in CI (`ci.yml:229-230`) |
| An upcaster may add and rename, never drop; `1 -> 2 -> 3`, never `1 -> 3` | `apps/troupe_core/lib/troupe/log/upcast.ex:4-14` | `apps/troupe_core/test/troupe/log/fold_test.exs` against recorded fixtures |
| A recorded fixture hash is evidence, not a test to update | `apps/troupe_core/lib/mix/tasks/troupe.fixtures.record.ex:13-17` | the task refuses to overwrite (`:30-37`) |
| Four renderings of one admin context | `apps/troupe_plane/lib/troupe/plane/admin/api.ex:1-10` | `apps/troupe_plane/test/troupe/plane/admin_parity_test.exs` |
| No admin function returns session content | `apps/troupe_plane/lib/troupe/plane/admin.ex:20-24` | `admin_parity_test.exs:147-150` |
| Troupe creates no Kubernetes secrets | `charts/troupe/values.yaml:11-15`; `scripts/remote-up:196-199` | by absence: `grep -n "kind: Secret" charts/troupe/templates/*.yaml` matches nothing |
| A UI can never apply backpressure to an agent | `apps/troupe_core/lib/troupe/application.ex:8-11`; `events.ex:9-11` | `backpressure_test.exs` asserts turn latency with a stalled socket (`ARCHITECTURE.md:182-186`) |

## 6. Comments, decisions, reports

Three habits are visible everywhere and stated in the prose:

- **Comments say why.** Every module opens with a `@moduledoc` that argues for the
  design rather than restating the code (Credo enforces the presence, not the content).
  Inline comments follow the same shape; see `config/runtime.exs:139-142,171-175,279-292`
  or `charts/troupe/templates/plane-deployment.yaml:177-194` for the register.
- **`DECISIONS.md` records every deviation from `spec.md` and every ambiguity
  resolved, numbered, newest at the bottom** (`DECISIONS.md:1-4`). Entries are a bold
  one-sentence decision followed by the reasoning. When a change departs from the spec
  or from an earlier decision, it gets a number.
- **`REPORT.md` proves done items**: per stage, the criteria, the command that
  demonstrates each and its output (`REPORT.md:1-30`). Numbers in it are from real
  runs and are dated by stage rather than by calendar.

The prose documents drift; [../AUDIT.md](../AUDIT.md) §2 lists 35 places where
`README.md`, `ARCHITECTURE.md`, `PROTOCOL.md`, `DECISIONS.md` or a moduledoc disagrees
with the code. When you change behaviour, the moduledoc is the one that must move with
it.

## 7. Commit messages

From `git log` on `main`: one short imperative or declarative sentence in the project's
voice as the subject, then a body of a few paragraphs saying what was wrong, what changed
and why. Recent subjects:

- `Say how an MCP client reaches a plane, and what the provider has to allow` (3f7c91f)
- `A remote MCP client can authenticate to the plane on its own` (e74e3b5)
- `An enum setting's choices are atoms in the registry, not atoms made from input` (9a200cf)

Others in the same voice: `Deploying it on a real cluster, and the bugs only a cluster
finds` (9ae7d3c), `Stage 6: what a session cost, as a fold over its own log` (79d4937),
`PlaneDownTest: poll for the queued report` (0491277). No conventional-commits prefixes,
no ticket numbers, no trailers in the history examined. Nothing in the repository
enforces any of this.

## 8. Naming

| Thing | Pattern | Source |
|---|---|---|
| Worker namespace and workload | `<namespacePrefix><profile>`, default prefix `troupe-w-` | `apps/troupe_operator/lib/troupe/operator/names.ex:11-17`; prefix from `TroupePolicy.spec.namespacePrefix` (`charts/troupe/values.yaml:248`) |
| Pod | `troupe-w-<profile>-<ordinal>` (StatefulSet naming) | `names.ex:23-25` |
| Per-pod Service and Ingress | `<profile>-<ordinal>` | `names.ex:27-29` |
| Pod hostname | `<ordinal>-<profile>.<workersDomain>` — one DNS label, hyphenated, so one wildcard covers every profile | `names.ex:31-50`; `config/runtime.exs:50-64` |
| Client endpoint | `<scheme>://<ordinal>-<profile>.<domain>[:port]/v1/socket` | `config/runtime.exs:59-64` |
| Session id | `YYYYMMDDTHHMMSS-<4 random bytes, url-safe base64>` | `apps/troupe_core/lib/troupe/session.ex:188-197` |
| Service principal subject | `svc:<team>/<name>` | [../AUDIT.md](../AUDIT.md) §1 (plane note) |
| Images | `troupe-operator`, `troupe-plane`, `troupe-worker`, `troupe-a2a` (release name with `_` as `-`) | `scripts/build-images:26`; `ci.yml:163` |
| Burrito artefacts | `troupe-<version>-<target>[.exe]` | `scripts/build-local:90`; `ci.yml:310` |
| Team and org PVCs | `team-<team>`, `org`; the pod's own volume `data` | `names.ex:62-72` |
| Labels | `app.kubernetes.io/{name,instance,managed-by}`, `troupe.dev/profile`, `troupe.dev/managed=operator` for what the operator wrote and pruning selects | `names.ex:79-110` |
| Test files and modules | `<subject>_test.exs` defining `Troupe.<App>.<Subject>Test`; `describe` and `test` names are sentences describing a property, and each file opens with a `@moduledoc` saying what it proves and how it skips | e.g. `apps/troupe_plane/test/troupe/plane/admin_parity_test.exs:1-33`; enforced only by `WrongTestFilename` |

## 9. Recipes

### Adding an admin method

`Troupe.Plane.Admin.API` is "a rename: a method name to a `Troupe.Plane.Admin` function
and its arguments" (`api.ex:5-7`); the MCP tool list is projected from it
(`apps/troupe_plane/lib/troupe/plane/admin/mcp.ex:200`, `MCP.tools/0` maps `API.list/0`).
The edits:

1. The function in `apps/troupe_plane/lib/troupe/plane/admin.ex`, taking the actor
   first and returning `{:ok, result}` or `{:error, %Error{}}`; authorisation and the
   `Audit.record/5` call live here (`admin.ex:26-28`).
2. A `%Method{}` entry in the table in `apps/troupe_plane/lib/troupe/plane/admin/api.ex`
   with a summary ending in a full stop, typed `%Argument{}`s each with a description,
   a `risk`, and `confirm` naming an argument when the risk is `:destructive`
   (`api.ex:16-35`; checked at `admin_parity_test.exs:107-134`).
3. A `{~w(words), "admin.x.y", ["arg", ...], "help"}` row in `@commands` in
   `apps/troupe_ctl/lib/troupe/ctl/admin.ex:19-`.
4. The console: a LiveView under `apps/troupe_plane/lib/troupe/plane/web/live/` that
   calls `Admin.<function>` and nothing else in `Troupe.Plane.*` (the module rule in
   `troupe.boundaries.ex:48-51`).

Then run `mix test apps/troupe_plane/test/troupe/plane/admin_parity_test.exs` (needs
PostgreSQL only for the rest of the plane suite; the parity test is `async: true` and
does not touch the database). The MCP tool appears without an edit; a tool name is the
method with dots replaced by underscores (`mcp.ex:211-216`).

### Adding a protocol event

1. Add the type and its `data` shape to `Troupe.Protocol.Schema.events/0`
   (`apps/troupe_protocol/lib/troupe/protocol/schema.ex:31`) — or to
   `ephemeral_events/0` (`:196`) if it carries no `seq`. Only add fields; never remove,
   rename, retype or make one required (`:9-12`).
2. Emit it through `Troupe.Session.Log.append/5` with the type as an atom
   (`apps/troupe_core/lib/troupe/session/log.ex:44-55`). Nothing else may publish a
   durable event. `Log.append` does not validate against the schema; the test does.
3. If the agent's replay acts on it, add it to `Troupe.Log.Fold.witnessed_types/0`
   (`apps/troupe_core/lib/troupe/log/fold.ex:59-70`); `fold_test.exs:72-75` reads the
   replay clauses out of `agent/server.ex` and fails if the witness does not cover them.
   A change that alters the fold of an existing fixture needs a new version and
   `mix troupe.fixtures.record <version>`, never an edited `hashes.json`.
4. Run `mix troupe.schema.gen` and commit `protocol/schema/v1/`; `mix troupe.schema.diff`
   and the `git diff --exit-code` step will otherwise fail CI (`ci.yml:229-236`).
5. Run `apps/troupe_core/test/troupe/session/log_schema_test.exs` if a real session
   emits it, and update the event table in `PROTOCOL.md:196-227` — which the audit
   found already missing eight emitted types ([../AUDIT.md](../AUDIT.md) §2), so treat the
   table as documentation debt rather than as a check.

### Adding a platform setting

1. Add a `%Setting{}` to `@settings` in `apps/troupe_plane/lib/troupe/plane/settings.ex:49-`
   with `key`, `group`, `type` (`:string | :integer | :boolean | :enum`, plus `values` as
   atoms for an enum — see commit 9a200cf), `summary`, `consequence`, `effect`, and either
   `app_key` (an atom or a path into the application environment the deployment sets)
   or `fallback` (`apps/troupe_plane/lib/troupe/plane/settings/setting.ex:1-40`). `group`
   decides which panel of the Settings page it appears in, "so that adding one is a
   change to this list and nothing else" (`setting.ex:20-22`). Read-only deployment
   values set `editable: false`; secrets set `secret: true` and are reported as set or
   not (`settings.ex:20-28`).
2. Read it with `Troupe.Plane.Settings.get/1` at the point of use (`settings.ex:260`);
   values are cached for five seconds per node and a write invalidates its own node
   (`settings.ex:37-45`). The settings page, `admin.settings.list`,
   `admin.setting.put` and `admin.setting.reset` need no change: they go through
   `Admin.settings_list/1`, `setting_put/3` and `setting_reset/2`
   (`apps/troupe_plane/lib/troupe/plane/admin.ex:431-467`), which read the registry.
3. If the setting has a deployment default, add the environment variable to
   `config/runtime.exs` and the value to `charts/troupe/values.yaml` and the plane
   Deployment, and document it in [../admin/configuration.md](../admin/configuration.md).
   A `fallback` with no reader is what `default_bundle_channel` is today
   ([../AUDIT.md](../AUDIT.md) open question 10); add the reader in the same change.

### Adding a protocol command

Not asked for here, but the same shape: `Troupe.Protocol.Schema.commands/0`
(`schema.ex:231`), the scope table and handler in `Troupe.Gateway.Dispatch`
(`dispatch.ex:41-74`), schema regeneration, and a `command_id` if it changes anything
(`commands.ex:5-9`).
