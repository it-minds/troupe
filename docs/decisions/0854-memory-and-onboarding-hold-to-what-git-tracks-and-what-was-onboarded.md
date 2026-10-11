---
number: 854
title: A fact's anchor is held to what git tracks when it is read back too, cached by the index; remember's old form is gone; memory.get takes control and says whether a model can be asked; onboarding outside a repository is refused at a start; a file onboarding brought in says where it went, is found below the root, and counts as unchanged
date: 2026-10-11
status: accepted
issue: 248
supersedes: [827, 835, 839]
paths:
  - apps/troupe_core/lib/troupe/memory/facts.ex
  - apps/troupe_core/lib/troupe/memory/facts/store.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
  - apps/troupe_core/lib/troupe/tools/remember.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/onboard.ex
  - apps/troupe_core/lib/troupe/onboard/instructions.ex
  - apps/troupe_core/lib/troupe/onboard/source.ex
  - apps/troupe_core/lib/troupe/onboard/start.ex
  - apps/troupe_core/lib/troupe/config/open_code.ex
  - apps/troupe_core/lib/troupe/setup.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/endpoint.ex
  - PROTOCOL.md
  - mix.lock
  - apps/troupe_core/test/troupe/memory/facts_tracked_test.exs
  - apps/troupe_core/test/troupe/onboard/leftovers_test.exs
  - apps/troupe_gateway/test/troupe/gateway/memory_scope_test.exs
symbols:
  - Troupe.Memory.Facts.list/2
  - Troupe.Instructions.glob?/1
  - Troupe.Onboard.onboarded_into/1
  - Troupe.Onboard.Instructions.found?/1
  - Troupe.Config.OpenCode.provider_names/0
  - Troupe.Protocol.Endpoint.default/0
gist: "Read-back anchors git doesn't track are missing, never hashed (cache: index size+mtime); memory.get is control + model; said-already counts unchanged"
---

The memory and onboarding leftovers of #248 and #516 (D110, D111 and D102), and two small
fixes. Each was reproduced on the chunk's tip by a test that failed there
(`Troupe.Memory.FactsTrackedTest`, `Troupe.Onboard.LeftoversTest`,
`Troupe.Gateway.MemoryScopeTest`, and new cases in `Troupe.SetupTest`,
`Troupe.Tools.RememberFactsTest` and `Troupe.Daemon.CLITest`).

**Memory (D111).**

