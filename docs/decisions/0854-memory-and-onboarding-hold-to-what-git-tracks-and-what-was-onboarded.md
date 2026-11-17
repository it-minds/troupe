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
  - apps/troupe_core/lib/troupe/onboard/source.ex
  - apps/troupe_core/lib/troupe/onboard/start.ex
symbols:
  - Troupe.Memory.Facts.list/2
  - Troupe.Instructions.glob?/1
  - Troupe.Onboard.onboarded_into/1
  - Troupe.Onboard.Instructions.found?/1
  - Troupe.Config.OpenCode.provider_names/0
  - Troupe.Protocol.Endpoint.default/0
gist: "Read-back anchors git doesn't track are missing, never hashed (cache: index size+mtime); memory.get is control + model; said-already counts unchanged"
---

- **The read path holds an anchor to what git tracks, as the write does.** Decision 839
  refused an ignored or untracked anchor when a fact was written and left the same check
  on the read path as not done: an anchor read back from a committed `facts.jsonl` (a
  `.env`) was hashed at every prompt, and read `current` when the committed hash matched.
  Now, in a repository, an anchor git does not track is `missing` and its file is never
  read. Where the index cannot be found nothing is cached and git is asked each time;
  where git cannot answer, the anchor is `missing`, never guessed.
- **A scope is a glob.** One word of at most 200 characters, not absolute, not `~`, not
  through `..`, with `/` between directories and its braces closed
  (`Troupe.Instructions.glob?/1`, the one reader `recall` matches it with). A sentence
  ("all Elixir files") is refused with what a glob looks like; nothing else is judged.
- **The old form is gone.** `remember`'s `section` and `text`, kept for one release by
  Decision 839, are refused with a sentence naming `kind`, `claim` and `anchors` and an
  example, so a bundle's agent written before facts is told what to call and writes
  nothing.
- **`memory.get` takes `control`.** It answers the brief at whatever path it is given, and
  a read there may migrate an old brief or read a person's edit back into facts, which
  writes. Chosen over answering an `observe`-only connection for a workspace one of its
  sessions has open: the dispatch does not know a connection's subscriptions, every local
  client holds `control` (a Unix socket's connection, and a loopback one with the
  discovery file's token), and a worker refuses `memory.get` to a session's token anyway.
- **`onboard.apply` and `onboard.decline` refuse outside a git repository**, where the
  plan is due nothing (Decision 835 left them acting there): `invalid_params` with a
  sentence, and nothing written or remembered. `troupe onboard` still runs wherever it is
  asked to.
- **A glob in opencode's `instructions` is held to the walk.** What `Path.wildcard/1`
  matches for an entry with `*`, `?`, `[` or `{` loses every path `.gitignore` hides (the
  path or a directory above it) and everything under `node_modules`, so `**/*.md` proposes
  the repository's Markdown, not its dependencies'. An entry that matches only such files
  is skipped saying so. A path named outright is taken as opencode takes it, ignored or
  not.
- **`setup.get` reads no key to name opencode's providers.** `Troupe.Setup.detect/0` read
  opencode's `auth.json`, which holds keys, and each `{file:}` a provider's options name,
  only to list the providers' names. It now reads the names from opencode's config alone
  (`Troupe.Config.OpenCode.provider_names/0`): `auth.json` is not read at all, since the
  names come from the config's `provider` map and `auth.json` only keys them.

**What this supersedes.** Of Decision 839: the older `remember` form kept for one release,
and "Not done" for the read path. Of Decision 835: apply and decline acting outside a
repository. Of Decision 827: `found?/1` as a look at the root only, and a repository whose
only other-tool file is nested not being announced.
