---
number: 835
title: A session's start asks about onboarding first and starts the librarian only once that is answered, over onboard.plan, onboard.apply, onboard.decline and memory.decline; the librarian writes the brief only
date: 2026-10-10
status: accepted
issue: 516
supersedes: [827]
paths:
  - apps/troupe_core/lib/troupe/onboard/notice.ex
  - apps/troupe_core/lib/troupe/onboard/start.ex
  - apps/troupe_core/priv/agents/librarian.md
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - apps/troupe_core/test/troupe/onboard/notice_test.exs
  - apps/troupe_core/test/troupe/onboard/librarian_test.exs
  - apps/troupe_core/test/troupe/tools/onboard_write_test.exs
  - apps/troupe_gateway/test/troupe/gateway/onboard_test.exs
  - clients/tui/lib/troupe/client/daemon/start.ex
  - clients/gui/packages/client/src/onboard.ts
  - clients/gui/apps/desktop/src/views/Onboard.tsx
symbols:
  - Troupe.Onboard.Notice.onboarding/2
  - Troupe.Onboard.Notice.brief/2
  - Troupe.Onboard.Notice.decline_onboarding/2
  - Troupe.Onboard.Notice.decline_brief/2
  - Troupe.Onboard.Start
gist: "Start: onboarding (first/outdated, in a repo only) before the librarian; ids name what was shown; plan is admin; notice repeats; no onboard_write"
---

Issue #516, the chunk's third wave, as the maintainer decided it: at a session's start,
first onboarding, then the librarian. Amends Decision 827 in three places (its
`supersedes` is that part): the librarian no longer onboards, the notice is said at every
start while something is due rather than once per version, and a start now asks rather
than only telling the person to run `troupe onboard`. On the chunk's tip a first session
over a `CLAUDE.md` with no brief started the librarian at once and asked nothing, the
librarian's first step was an onboarding pass through `onboard_write`, and `onboard.plan`
was `method_not_found`.

