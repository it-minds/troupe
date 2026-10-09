---
number: 826
title: "On a pod the bundle's agents and skills beat the working copy's of the same name unless the profile sets `repositoryOverridesBundle`; the losers are listed as skipped, onboarding refuses there, and a worktree reads its main checkout's committed files"
date: 2026-10-09
status: accepted
issue: 516
paths:
  - apps/troupe_core/lib/troupe/agent/definitions.ex
  - apps/troupe_core/lib/troupe/skills.ex
  - apps/troupe_core/lib/troupe/worktree.ex
  - apps/troupe_core/lib/troupe/onboard/pod.ex
  - apps/troupe_core/lib/troupe/session.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/test/troupe/pod_layers_test.exs
  - apps/troupe_core/test/troupe/onboard/pod_test.exs
  - apps/troupe_worker/lib/troupe/worker/plane/commands.ex
  - apps/troupe_worker/test/troupe/worker/bundle_wins_test.exs
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_plane/lib/troupe/plane/web/live/profile_editor.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - charts/troupe/crds/workerprofile.yaml
  - docs/admin/profiles-and-policy.md
symbols:
  - Troupe.Agent.Definitions.bundle_wins?/1
  - Troupe.Agent.Definitions.load/2
  - Troupe.Skills.available/3
  - Troupe.Skills.skipped/2
  - Troupe.Worktree.main/1
  - Troupe.Onboard.Pod.refusal/1
gist: "On a pod the bundle's agents and skills beat the disk's of a name unless spec.repositoryOverridesBundle is true; losers listed in files_skipped"
---

Issue #516, slice 7, and its decision 6 as the maintainer took it: on a pod the bundle
wins, with a profile setting to let the repository's files win instead.

What was there: `Troupe.Agent.Definitions.load/2` merged built-ins, then the bundle, then
the config directory's `agents/`, then the working copy's `.troupe/agents/`, and
`Troupe.Skills.available/3` put the person's and the workspace's skills after the
bundle's, the nearer layer winning. On a pod the working copy is a clone, so a
repository's `.troupe/agents/build.md` replaced the `build` the channel's bundle publishes,
in every session of every team that opened that repository; the only defence was a
moduledoc saying those directories were empty on a worker, which nothing made true.

- **The rule, in one place.** `Definitions.bundle_wins?/1`: wherever a session has a
  bundle, which only a pod does, the bundle's agents and skills beat every file on the
  pod's disk of the same name, unless the bundle pin carries `repository_overrides: true`.
  The agent merge (`load/2`) and the skill merge (`Skills.available/3`, through its
  private `local/2`) both ask it. On a pod the order is: built-ins, the pod's config
  directory, the working copy (`.troupe/agents/`, `.troupe/skills/`, and whatever
  `Skills.Local` reads besides, `.agents/skills/` included once Decision 822's layer is
  there), then the bundle, then its ACP agents. The setting puts the bundle back below the
  directories, which is the order there was before.
- **Only the names the bundle has.** A working copy's agent or skill of another name is
  read as on a laptop, and may still replace a built-in agent the bundle does not
  publish; an admin who wants a name fixed publishes it in the bundle. A skill on disk of
  a name the bundle has is left out whether or not the agent at hand may consult the
  bundle's one, for the reason `load/2` gives for applying the entitled set after the
  merge: a file standing in for one somebody was not given is a different skill answering
  to that name.
- **A loser is not read, and is listed.** It is taken out of its layer before the merge,
  not parsed and then replaced, so a broken one cannot even warn. `Definitions.skipped/1`
  and `Skills.skipped/2` give each as `{kind, name, path, reason}`; the reason says the
  bundle has that name and that the profile does not allow the repository's. The session
  writes them into its log as `files_skipped` (a new durable event, an addition within
  version 1) at a start whose list differs from the one the log last recorded, an empty
  list included: the definitions are read again at every activation, a working copy can
  gain or lose the file between two, and a session that keeps the same file through a
  hundred wakes says so once. A durable event rather than a log line because the person
  whose repository it is reads the session, not the pod's log, and because a log is where
  "what could this session have used" is already answered (`session_created`'s
  `entitlements`, `mounts_resolved`). Not on `session_created`, which is written once,
  before a session's first clone has run.
