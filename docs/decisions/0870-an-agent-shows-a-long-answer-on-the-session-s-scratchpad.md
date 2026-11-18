---
number: 870
title: "An agent shows a long answer on the session's scratchpad with `show`: a named document beside the session's log, addressed as `scratch:/<name>`, replaced under the same name, each write a durable `scratch_updated`; `scratch.list` folds them and `fs.read` reads one; the scratchpad is display only, so nothing in the conversation is replaced"
date: 2026-10-11
status: accepted
issue: 472
paths:
  - apps/troupe_core/lib/troupe/scratch.ex
  - apps/troupe_core/lib/troupe/tools/show.ex
  - apps/troupe_core/lib/troupe/mounts.ex
symbols:
  - Troupe.Scratch
  - Troupe.Tools.Show
gist: "show writes scratch:/<name> beside the log, never the workspace; offered on every call; scratch_updated per write; list is a fold; display only, nothing replaced"
---

The maintainer decided on 2026-10-11 that in this release the scratchpad is display only:
a `show` call stays in the log as it was written, and nothing replaces an old document
with a pointer, so the prompt prefix stays the same for the whole session (Decisions 863
and 867). Saving tokens by putting pointers in place of old documents is for compaction,
where the prefix changes anyway; a follow-up issue carries it.

**What there is.**

- **The tool, `show`** (the issue's working name, kept: a verb, like the other tools, and
  what it does from the person's side). `name`, `title`, `content` and an optional `kind`,
  one of `markdown` (the default), `mermaid`, `json`, `csv` and `text`. It writes or
  replaces the document of that name; calling it again under the same name is a new
  version, not a second document. `:auto`: it writes nothing but the session's own
  scratchpad. Its result tells the model the path and the version, and to reply in a few
  sentences that name the document without repeating it.
- **The name** is a file name, lowered: letters, digits, `.`, `-` and `_`, starting with a
  letter or digit, at most 64. A separator, `..` and a control character are refused each
  in a sentence of its own, and so is a name Windows keeps for a device (`nul.md`). Lowered
  because Windows and macOS fold case, where `Plan.md` and `plan.md` would be one file and
  two documents.
- **The listing, `scratch.list`** (`observe`): the latest event of each name, in the order
  each was first shown, with `updated_at`. A fold over the log, so a running and a dormant
  session answer it alike and a client that attaches late or replays has the same from the
  events. Reading stays on `fs.read`, the one read path: `scratch:/<name>` resolves there.
- **The caps**, `scratch_max_bytes` (262,144) and `scratch_max_documents` (50), schema keys
  any layer may set. Past either, `show` refuses with a sentence that says what to do:
  show a shorter one or split it; replace a document under its name or answer in the chat.

**Where the documents are, and why not `session:/scratch`.** The issue put them under
`session:/`, read as "private, on the pod's volume". On a laptop and on a pod alike,
`session:/` is the checkout the agent works in. There a document would be a file in the
person's repository, which `git add -A` commits; two sessions in one checkout would write
over each other's `plan.md`; and an erasure, which deletes the session's directory, would
leave it behind. The issue's own boundaries say the opposite: the scratchpad is not the
workspace, erasure and private sessions cover it, and nothing outlives the session. So the
documents are in the session's own directory, beside its log and blobs
(`<state>/sessions/<workspace>/<id>/scratch/`), and addressed as `scratch:/<name>`, a mount
prefix of their own that `Troupe.Mounts.resolve/3` holds to that directory as it holds
every other path. The entry is not in the session's table: `show` resolves against a table
with only it, read-write, and a client's `fs.read` against the session's table with it
first and read-only, so `fs.upload` cannot put a document there that no event announced,
and the file tools and the sandbox never see it. What follows from where it is:

- an erasure deletes the documents with the log;
- a private session's documents stay on the device with its log, and what the sealer
  seals of them is the event, without the words, and the call that held them, as it
  seals every answer;
- a fork (`Troupe.fork_session/2`) carries each document its history lists, copied while
  the parent's copy is still the version the fork's log names; one the parent replaced
  since stays behind, and reading it is `not_found` rather than words the fork never saw;
- a session restored on another device or pod lists what its log says, and reads a
  document only where it was written, as a session's blobs are.

**On every call, every model.** `show` is a built-in, offered to an agent with every tool
from its first call and to `plan`, which names it, and gated by nothing: not the turn's
calls, not the model, not a loop. The tools are the front of every prompt, and a tool that
came and went would change it (Decision 867). Its definition is short for the same reason.

The turn costs more, about 30% a run: one more model call, which carries the document as
the call's arguments, and a short reply on top of the plan. That is the display-only
decision's price, and the saving is compaction's to make.
