---
number: 918
title: "A running session explains what is in force in it, from the layers it started with, through `config.get` naming it, which a pod answers its session's own token too, `troupe config --explain --session`, the TUI's `/settings` and the desktop's Settings pane; a GUI test waits for a control as for words; and a trigger that stops taking a key loses it"
date: 2026-10-18
status: accepted
supersedes: [913, 914, 915]
paths:
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe/registry.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/explain.ex
  - apps/troupe_core/lib/troupe/config/settings.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_worker/lib/troupe/worker/auth.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/test/troupe/worker/config_explain_test.exs
  - clients/tui/lib/troupe/cli/session_config.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/test/troupe/pod_settings_test.exs
  - clients/gui/packages/client/src/config.ts
  - clients/gui/apps/desktop/src/views/PodConfig.tsx
  - clients/gui/packages/client/test/support/waits.ts
  - clients/gui/apps/desktop/test/support.ts
  - clients/gui/apps/console/test/support.ts
  - apps/troupe_plane/lib/troupe/plane/triggers.ex
  - apps/troupe_plane/priv/repo/migrations/20261018000918_dead_trigger_keys.exs
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/scim.ex
  - scripts/dev-down
  - apps/troupe_operator/test/support/e2e/world.ex
symbols:
  - Troupe.Session.resolved/1
  - Troupe.Config.Settings.describe_session/1
  - Troupe.Config.Explain.explain_session/3
  - Troupe.CLI.SessionConfig
  - Troupe.Plane.Identity.refusal_standing?/2
gist: "config.get naming a session is what it started with, layers named (profile, session, enforced); a pod answers its token; GUI waits for controls; no key kept off a webhook"
---

Chunk 38's slot C38: the follow-up Decision 913 left ("there is no method that explains a
pod session's configuration"), the rest of Decision 915's waiting guard, and the small
code-local items of `defects.md` D130. Each part had a test that failed on the chunk's tip.

## A running session explains what is in force in it

**What is in force is what it started with.** A session resolves its configuration once,
as it starts (`Troupe.Session.build_opts/1`), and the layers it was resolved from, every
value and rule with where it came from, are kept with the session's name in the registry
(`Troupe.Session.resolved/1`). `config.get` with a `session_id` answers from those
(`Settings.describe_session/1`), in the shape `config.get` answers a workspace's, plus
`session_id` and `pod`; `explain` (`text` or `json`, for `key`) adds what `troupe config
--explain` prints for it (`Explain.explain_session/3`). Re-reading the files at the
request was the other choice, and is wrong twice: a file changed since says what the
session does not run, and a pod's terms and profile rules are not in any file.

