---
number: 903
title: "A profile preview compares the stored profile with the write laid over it; enabling a team's group again changes none of its settings unless asked to link; the plane's own subjects are no person's; a removed person's sessions stay theirs through a rebuild; and a push GitHub took that the plane missed is recorded by the next one"
date: 2026-10-14
status: accepted
supersedes: [901]
paths:
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/provision.ex
  - apps/troupe_plane/lib/troupe/plane/login.ex
  - apps/troupe_plane/lib/troupe/plane/index.ex
  - apps/troupe_plane/lib/troupe/plane/identity.ex
  - apps/troupe_plane/lib/troupe/plane/web/router.ex
  - apps/troupe_worker/lib/troupe/worker/github.ex
  - apps/troupe_worker/lib/troupe/worker/github/tree.ex
  - clients/gui/apps/console/src/views/Profiles.tsx
  - clients/gui/apps/desktop/src-tauri/src/daemon.rs
  - clients/gui/packages/client/test/support/daemon.ts
  - apps/troupe_core/lib/mix/tasks/troupe.config.schema.ex
  - clients/gui/packages/client/test/support/provider-types.ts
symbols:
  - Troupe.Plane.Admin.preview/2
  - Troupe.Plane.Admin.team_enable/4
  - Troupe.Plane.Provision.verdict/1
  - Troupe.Plane.Identity.removed_owner/2
gist: "Preview diffs stored vs stored+write; team.enable on its own group refuses changed settings without link; removed:/svc: never sign in; rebuild keeps markers; lost pushes recorded"
---

A sweep of small defects the chunk 34 fixers recorded in `docs/developer/defects.md` (D127)
and the chunk 35 fixers noticed, fixed in chunk 35. Most are bugs against a rule already
written down; these are the ones where a rule had to be chosen. It replaces the bullet of
Decision 901 that has the console drop the preview's lines the write does not send; the rest
of 901 stands. It also does two things Decision 899 lists as not done there.

- **A profile preview compares like with like.** `admin.profile.preview` diffed the stored
  row, every column of it, against the write as sent, so every preview said the name, the
  replicas and the sessions per pod were changing, though no write sends the last two and
  the name only says which profile. It now diffs the stored profile against the stored
  profile with the write's fields laid over it, which is what a put leaves, so the preview
  and the put's audit diff are the same diff. The console's filter for it is gone.
- **A verdict's violations are sentences.** `Provision.verdict/1` carried the policy
  checker's tuples, which JSON cannot carry, so `admin.profile.get` and
  `admin.profile.preview` of a profile the cluster's policy refuses answered a 500 over
  `/rpc`. It describes them as `check/1` does.
- **A blank "most sessions at once" in the LiveView editor is no ceiling**, sent as `null`,
  as the console sends it (Decision 901). Dropped when blank, a ceiling could be set there
  and never taken away.
- **Enabling a team's own group again changes none of its settings.** `admin.team.enable`
  on a group a team already draws from, with settings that differ from the team's, changed
  them and answered the team as if nothing had; with none sent, it put the team's settings
  back to the plane's defaults. Of the two ways out, answering with what changed or refusing
  without `link: true`, this refuses: it is the pattern the same method already follows for
  a name another team has, the console already treats an existing name as a refusal, and a
  team's settings change through `admin.team.update`, which answers its diff. The refusal
  is `conflict` with `settings` naming the fields, compared as the team's changeset casts
  them. With `link: true` it changes them, and a team that exists takes only the settings
  sent: the plane's defaults are a new team's, which is what the `link` argument already
  said ("changing its settings to those sent").
- **The plane's own subjects are no person's.** A sign-in whose subject claim starts with
  `removed:` (a removed person's sessions' owner) or `svc:` (a service principal) is refused
  as `reserved_subject`, before anything is looked up.
- **A `PUT` to `/scim/v2/Users/<id>` names a person the plane has**, or answers `404` as a
  `GET` does. It was keyed on the body alone, so a provider replacing somebody it had
  deleted made them again.
- **A removed person's sessions stay theirs through `mix troupe.index.rebuild`.** The
  manifest names the subject they had. A row whose owner is a tombstone's marker keeps it;
  with no row, a session whose manifest was last written no later than a removal under that
  subject is that tombstone's. Either way it is read-only, and a row that was read-only stays
  so; nobody who later arrives under the subject is given it.
- **A push GitHub took that the plane did not record is recorded by the next one.** Before
  it builds a commit, a push reads the branch's head. One ahead of the record is the
  session's own when its only parent is the session's last commit (or the clone's, before a
  first push), its message carries the session's `Troupe-Session:` trailer, and its tree is
  one the workspace's own git holds, which only this workspace and GitHub have; then it is
  recorded and the push builds on it. Anything else is left as it is, and the push is
  refused as before: a person's commit on the branch is never built over.
- **A first push takes the clone's starting commit where the plane never did**, from the
  root of the workspace's history (a clone of depth one checked it out), and records it.
- **The audit logs a redaction at `debug`.** An ordinary profile's diff carries
  `secretRef.key`, `tokenUrl` and `transitKey`, each redacted on every save; that is the
  belt-and-braces working, not an error.
- **The desktop app starts a daemon with `CREATE_NO_WINDOW` on Windows**, so the
  `troupe-daemon.cmd` shim, run by `cmd.exe`, opens no console window.
- **The GUI's fake daemon serves the protocol's list of provider types.**
  `mix troupe.config.schema` writes `clients/gui/packages/client/test/support/provider-types.ts`
  from `Troupe.Protocol.ProviderTypes.wire/0` and `kinds/0`, `--check` holds it there in CI,
  and the fake imports it, so it cannot offer a list the daemon does not. A module beside the
  fake rather than a file under `protocol/schema` it reads: the GUI's tests also run in an
  image built from `clients/gui` alone, which the cluster job found when a first try read the
  file from the repository root.

**Proof:** each was a failing test on the chunk tip first, apart from the TUI race and the
cluster test's comment. Over `/rpc`, `admin.profile.get` of a refused profile answered 500
with the tuple in the log; the preview listed `replicas` and the name; the LiveView save
kept `max_sessions` at 6; the team kept no `budget_micros` when enabled again with none; a
`PUT` after a `DELETE` answered 200; `Login.from_claims/1` signed in a `removed:` subject;
the rebuild named the removed person's subject; the push after a lost record was refused as
"commits this session did not push", and one with no base as having nothing to build on;
the audit logged `[error]` three times for one profile's identities; `cargo test` found the
daemon's command on the test's own console; and a label changed in the fake's generated
list fails `mix troupe.config.schema --check`. The tests are in `admin_api_test.exs`,
`panel_test.exs`, `one_row_per_person_test.exs`, `admin_test.exs`, the worker's
`index_rebuild_test.exs` and `github_fix_loop_test.exs`, and `daemon.rs`.
