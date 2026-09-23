# Conventions

What a tool enforces, and the habits the code shows. Where a convention is stated but not
enforced, this says so.

## 1. The gate

`mix check` runs, in the test environment: `compile --force --warnings-as-errors`,
`format --check-formatted`, `credo --strict`, `troupe.boundaries`, `test`. CI's `lint` and
`test <app>` jobs run the same steps plus the generated-file checks
([build.md §3](build.md#3-generated-committed-files)); `scripts/ci` is the CI job on a
machine. The clients have their own gates: `mix check` in `clients/tui` (with
`troupe.xref`), and `pnpm typecheck`, `test`, `tokens:check` in `clients/gui`. A package
both the TUI and the umbrella lock must be the same version in both lock files;
`elixir scripts/locks-agree.exs` checks it.

**The formatter's blind spot.** The root `.formatter.exs` lists
`{config,lib,test}/**/*.{ex,exs}` relative to the root, and no app has its own, so
`mix format --check-formatted` never opens a file under `apps/`. Credo covers part of it
(spacing, trailing whitespace, line length 120). Run `mix format` in the app directory by
hand.

**Credo** runs with `--strict`, so low-priority checks fail too: a `TODO` or `FIXME`
comment fails the gate; every module needs a `@moduledoc`; no `IO.inspect`, `dbg` or
`IEx.pry`; test files end in `_test.exs`; `apply/3` is flagged (the one deliberate use says
why).

**Line endings** are LF everywhere, whatever `core.autocrlf` says (`.gitattributes`):
Credo's line-ending check and `dash` both break on CRLF.

## 2. Boundaries

The rules are in [architecture.md §2](architecture.md#2-boundaries). When a client
needs a server module, the protocol is missing a method — add it to `PROTOCOL.md` and the
apps in the same pull request as the client change that needs it. A LiveView calls
`Troupe.Plane.Admin` and nothing else in the plane.

## 3. Rules the code states and tests check

| Rule | Checked by |
|---|---|
| `Session.Log` is the only publisher of durable events; agents publish ephemerals | structure: `Troupe.Events` is internal to core |
| Ephemerals are never persisted and may be dropped | `backpressure_test.exs` |
| A response is an acknowledgement, never the effect; replaying a `command_id` returns the first acknowledgement | `commands_test.exs`; the Python conformance client |
| Schema changes are add-only within version 1 | `mix troupe.schema.diff` |
| An upcaster adds and renames, never drops; one version at a time | `fold_test.exs` against recorded fixtures |
| A recorded fixture hash is evidence, not a test to update | `troupe.fixtures.record` refuses to overwrite |
| Every admin method is an API method and an MCP tool, with a summary and described arguments; destructive ones name `confirm`; none returns session content | `admin_parity_test.exs` |
| Troupe creates no Kubernetes Secrets | no `kind: Secret` in the chart |
| A UI can never apply backpressure to an agent | a test stalls a socket and requires turn latency within 10 % |

## 4. Comments, decisions and messages

- **Comments say why.** Every module opens with a `@moduledoc` that argues for the design
  rather than restating the code. When behaviour changes, the moduledoc moves with it.
- **`DECISIONS.md`** records every judgment call a reader could have made differently,
  numbered, newest at the bottom: a bold one-sentence decision, then the reasoning. Code
  cites decisions by number. `clients/tui/DECISIONS.md` and
  `apps/troupe_daemon/DECISIONS.md` hold those two projects' own.
- **Commit messages and pull request titles** state the behaviour that is now true, in
  plain prose — "A session's listing says what it has actually spent" — with a body saying
  what was wrong, what changed and why. No conventional-commit prefixes, no ticket numbers,
  and no attribution trailers. Nothing enforces this.

## 5. Naming

| Thing | Pattern |
|---|---|
| Worker namespace and workload | `<namespacePrefix><profile>`, default `troupe-w-` |
| Pod; its Service and Ingress | `troupe-w-<profile>-<ordinal>`; `<profile>-<ordinal>` |
| Pod hostname | `<ordinal>-<profile>.<workersDomain>` — one DNS label, so one wildcard covers every profile |
| Session id | `YYYYMMDDTHHMMSS-<4 random bytes, url-safe base64>` |
| Service principal | `svc:<team>/<name>` |
| Images | `troupe-operator`, `troupe-plane`, `troupe-worker`, `troupe-a2a`, `troupe-gui` |
| Team and org volumes; a pod's own | `team-<team>`, `org`; `data` |
| Tests | `<subject>_test.exs` defining `Troupe.<App>.<Subject>Test`; test names are sentences stating a property; each file's `@moduledoc` says what it proves and how it skips |

## 6. Recipes

**An admin method.** The function in `Troupe.Plane.Admin` (actor first, `{:ok, result}` or
`{:error, %Error{}}`, authorisation and `Audit.record/5` inside); a `%Method{}` in
`Troupe.Plane.Admin.API` with a summary ending in a full stop, typed and described
`%Argument{}`s, a `risk`, and `confirm` when destructive; a LiveView that calls it. The MCP
tool appears by itself. Run `admin_parity_test.exs`.

**A protocol event.** Add the type and its data to `Troupe.Protocol.Schema.events/0` (or
`ephemeral_events/0`), only ever adding fields; emit it through `Session.Log.append/5`; if
the agent's replay acts on it, add it to `Troupe.Log.Fold.witnessed_types/0` (the fold test
reads the replay clauses and fails otherwise) and record a new fixture version rather than
editing a hash; run `mix troupe.schema.gen` and commit `protocol/schema/v1/`; update the
event table in `PROTOCOL.md`.

**A protocol command.** `Troupe.Protocol.Schema.commands/0`, the scope table and handler in
`Troupe.Gateway.Dispatch`, schema regeneration, and a `command_id` if it changes anything.
The GUI's side: a wrapper in `packages/client/src/plane.ts` (plane RPC) or a method on
`SessionView` (a session command), an open type, an export from `index.ts`, a case in the
test fakes.

**A platform setting.** A `%Setting{}` in `Troupe.Plane.Settings` with `key`, `group`,
`type`, `summary`, `consequence`, `effect` and either `app_key` (the deployed value) or a
`fallback`; `editable: false` for deployment values, `secret: true` for secrets. Read it
with `Settings.get/1` where it is used. The console, `admin.settings.list`, `put` and
`reset` need no change. A deployed default also needs the variable in `config/runtime.exs`,
the value in `charts/troupe/values.yaml` and a row in
[../admin/configuration.md](../admin/configuration.md).

**A GUI view.** `apps/desktop/src/views/<Name>.tsx`, importing only React,
`@troupe/client`, `../hooks`, `../shell` and sibling views; data through a hook, never a
socket in a component; `Pill`, `statusOf`, `Cost` and friends from `views/bits.tsx`; a new
colour starts as a token in all three theme files. Check it at 380 px, and that every
status is a glyph and a word.