- **The setting: `spec.repositoryOverridesBundle` on the `WorkerProfile`.** A boolean, off
  unless it is `true`. It lives in the resource's spec, so the plane's row keeps it in its
  existing `spec` map with no migration, a repository's manifest holds it in gitops mode,
  and the CRD declares it (`type: boolean`, no default, so no existing resource changes).
  The plane refuses a value that is not a boolean in `Fleet.Profile`'s changeset, which
  `admin.profile.put` and the gitops reader both go through: a `"true"` saved as text would
  be on to the admin and off to the pod. The console's editor has it as a toggle, loaded
  and written back as `orgMount` is, so a save from there does not turn it off.
- **It travels with the pin, at every activation.** `Harness.bundle_params/1` reads it
  from the profile's row and sends `repository_overrides_bundle` beside `bundle_version`
  in `session.activate`, on a session's first start and every wake; the worker puts it on
  the bundle map as `repository_overrides`, beside `entitlements`, for the reason that
  comment already gives: every place that reads the bundle has to apply it, and something
  carried separately is something one of them forgets. Not an environment variable the
  operator sets: that would restart every pod to change it, and an `ssh` profile has no
  pod template. Anything but `true` on the wire is the bundle winning, so a plane that
  says nothing leaves pods on the safe side.
- **Commands (Decision 763).** They follow the same rule and have nothing to lose to: a
  bundle carries no commands, so a working copy's `.troupe/commands/` are read on a pod as
  everywhere, and a command named like an agent is still skipped as 763 says, the agent on
  a pod being the bundle's. When bundles carry commands, they join this rule.
- **Onboarding refuses on a pod.** `Troupe.Onboard.Pod.refusal/1` is the one check, for
  `troupe onboard` and for the onboarding tool (#516 slice 3) alike: given a session id, a
  `team` session is refused; given `nil`, as a command line has no session, a machine
  marked `TROUPE_WORKER_AUTOSTART=true` is, which the operator sets on every pod and a
  host sets for its worker, and which a command a session's shell runs there inherits. The
  sentence says to onboard on your own machine and commit the result. On a pod the working
  copy is a clone the bundle beats and the config directory is the pod's, read by every
  session it runs: neither is a place to write Troupe's own files.
- **A worktree reads its main checkout's committed files.** A git worktree is made at a
  commit, so one made before onboarding has no `.troupe/agents/` or `.troupe/skills/`
  while the main checkout's sessions read them. `Troupe.Worktree.main/1` recognises one as
  trust does (`Troupe.Config.Trust.root/1`): its `.git` file names the checkout's
  `.git/worktrees/<name>` and that names it back. The project layer is then the worktree's
  own directory over the main checkout's, and of the main checkout's only the files its
  HEAD commits (`git ls-tree`) are read. A file there that is not committed — onboarded
  and not reviewed yet, untracked or only staged — is not read and is listed as skipped,
  saying to commit it; one the worktree has its own of is not listed. A committed file is
  read where it is, so an edit to it not yet committed is read with it: what is committed
  decides which files, not which bytes. The main checkout's `.troupe/skills` becomes a read
  root of the worktree's session, for the files beside its skills. Commands, workflows and
  `mcp.json` in a worktree are not part of this slice.
- **Not decided here, as the chunk said:** Cursor rules at runtime or onboarded, automatic
  onboarding, the deprecation, and a repository without `AGENTS.md` (#516's decisions 1,
  4, 5 and 7). The precedence ladder is Decision 822's; this decision is its pod line.
- **Proof:** `Troupe.PodLayersTest` — a pod session whose working copy has
  `.troupe/agents/build.md` ran the repository's `build` on the chunk's tip (the first
  test failed there with `:project`); now the bundle's runs and the model is sent its
  prompt, a name the bundle lacks is the repository's, the repository's skills of the
  bundle's names are neither offered nor stand in, `skipped` lists them with the reason,
  `files_skipped` is written once across a dormancy and again, empty, when the files go,
  `repository_overrides` puts the order back, and a laptop is unchanged; a worktree made
  before onboarding reads the main checkout's committed agent and skill, its own first,
  lists the uncommitted ones and reads them once committed, and the checkout reads its own
  as they are. `Troupe.Onboard.PodTest`: a team session and a worker's machine refused with
  the sentence, a local session and a laptop allowed. `Troupe.Worker.BundleWinsTest`, a
  `session.activate` with a bundle the pod's registry fetches: the bundle's `build` and the
  repository's in `files_skipped`; with `repository_overrides_bundle: true` the
  repository's; with `"true"` the bundle's. The plane's `AdminTest` (a boolean kept, a
  string or a number refused), `BundlesTest` (the push says `false`, then `true` once the
  profile does) and `PanelTest` (the toggle, kept on a save, cleared when unticked).
