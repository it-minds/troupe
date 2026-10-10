---
number: 839
title: remember and the librarian write facts anchored on the files they were read from, with evidence Troupe takes from the session, and memory.get, memory.forget and the TUI's /memory show and forget them one by one
date: 2026-10-10
status: accepted
issue: 248
paths:
  - apps/troupe_core/lib/troupe/tools/remember.ex
  - apps/troupe_core/priv/agents/librarian.md
  - apps/troupe_core/lib/troupe/memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/mix/tasks/troupe.palette.ex
  - apps/troupe_core/test/troupe/tools/remember_facts_test.exs
  - apps/troupe_core/test/troupe/tools/librarian_facts_test.exs
  - apps/troupe_gateway/test/troupe/gateway/memory_facts_test.exs
  - clients/tui/test/troupe/memory_facts_tui_test.exs
symbols:
  - Troupe.Tools.Remember.run/2
  - Troupe.Memory.survey_version/0
  - Troupe.Client.Daemon.memory_page/1
gist: "remember: kind/claim/anchors; Troupe takes hash, seq, head, exit status; replaces re-anchors or drops; librarian no notes; survey 2; forget by id"
---

#248's writers and views, beside Decision 838's store (`Troupe.Memory.Facts`: the record,
the status computed when read, the prompt's core, `recall`, the generated `memory.md` and
the migration). On the chunk's tip `remember` took only `section` and `text` and wrote
prose into `.troupe/memory.md`: called with `kind`, `claim` and `anchors` it answered
`missing required argument "section"` and wrote nothing, so nothing could write a fact
with an anchor, and the librarian could only replace sections wholesale.

**`remember` writes facts.** It takes `kind` (`command`, `convention`, `overview`,
`layout`, `negative`, `note`), `claim`, `anchors` (workspace-relative paths) and an
optional `scope` glob, and writes through `Facts.put/3`. What makes the fact evidence is
Troupe's, never the model's: the store hashes each anchor as it writes, and `remember`
gives it the session, the seq of the `tool_call_started` that began this call (read from
the session's own log), who wrote it (`librarian` for the librarian, otherwise
`agent:<profile>`) and, for a `command` fact, the exit status of the session's latest run
of a command the claim names. A command is named when it is the claim, or one of the
claim's code spans, word for word (whitespace aside); a looser match (a substring) would
give `mix test`'s status to a claim about `mix test apps/x`. A run its timeout killed has
no exit status (Decision 837), and neither has a command the session never ran.

**Anchors are held to the workspace.** Each is resolved as the file tools resolve a read
(`Workspace.resolve/3`): a path out of the workspace, a link out of it, a directory or a
file that is not there is refused by name, before the store holds them to its own edge
(838: not in `.git`, not memory's own files, at most eight, none over 10 MiB). Not
`resolve_readable/3`: a read root would let a fact carry the hash of a file outside the
repository, and a hash is an oracle for what a file holds. An anchor the agent did not
read, edit or write in this session is allowed (it may know a manifest without reading it
again) and the answer says so, so the model can read it before it trusts the anchor.

**`replaces` re-verifies.** With a claim, the new fact is written and the one it names is
dropped once it is; alone, it drops that fact. The same kind and claim written again is
the same fact to the store (838), its id kept and its anchors and evidence this call's,
and is not then dropped. That is how a fact that may no longer be true is re-anchored,
corrected or dropped. A person's fact (`by: person`, a hand edit read back)
is theirs: `remember` neither replaces nor drops it, and only `memory.forget` removes it.
`:auto` stays (Decision 649, TUI Decision 55): the paths a model names are only read, to
hash them, inside the workspace, and the store is the one file written.

**The librarian writes no notes.** Asked for one, `remember` refuses it by the agent's
name: a note is what an agent learned working here, and a survey learns commands,
conventions, an overview and a layout. Enforced, not only asked, because the prompt asked
before and a cheap model does not always listen.

**The older form keeps working for this release.** `section` and `text`, from an older
prompt or a bundle's agent written before facts, map onto facts: `note` is a `note` fact;
`overview`, `layout`, `commands` and `conventions` are a fact of the matching kind per
bullet (a continuation line kept with its bullet; text with no bullets is one fact),
unanchored, and replace what the same writer wrote of that kind the old way before, so a
librarian from an older bundle rewriting its sections each run does not pile up copies,
and nothing anchored or a person's is touched. The answer says it is the older form. Both
arguments stay in the schema, marked as the older form, so a provider that holds a call to
its schema does not refuse an old call. Remove them in the release after this one.

**The librarian.** Its tools gain `recall`. Its prompt starts with `recall` and no
arguments, re-reads the anchors of every `moved` or `missing` fact and of every `migrated`
one, and re-anchors, corrects or drops each with `replaces`; then surveys as before and
writes `command` facts anchored on the manifest it read them in, `convention` facts on the
file a convention is stated or shown in, and `overview` and `layout` facts for `recall`.
`Troupe.Memory.survey_version/0` is 2, so every brief written before facts is `outdated`
and the start asks to rewrite it once (Decision 835).

**The protocol (additive to v1).** `memory.get` gains `facts` (every fact as the store
reads it, with `status`) and `generated: true` (the brief's `text` and `sections` are the
facts' view); `memory.forget` takes an optional `id`, forgetting that fact alone and
answering `{"forgotten": true, "id"}`, `not_found` for an id no fact has, and without one
deletes the whole brief as before. The shapes are in PROTOCOL.md, for the desktop app's
view (AA26) as for the TUI's.

**The TUI's `/memory`.** Alone it opens a page: the facts kind by kind (commands,
conventions, what does not work, overview, layout, notes), "may no longer be true" beside
each `moved` or `missing` one, where the selected fact came from beside the list (status,
claim, scope, anchors with their hash, who wrote it, session and event, HEAD, exit status,
written and verified), `x` forgetting it, `r` reading it again. `refresh` and `forget`
stay the notice line's. A daemon from before facts, which answers no `facts`, and a brief
that is off leave `/memory` the line it was. "May no longer be true" is drawn in a role of
its own, `:stale` (`status.offline.fg`, the sixteen colours' yellow), not in the reserved
colour: TUI Decision 149 keeps that for a person being needed, and a fact whose anchor
moved needs the librarian, not the person.

**Not here.** The store, the status, the prompt's core, `recall` and the generated view
(838); the desktop app's view (AA26); a person's forget by id from the command line; facts
derived from the log (#248's Option 3); symbol anchors (#36).

**Proof.** `Troupe.Tools.RememberFactsTest` (a fact anchored on a file the agent read,
with the call's seq, HEAD and `agent:build`; an unread anchor noted; a command fact
carrying its run's exit status and one never run carrying none; anchors out of the
workspace, linked out, missing or a directory refused; `replaces` re-anchoring a moved
fact and dropping one; a person's fact neither replaced nor dropped; the librarian's note
refused; the older form's note and sections, a section replacing what it wrote before and
nothing anchored; survey 2 making a survey-1 brief `outdated`), which failed on the tip;
`Troupe.Tools.LibrarianFactsTest` (the prompt; a librarian run with a moved and a missing
fact re-anchoring one and dropping the other, its note refused);
`Troupe.Onboard.LibrarianTest`; `Troupe.Gateway.MemoryFactsTest` (`facts` with status,
`moved` and `missing` read at once, forget by id, `not_found`, the whole brief without);
the TUI's `Troupe.MemoryFactsTUITest` (the page by kind, the evidence, `:stale` and never
the reserved colour, `x`, no facts, a daemon with none).
