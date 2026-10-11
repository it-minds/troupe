---
number: 870
title: "An agent shows a long answer on the session's scratchpad with `show`: a named document beside the session's log, addressed as `scratch:/<name>`, replaced under the same name, each write a durable `scratch_updated`; `scratch.list` folds them and `fs.read` reads one; the scratchpad is display only, so nothing in the conversation is replaced"
date: 2026-10-11
status: accepted
issue: 472
paths:
  - apps/troupe_core/lib/troupe/scratch.ex
  - apps/troupe_core/lib/troupe/tools/show.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/mounts.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_core/priv/agents/build.md
  - apps/troupe_core/priv/agents/plan.md
  - apps/troupe_core/priv/bench/budgets.json
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_core/test/troupe/tools/show_test.exs
  - apps/troupe_gateway/test/troupe/gateway/scratch_test.exs
  - clients/gui/packages/client/src/scratch.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - docs/user/README.md
  - PROTOCOL.md
symbols:
  - Troupe.Scratch
  - Troupe.Tools.Show
gist: "show writes scratch:/<name> beside the log, never the workspace; offered on every call; scratch_updated per write; list is a fold; display only, nothing replaced"
---

Issue #472. A long answer, a plan or a report or a table, had one place to go: the
transcript, as assistant text, where it scrolls away and can only be revised by printing
it again. The maintainer decided on 2026-10-11 that in this release the scratchpad is
display only: a `show` call stays in the log as it was written, and nothing replaces an
old document with a pointer, so the prompt prefix stays the same for the whole session
(Decisions 863 and 867). Saving tokens by putting pointers in place of old documents is
for compaction, where the prefix changes anyway; a follow-up issue carries it.

**What there is.**

- **The tool, `show`** (the issue's working name, kept: a verb, like the other tools, and
  what it does from the person's side). `name`, `title`, `content` and an optional `kind`,
  one of `markdown` (the default), `mermaid`, `json`, `csv` and `text`. It writes or
  replaces the document of that name; calling it again under the same name is a new
  version, not a second document. `:auto`: it writes nothing but the session's own
  scratchpad. Its result tells the model the path and the version and to keep the reply
  short and name the document.
- **The name** is a file name, lowered: letters, digits, `.`, `-` and `_`, starting with a
  letter or digit, at most 64. A separator, `..` and a control character are refused each
  in a sentence of its own, and so is a name Windows keeps for a device (`nul.md`). Lowered
  because Windows and macOS fold case, where `Plan.md` and `plan.md` would be one file and
  two documents.
- **The event, `scratch_updated`**, durable, under the agent that called: `name`, `path`
  (`scratch:/<name>`), `kind`, `title`, `size`, `hash` (`sha256:…`, what `fs.read`
  answers), `version` (the writes of that name in the session, from 1) and `call_id`, the
  `show` call, so a client puts its card where the call was. Never the words: they are in
  the call's arguments already, as any answer's are.
- **The listing, `scratch.list`** (`observe`): the latest event of each name, in the order
  each was first shown, with `updated_at`. A fold over the log, so a running and a dormant
  session answer it alike and a client that attaches late or replays has the same from the
  events. Reading stays on `fs.read`, the one read path: `scratch:/<name>` resolves there.
- **The caps**, `scratch_max_bytes` (262,144) and `scratch_max_documents` (50), schema keys
  any layer may set. Past either, `show` refuses with a sentence that says what to do:
  show a shorter one or split it; replace a document under its name or answer in the chat.
- **The words.** The tool's description says when: a plan, report, comparison, Mermaid
  diagram or table a person will read, instead of a long answer in the chat, which then
  stays short and names it. `build.md` says it in one sentence, and `plan.md`, which now
  names the tool, for a plan longer than a few paragraphs.

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

**What it costs offline.** The offline bench's `tool_calls` turn on `build`: tool
definitions 14,174 bytes against 13,640 (534 more, the new tool), the system prompt 1,548
against 1,431 (117, `build.md`'s sentence), the first prompt 15,854 against 15,203, the
largest 31,351, and 184,128 of the stand-in's tokens over the thirty-one calls against
179,075 (2.8% more). The budgets move with it: 1,600, 14,300, 15,950, 31,500 and 185,000.
On a provider that caches, the definition is read from the cache after the first call.

**The desktop app.** A card where the call was, which opens a panel beside the
conversation with a tab for each document, read with `fs.read` when a tab opens and again
for a newer version; Markdown through the app's own renderer, the other kinds as written.
The real viewer is #61's, and publishing one is #62's.

**Proof.** `Troupe.Tools.ShowTest`: offered on every call of `build` on two models and of
`plan`; two calls under one name log versions 1 and 2, write beside the log and not in the
checkout, and list as one document; the order of a listing; each refused name and kind
writes nothing; both caps refuse in words; a dormant session lists, an erasure takes them;
a private session's event holds no words; a fork carries them; the live bench's plan
without the scratchpad has neither the tool nor its words. `Troupe.Gateway.ScratchTest`:
`scratch.list` and `fs.read` agree on the hash, for a running and a dormant session; a
replay holds every version; `fs.upload` to `scratch:/` and a path out of it are refused.
On the chunk's tip the first was `[false, false, false]` for every call and the second
`method_not_found`.