**A pod's parts are named.** The worker passes, beside its overrides, where each came from
(`Troupe.Config.resolve/3`'s `:sources`): the environment is the worker profile's, which the
operator writes from its `llm`, so its values are layer `profile` with the profile and the
variable as source; the terms the session was created with are `session`; the platform's
two switches are `enforced`, from the plane's platform settings, and so written to no scope;
what the pod sets of its own is `cli`, from the worker pod. The profile's rules, which
arrive as overrides, are in the layers' `rules` beside the files', so they are listed with
their profile, as `Permissions.scope/1` already named them; the configuration in force is
unchanged, since a profile's rules are the platform's and nothing held them. A repository's
files read as a pod reads them, no key marked trusted taken from them, which the answer's
warnings say. On a pod no key has a scope: none of it is a client's to write.

**A pod answers its session's own token.** The guard keeps `config.get` the pod's own when
it names no session, and refuses a session's token that; naming the token's session, it is
that session's, held to the role as every method about the session is (`observe`). The
gateway answers it on a worker as on a daemon, where every other `config.*` method stays the
daemon's.

**Shown everywhere a laptop's is.** `troupe config --explain [KEY] [--json] --session ID`
asks this machine's daemon, and for a session it does not have, the session's pod through
the plane last signed in to, opened to read, which wakes nothing; a session asleep is said to
have nothing in force. The TUI's `/settings` in a pod session reads the pod's answer over the
session's connection and changes nothing (each change says why), and the person's own theme
is not taken from it. The desktop app's team session has a **Settings** pane listing every
key something set and every rule, each with where it came from. Not chosen: a pod pushing
the explanation into the session's log, which would write configuration into a history the
plane cannot read and make every wake an event.

## A GUI test waits for a control as for words

Decision 915's check refused a bare `says` or `link`; a control is the same shape. It now
refuses `expect(button(…))`, `field(…)` or `row(…)` asserted present at once, and a read of
one found at once (`button(…)!.disabled`), unless marked `// at once: <why>`. The supports
wait for it, `await seesButton(…)` (the console's `seesField(…)` too), and the test reads the
control the wait answered. 43 such assertions were converted across both apps. Absence is
still not checked, as words' is not: `expect(button(…)).toBeNull()` cannot flake this way,
only pass early, and the about 65 of them stay.

## A trigger that stops taking a key loses it

Decision 914 left a key on a trigger whose source stopped taking one, dead but kept, and a
listing then said `has_key`. Now `Triggers.put/3` and the GitOps pass drop the key, its hash,
salt and rotation, when a trigger is written with a source that takes none, and the
listing's `has_key` is true only for a webhook that names no repository and holds one; a
migration drops the keys kept before. A trigger changed back to a webhook has no key until a
rotation gives it one, as 914 said, and now also says.

## The rest of D130's small items

- **A refused push a later push resolves.** A push that agrees with the row SCIM gave its
  `externalId`, after one of the pair was refused, audits `person.adopt_agreed`, and the pair
  is no longer listed by `admin.identity.duplicates`; one refused after that is listed again.
  Audited only while a refusal stands (`Identity.refusal_standing?/2`), so a provider's every
  sync writes nothing. Unlike an administrator's settlement (`person.adopt`), an agreement
  lets no later disagreeing push past the check.
- **Plane test databases.** `scripts/dev-down --test-databases [DAYS]` drops the
  per-checkout test databases made more than a week (or DAYS days) ago, saying each, and
  keeps one in use; a checkout that still runs its suite makes its own again.
- **The cluster suite's waits say why.** `World.eventually/2` takes `:explain`, asked once
  when it gives up, and a world's wait for a profile to finish replacing its pods says the
  profile's conditions, each pod's phase, readiness and container states, and the namespace's
  last warnings.
- **The fake pod's mark everywhere.** `bundles_test.exs` and `control_test.exs` enrol with
  `FakePod.token/1` and verify with `FakePod.verify/1`, as the other plane suites do, so
  another checkout's worker link that reaches the port is refused.

## Proof

On the chunk's tip `config_explain_test.exs` (worker) failed every test: `config.get`
naming the session was `forbidden` to its token, and `method_not_found` on a pod to anyone.
Now it answers the profile's `models.cheap` as `profile`, `max_turns` and `approvals` as
`session`, `managed_permission_rules_only` as `enforced` with no scope, the repository's
`compact_at` and not its `auto_approve`, the profile's two rules with their profiles, and
the explanation's text, ladder and JSON; the pod's own settings and another session's stay
refused, and a session not running there is `not_found`. Core's `describe_session/1` answers
what a session started with though its file changed after. The TUI's `pod_settings_test.exs`
draws `/settings` in a pod session from the fake pod's answer and changes nothing, and the CLI
asks the daemon, then the pod, then says the session runs nowhere. The desktop's
`pod-config.test.tsx` lists the pod's keys and rules in a team session's Settings pane, and a
local session has none. Both apps' `waits.test.tsx` refuse the control forms and found 43 on
the tip. `trigger_ingress_test.exs` keeps no key on a trigger made a schedule and lists a
kept one as none; `identity_gaps_test.exs` drops a refusal a later push resolved and lists one
after it again.