- **The read path holds an anchor to what git tracks, as the write does.** Decision 839
  refused an ignored or untracked anchor when a fact was written and left the same check on
  the read path as not done: an anchor read back from a committed `facts.jsonl` (a `.env`)
  was hashed at every prompt, and read `current` when the committed hash matched. Now, in
  a repository, an anchor git does not track is `missing` and its file is never read. Its
  `changed_at` is the file's own mtime, so a brief a librarian has stamped since does not
  count it as a new change at every start. **Cached by the index, not by the anchor:**
  whether a path is tracked changes when the index does (`git add`, `rm --cached`, a
  commit, a checkout), never when the file's bytes do, so the answer is kept beside the
  hashes keyed by the checkout or worktree and the path, against the size and mtime of the
  index git lists from (`.git/index`, or the one a worktree's `.git` file names), and is
  trusted only after the second the index was last written, as a hash is (Decision 838).
  The paths not answered for the index as it is are asked of git together, one `git
  ls-files --cached` per two hundred, so a prompt makes no git call while the index stands
  still and one after it moves, however many facts there are. Where the index cannot be
  found nothing is cached and git is asked each time; where git cannot answer, the anchor
  is `missing`, never guessed.
- **On Windows the committed name, whatever the case typed.** git's pathspecs compare case
  and Windows' file names do not, so `MIX.EXS` was refused as untracked. Where the platform
  compares paths without case the listing is asked with `:(literal,icase)` and the anchor
  is stored by the name git commits, so a fact reads the same on every checkout.
- **A scope is a glob.** One word of at most 200 characters, not absolute, not `~`, not
  through `..`, with `/` between directories and its braces closed
  (`Troupe.Instructions.glob?/1`, the one reader `recall` matches it with). A sentence ("all
  Elixir files") is refused with what a glob looks like; nothing else is judged.
- **The old form is gone.** `remember`'s `section` and `text`, kept for one release by
  Decision 839, are refused with a sentence naming `kind`, `claim` and `anchors` and an
  example, so a bundle's agent written before facts is told what to call and writes
  nothing. `Troupe.Session.Memory.note/3` and `put_section/4`, which no code called, go, and
  with them `Troupe.Memory.Facts.replace/4` and its store message, which only
  `put_section/4` used. A test that wants a built brief writes a fact and stamps it with
  `Troupe.Session.Memory.checked/1`, which is what a librarian's run does.

**Memory and onboarding over the protocol (D110).**

- **`memory.get` takes `control`.** It answers the brief at whatever path it is given, and
  a read there may migrate an old brief or read a person's edit back into facts, which
  writes. Chosen over answering an `observe`-only connection for a workspace one of its
  sessions has open: the dispatch does not know a connection's subscriptions, every local
  client holds `control` (a Unix socket's connection, and a loopback one with the
  discovery file's token), and a worker refuses `memory.get` to a session's token anyway.
  What loses it is a read-only token (`troupe ctl token --scope observe`), which no client
  of the brief uses.
- **`memory.get` says whether a model can be asked**, under the workspace's own config:
  `model: {usable, reason}`, from `Troupe.Config.key_problem/1`, the check the terminal
  UI's start makes before it starts a librarian. `setup.get`'s `usable` is the machine's;
  the desktop app can now apply the workspace's (its start still reads `setup.get`: a
  follow-up of its own).
- **`onboard.apply` and `onboard.decline` refuse outside a git repository**, where the plan
  is due nothing (Decision 835 left them acting there): `invalid_params` with a sentence,
  and nothing written or remembered. `troupe onboard` still runs wherever it is asked to.

**Onboarding (D102).**

- **A file onboarding brought in says where it went.** The instruction files' loader listed
  every other tool's file as "not read: run troupe onboard", onboarded or not. When one is
  listed so, the loader reads where onboarding recorded its sources (the repository's
  `.troupe/onboarded.json` for an `AGENTS.md`, each rule's front matter for a rule,
  `Troupe.Onboard.onboarded_into/1`) and says "not read: onboarded into AGENTS.md" or the
  rule's file. The other tool's file itself is still not read (Decision 828), and nothing
  is hashed: a source that changed since is drift, which `troupe instructions check` says.
- **The first notice finds a nested file.** `found?/1` looked at the root by name only, so a
  repository whose only `CLAUDE.md` was in a directory was told nothing. Below the root it
  now asks git's own listing, tracked and untracked files that `.gitignore` does not hide,
  for the names a directory may hold (`CLAUDE.md`, `GEMINI.md`, a `.cursor/rules/*.mdc`),
  and keeps what the walk would enter: nothing under `node_modules`, nothing in a hidden
  directory but `.github` and `.cursor`, and git's listing has no nested repository's
  files. Chosen over the walk itself because `found?/1` runs at every start of a workspace
  not yet onboarded, and the walk stats every file of a large repository; one listing costs
  the same whatever its size. The plan that follows a find is the walk's, so a listing that
  finds more than the walk would proposes nothing more. Outside a repository nothing is
  due before `found?/1` is asked (Decision 835).
- **A second run counts what it brought in as unchanged.** A file whose every word is in
  the file it would go into is skipped "everything it says is in AGENTS.md already", which a
  second `troupe onboard` printed for every file it had onboarded, every run. A source now
  says which file says it all (`said_in`), and the plan counts the skip as unchanged when
  that file's recorded provenance names the source; a file that says nothing new to an
  `AGENTS.md` nothing onboarded it into is still listed, as on a first run.
- **A glob in opencode's `instructions` is held to the walk.** What `Path.wildcard/1`
  matches for an entry with `*`, `?`, `[` or `{` loses every path `.gitignore` hides (the
  path or a directory above it) and everything under `node_modules`, so `**/*.md` proposes
  the repository's Markdown, not its dependencies'. An entry that matches only such files is
  skipped saying so. A path named outright is taken as opencode takes it, ignored or not.
  `Path.wildcard/1` still descends into `node_modules` to find what it then drops.
- **`setup.get` reads no key to name opencode's providers.** `Troupe.Setup.detect/0` read
  opencode's `auth.json`, which holds keys, and each `{file:}` a provider's options name,
  only to list the providers' names. It now reads the names from opencode's config alone
  (`Troupe.Config.OpenCode.provider_names/0`): `auth.json` is not read at all, since the
  names come from the config's `provider` map and `auth.json` only keys them. The copy
  reads both when the person asks for it.

**Two small fixes.**

- **An empty `TROUPE_DAEMON_SOCKET` is unset** (`Troupe.Protocol.Endpoint.default/0`), as is
  one of spaces: the daemon took `""` for a socket's path and died with `listen_failed
  unix: eafnosupport` (D68).
- **`decimal` is 3.1.2**, the patch release that fixes `Decimal.round/3`'s unbounded
  allocation (EEF-CVE-2026-97853, GHSA-6c27-994x-c52f), and not 3.2.0, which changes what
  some operations signal and return. It ships in the plane's database client, not the
  daemon.

**What this supersedes.** Of Decision 839: the older `remember` form kept for one release,
and "Not done" for the read path. Of Decision 835: apply and decline acting outside a
repository. Of Decision 827: `found?/1` as a look at the root only, and a repository whose
only other-tool file is nested not being announced.

**Proof.** `Troupe.Memory.FactsTrackedTest` (an ignored `.env` and an untracked file read
back `missing` and absent from the hash cache, and `current` once added; six anchors asked
in one listing, none again while the index stands, one after it moves; a write refusing
both and storing `mix.exs`; on Windows `MIX.EXS` stored as `mix.exs`, elsewhere another
file; the scope's refusals and `remember`'s; the helpers gone),
`Troupe.Tools.RememberFactsTest` (a session's `remember` with `section` and `text` refused,
naming the new form, nothing written), `Troupe.Gateway.MemoryScopeTest` (`memory.get`
`control`, an `observe` connection refused and the brief there not migrated; `model` usable
with the fake and refused with an unset `{env:}` key; apply and decline refused outside a
repository, nothing written, and answered once it is one), `Troupe.Onboard.LeftoversTest`
(a `CLAUDE.md` and a Cursor rule saying where they went, a `GEMINI.md` not onboarded still
saying to run `troupe onboard`; a nested `CLAUDE.md` and a directory's rule found and due,
`node_modules`, an ignored and a hidden directory not; a second plan with nothing skipped
and four unchanged, a file said already elsewhere still named; `**/*.md` without
`node_modules` and ignored files, a named path kept), `Troupe.SetupTest` (opencode's
providers named with its config read and neither `auth.json` nor a `{file:}` key touched),
`Troupe.Daemon.CLITest` (an empty and a blank `TROUPE_DAEMON_SOCKET` giving the unset
endpoint, and the daemon started on it), `Troupe.GitTest` (the tracked check on the way in
and out running nothing the repository names), and the updated `Troupe.Onboard.InstructionsTest`
and the TUI's `Troupe.OnboardCLITest` (a second run's count). Each new test failed on the
chunk's tip.