- **What is due, decided in one place.** `Troupe.Onboard.Notice.onboarding/2`: `first`
  when the workspace has other tools' files, nothing is onboarded and nothing declined
  there (827's test, the plan it took to decide kept); `outdated` when the workspace's
  recorded onboarding version (`Troupe.Onboard.onboarded_version/2`) is older than
  `Troupe.Onboard.version/0`; `none` otherwise, on a pod or a worker's machine, and once
  the person said no under this version. **Only in a git repository** (a `.git` here or
  above, as `Troupe.Instructions.repository_root/1` finds it): a start in a directory in
  none is `none` before any source is asked. In the home directory, Claude Code's own
  `~/.claude/` looked like a workspace's `.claude/`, so a start there planned by walking
  the whole home tree and proposed `~/AGENTS.md`, and with the notice said at every start
  it would have done so every time. `Troupe.Onboard.Notice.brief/2`: `first` and
  `stale` as `refresh_due` has them (Decisions 649, 696, 713, the TUI's 127), `outdated`
  when an older survey wrote the brief (`Troupe.Memory.survey_version/0`) and the person
  has not said no to that, `none` otherwise or with memory off. The event and the protocol
  read the same functions, so they cannot disagree.
- **The answers are the person's, in the state directory.** `<state>/onboard.json` gains
  `onboarding_declined` (the workspace's real path to the rules' version the person said no
  under) and `brief_declined` (the brief's path, so every checkout of a repository shares
  it, to the survey's version), beside `declined`, the per-file nos `troupe onboard`
  already kept (Decision 823). A no lasts until the version changes; nothing is written
  into the repository by saying no.
- **The notice repeats until answered.** `onboarding_suggested` is logged at every start
  while onboarding is due or the brief outdated and not declined for that version, with
  `due`, `brief_due` and `counts` (`files`, `write`, `create_agents_md`: the workspace's
  files a client would ask about) added to what 827 gave it. 827 said it once per
  workspace and version and remembered that it had (`suggested`): a person who closed the
  client before answering was never asked again, and a client that asks on the event (the
  desktop app) would never ask. The notice now writes nothing at all. The cost is the
  first-time plan at each start of a workspace that has other tools' files and has not
  answered, which a workspace with none never pays (`found?/1` first, as 827 has it).
- **The protocol (additive to v1).** `onboard.plan {workspace}` answers `onboarding`
  (`due`, `recorded`, `version`, `tools`, `items`, `skipped`), `brief` (`due`, `recorded`,
  `version`) and `refusal` (`Troupe.Onboard.Pod`'s sentence on a worker's machine, where
  onboarding is never due). Items are listed only while onboarding is due, and then every
  one the person would see: the workspace's and their own (`Troupe.Onboard.plan/2` for
  every target, every registered source); while it is not, no source is asked, so a start
  with nothing due does not walk the workspace. Each item carries `id`, `target`, `path`,
  `shown`, `status`, `question` (`write` or `create_agents_md`), `source`, `also_from`,
  `was`, `notes` and `diff`, which is what `troupe onboard` shows. `tools` names the other
  tools by their files (`Troupe.Onboard.Start.tool/1`), and `skipped` holds what the
  sources passed over and any proposal the writer would refuse. `onboard.apply {workspace,
  ids | all}` writes the items named, or every `write` one (a new `AGENTS.md` only by its
  id: Decision 827's own question), answering `written` and `refused`; `onboard.decline
  {workspace, ids | all}` says no to them, `all` also remembering the no for this version.
  `memory.decline {workspace}` remembers a no to an outdated brief; the contract's
  placeholder name is the method's. `command_id` is optional on all three and makes a
  retry a no-op. The daemon's alone, `method_not_found` on a worker.
- **An id is what was shown.** A 16-character hash of the target, the path, the source and
  each other file it is made from with their hashes, and what the file holds now. Apply
  and decline plan again and act by id, so a file whose source or content changed since
  the person saw it names nothing and is refused with a sentence, never written over what
  was not shown. Not chosen: `target:path` as the id (a changed source would be written
  under a yes given to the old one).
- **Answered is stamped.** A call that answers every item its plan held records the
  workspace as onboarded under this build's rules (`Troupe.Onboard.stamp/1`), as `troupe
  onboard` does after a run that left nothing unanswered (827). A yes to all that leaves a
  new `AGENTS.md` to its own question is not answered yet; the question's answer is.
- **Scopes.** `onboard.plan` and `onboard.apply` take `admin`, what `config.set` and
  `memory.forget` take: the plan answers with what other tools' files hold at the path it
  is given, the person's own (`~/.claude/CLAUDE.md`, their config directory's) among them,
  so a `control` token would read files under the person's home; a yes writes into the
  repository and into the person's config directory. `onboard.decline` and
  `memory.decline` take `control`: they write only the person's own answer. The local
  clients hold all three: a Unix socket's connection, and a loopback TCP or WebSocket one
  with the discovery file's token (the terminal UI's link and the desktop app's), are
  given `observe`, `control` and `admin`.
- **The librarian writes the brief only.** `priv/agents/librarian.md` loses 827's
  onboarding pass and `onboard_write` from its tools; it starts from `README.md`, reads
  what onboarding wrote (already in its prompt as `AGENTS.md` and `.troupe/rules/`), and
  keeps out of the brief what the person did not let in. `onboard_write` stays a
  named-only tool (Decision 823) for a profile that names it. The survey's version stays
  1: for the same repository, onboarded or not, the brief it writes does not change; the
  onboarding was a step before it, now taken before it starts.
- **The order is the client's, because starting a session is (649).** The daemon says what
  is due; a client asks about onboarding and starts the librarian only once onboarding is
  answered, so it reads the onboarded `AGENTS.md`. The terminal UI's flow is TUI Decision
  154 (`clients/tui/lib/troupe/client/daemon/start.ex`); the desktop app's is its own.
- **The desktop app's flow** (`@troupe/client`'s `StartQuestions`, `views/Onboard.tsx`;
  #544, #550). The questions sit where the approval panel sits, not in a modal, the
  default (Onboard, Re-run) first and filled, and nothing takes the focus from the
  composer. Review is offered beside Re-run for an out-of-date onboarding too, since a
  re-run can replace files and the diff costs nothing to show. A new `AGENTS.md` is asked
  in its place in the plan under Review, or after the rest is written under Onboard, in
  827's words with its diff. The client keeps the first plan's items for the follow-up
  questions, because after the first write the plan answers nothing due. Every replay asks
  for the plan again and the plan decides, so a session opened after it was answered asks
  nothing; the harness's own line stays in the transcript for an older daemon, a replay or
  a team session. A team session runs no flow and asks the local daemon nothing, and a
  plan's refusal shows its sentence and asks nothing. The librarian starts only for a
  session this app just started (the first run's session counts), after onboarding is
  answered, on the same conditions as the terminal UI's (memory on, a git repository, a
  model, `memory_auto_refresh` for the automatic start); the outdated brief's Re-run sits
  behind the same conditions.
- **Not here.** Onboarding by itself without asking; `onboard.apply` and
  `onboard.decline` refusing outside a repository (a client calls them only on a plan's
  items, and `troupe onboard` still runs anywhere it is asked to); the bench (slice 8).
- **Proof.** `Troupe.Gateway.OnboardTest` (the plan's `first`, items with ids, the same
  ids again, the brief `first`, nothing written; apply with `all` writing the rule and not
  the new `AGENTS.md`, then due `none`, then the `AGENTS.md` by its id and the version
  recorded; an unknown id refused; a changed source refused by id; decline with `all`
  remembered; `outdated` until declined and then recorded; `memory.decline`; a worker's
  machine refusing; the scopes, a `control` connection refused the plan): all eight failed
  on the chunk's tip with `method_not_found`. `Troupe.Onboard.NoticeTest` (`due`,
  `brief_due`, `counts` in the event; the event again at the next start until declined,
  first and outdated and the brief alike, where 827's test asserted the second start was
  quiet; nothing written in the state directory; `onboarding/2` and `brief/2` with their
  declines; a directory in no repository with a `.claude/` in it due nothing, traced
  handing no path under `.claude` to `:file`, and due once it is one),
  `Troupe.Onboard.LibrarianTest` (no `onboard_write`, no onboarding pass) and
  `Troupe.Tools.OnboardWriteTest` (the tool through a profile that names it; the
  librarian and `build` neither offered it nor let call it). The terminal UI's half is
  TUI Decision 154's proof.
