---
number: 957
title: "A memory document's ## Topic sections are its entries, read by the plane off the text it keeps, each with who last changed it and in how many sessions it was used; on a topic two levels both have, the closest level's entry replaces the lower ones in the prompt and says so in one line, and what is in effect for a person in a team is one list, memory.in_effect; remember with level me writes under a topic, Notes by default; and the daemon sends memory.in_effect and admin.memory.get, preview and put on to the plane as its person"
date: 2026-10-27
status: accepted
issue: 55
paths:
  - apps/troupe_protocol/lib/troupe/protocol/memory/entries.ex
  - apps/troupe_protocol/lib/troupe/protocol/memory.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory/in_effect.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/admin/api.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/tools/remember.ex
  - apps/troupe_core/lib/troupe/user_memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/user_memory.ex
  - clients/gui/packages/client/src/entries.ts
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/src/artifacts.ts
  - clients/gui/apps/desktop/src/views/OwnMemory.tsx
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/Memory.tsx
  - clients/tui/lib/troupe/client/own_memory.ex
  - clients/tui/lib/troupe/ui/tui/memory_page.ex
  - clients/tui/lib/mix/tasks/troupe.xref.ex
  - PROTOCOL.md
  - docs/user/memory.md
  - docs/admin/console.md
symbols:
  - Troupe.Protocol.Memory.Entries
  - Troupe.Plane.Memory.InEffect
  - Troupe.Plane.Memory.append_own/3
  - Troupe.Gateway.Memory.in_effect/1
  - Troupe.Gateway.Memory.admin/2
gist: "## Topic sections are entries, parsed from the kept text; closest level's entry per topic wins in prompt and memory.in_effect; remember takes topic"
---

#55, to the maintainer's design and decision of 2026-10-26 on #765 ("memory as entries"): a
level's memory is notes on topics, and where two levels have a note on one topic the closer
one is the note a session follows. Decisions 922, 929, 943, 947 and 951 kept each level as
one Markdown document, read whole into every session in its scope, the organisation's first;
Decision 954 had the desktop app read them as entries in the client, and C45's terminal did
the same, each with a shim to go once the plane answered entries. This records how the plane
and the harness read entries, and what changed in what a session's prompt holds.

## Entries are a reading of the text

**The text stays what is kept.** Versions, the 8192-byte limit, conflicts over the version
edited, the audit and blame are the document's as before; nothing new is stored. An entry is
a `## <Topic>` section of the text, its topic the heading's words and its body the lines under
it, blank lines at the edges left off; text before the first heading is the entry called
*General*, with no heading. A `## ` line inside a fenced code block is the code's. The rule is
in the protocol app (`Troupe.Protocol.Memory.Entries`), because the plane that answers entries,
the harness that builds the prompt from them and the daemon that reads its copy offline must
read a document the same way.

**Topics compare by their words**, case and spacing aside (`key/1`): `## Tone`, `## tone` and
`##  TONE` are one topic.

**Answered, not stored.** `admin.memory.get` answers `entries` beside `text` for the version
shown, and the plane's `me.memory` answers them in each document and the person's own when
asked `entries: true` (the daemon asks it for a client; its five-minute poll does not, so a
poll costs no blame). Each entry has `version`, `by` and `at`, those of its newest line in the
document's blame (Decision 951), an agent's `session` and `agent`, and **`used`**: how many
sessions read a version of the document holding it since it came in, counted off
`memory_reads`. That is approximate and said so: the plane keeps one row per session, the
version its last turn read, and a week of a machine's, so a session whose turns all came
before the entry, or one silent for a week, is not counted. Not chosen: a history of reads,
which Decision 947 declined for "who is behind" and which this count does not need either.

**A save may be entries.** `me.memory.put` and `admin.memory.put` (and both previews) take
`entries` in place of `text`, `[{topic, body}]`, which the plane writes back as sections in
their order, each heading's text as given, one blank line between: one entry with no topic,
first only, is General, and a body holding a `## ` line is refused, since read back it would
be an entry of its own. *Forget* is a save without the section: a new version, the old text
kept as every version is. Nothing is soft-deleted.

## Closest wins per topic

**The rank.** Organisation 0; a team 1; a worker profile 2 and up along its chain, the one
that extends nothing first; the person's own closest (`Entries.rank/2`). Two documents of one
rank, the two teams a person's machine reads (Decision 922), replace neither of each other:
both stay, as they did. *General* is no topic: it is never replaced and replaces nothing, so
an organisation's opening words are not lost to a person who writes a line above their own
first heading.

**In the prompt** (`Troupe.Instructions`), on every topic two documents share, only the
closest's section is read; the lower ones' are left out of their documents, and the closest's
says, as a line under its heading, `<Topic>: this replaces the organisation's.` (or the team
`<name>`'s, the worker profile `<name>`'s, several joined by "and"), so the model knows there
was something else and that this one holds. A document none of whose sections is replaced and
which replaces nothing is read word for word, as before; one every section of which a closer
level replaced is listed but adds no block. The organisation's sections no closer level has
stay first, in their order, then the team's and the profile's, then the person's own section.
`instructions_loaded.memory` names, on each document some of whose sections were left out,
`replaced: [{topic, by: [{scope, name}]}]`, and `context.get`'s file the same list.

**This is the decision's point, plainly:** until now the organisation's memory came first and
was read whole in every session, the person's own after it (Decision 943, citing Decision
921's precedence of the organisation's instructions). That still holds for every topic only
the organisation has. On a topic the person also wrote about, **the person's entry wins and
the organisation's is not in the prompt**; likewise a team's over the organisation's, a
profile's over a team's. An administrator who needs a rule nobody can override keeps it under
a topic no one else uses, or in a profile's per-tool rules, which no memory changes; the
admin guide says so under Company memory. Not chosen: keeping both and leaving the model to
pick the narrower, which is what "the narrower wins" in the preamble had asked and what the
maintainer's design replaces with the model being told.

**One list, `memory.in_effect {team?, profile?}`** (any person, for themselves): the chain for
a new session of theirs in one of their teams (their first by name where none is named;
another team is `not_found`), on a profile they may use through it where one is named, as one
list of topics, a topic where it first comes in the chain's order and the closest level's
entry there, with `replaces: [{level, topic, body}]`, closest first. `levels` is the chain with
each level's version and count. The harness and the plane apply the same functions
(`Entries.resolve/1`, `Entries.in_effect/1`), so what the app shows is what the prompt takes.
The daemon's `me.memory.status` carries `in_effect` too, worked out from its copy as the
sessions there read it, for a client in Local only.

**The chain's order is the plane's.** `Troupe.Protocol.Memory.read/1` sorted the documents by
scope and then by name, which put a profile chain in alphabetical order and not the order
Decision 929 gave it; it now keeps the plane's order within a scope (teams by name, the chain
the one that extends nothing first), since which profile is closer now decides a topic.

## `remember` writes under a topic

`remember` with `level: "me"` takes a `topic`, `Notes` where none is named, and the plane adds
`- <entry>` at the end of that topic's section (found as topics compare), making `## <topic>`
at the end of the document where there is none, never in place of a word (`append_own/3`,
`me.memory.put {append, topic}`, `session.memory.put {..., topic}`). Sections under a date,
which agents wrote before this, stay as they are. The host function `Troupe.UserMemory`
installs takes the topic as a third argument; one from before takes the entry alone. The
tool's schema gains `topic` as a bare string and its description names it only where a host
is installed, as `level`'s does. Measured with the umbrella's `mix troupe.bench` (no host),
against 0.28.0's numbers in `budgets.json`: tool definitions 14787 to 14813 bytes, the first
prompt 16612 to 16638, the largest 32109 to 32135, the turn's input tokens 189998 to 190204,
the schema's 26 bytes on every call; every budget holds, none moves. A prompt reads the
replaces line only where a document has a topic a closer one has, which the bench's
scenarios have none of.

## Every level the person may change, through the daemon

The daemon sends `memory.in_effect` and `admin.memory.get`, `admin.memory.preview` and
`admin.memory.put` on to the plane as its person, with the arguments the plane takes and
nothing else (`Troupe.Gateway.Memory.in_effect/1`, `admin/2`), all `control` as the person's
own memory's are: the text is theirs to read, and a put is a save. **The plane decides who
may**: a team admin their team's, a platform admin the organisation's and a profile's, and
anybody else is told the plane's own refusal with its code. A put asks for the copy again, so
the sessions running there read it from their next turn. All four are refused to a client in
Local only, as the rest of memory is (Decision 951). The screens that use the admin methods
are the app's and the terminal's to draw; neither edits the organisation's levels yet.

**The organisation's name** is the plane's (`plane_name`, what the console's header shows),
answered as `organisation: {name}` in `me` (so in `initialize`'s `principal`), in `me.memory`
and in `memory.in_effect`, so a client says "Everyone at <name>". **Every team of the
person's** is a level, a team with no document among them: `me.memory {entries: true}` names
them (`teams`), and the daemon answers a team with none as an empty document.

## The clients read them

The desktop app's Memory view reads each level's entries from `me.memory` and *In effect for
you* from `memory.in_effect`, saves the person's own as entries, and shows who last changed
each entry, when and in how many sessions it was used at every level; the client's parsing and
in-effect (`packages/client/src/entries.ts`) go, leaving the types, the topic comparison its
clash warnings use and the side-by-side rows. The gallery's `scopeOf` and its second listing
go too: every plane row says its `scope` since Decision 953. The terminal's `/memory` reads the
same answers and saves entries; `Troupe.Client.MemoryEntries` goes. The terminal may call
`Troupe.Protocol.Memory.Entries` (`mix troupe.xref`'s list of the harness's doors): a pure
module of the protocol, as `Troupe.Protocol.Glob` is, for comparing topics and writing the
text a conflict shows beside the other version, never for working out what is in effect. The console's Company
memory keeps its document editor and gains only *Its entries*, a read-only list.

## Left

The app's and the terminal's screens for changing the organisation's and a team's levels over
`admin.memory.*` (since drawn, by role: `me.memory {entries: true}` answers `roles`, whether
the caller is a platform admin and the teams they administer, and a refusal of a level's save
says in `data.reason` who may change it); a fallback for a plane from before `memory.in_effect` (the daemon says it is
`unavailable`); rules inside memory; an agent writing above the person's level.

## Proof

- `apps/troupe_protocol/test/troupe/protocol/memory_entries_test.exs`: sections and General, a
  heading in a code block the code's, round trips with the heading kept, entries checked, keys,
  in effect with replaces closest first, a level's entries marked, two of one rank both kept.
- `apps/troupe_plane/test/troupe/plane/memory_entries_test.exs`: entries with who and when
  beside the text, as the version stood; entries saved and previewed and refused; role
  refusals; used counts; `me.memory {entries}` with every document's, the organisation's name
  and every team; `memory.in_effect` as one list, with a profile's chain, and refused for a
  team the person is not in or a profile they may not use. `user_memory_test.exs`: an entry at
  the end of its topic's section, a new section made, a dated one kept, a topic too long.
- `apps/troupe_core/test/troupe/instructions_prompt_test.exs`: an organisation's `Tone` and a
  person's `tone`, the person's read with its replaces line and the organisation's left out, a
  team's `Prices` replacing the organisation's, the organisation's other sections first, and
  `instructions_loaded.memory`'s `replaced`. `tools/remember_me_test.exs`: the topic reaching
  the host and named in the answer, `Notes` for none.
- `apps/troupe_gateway/test/troupe/gateway/plane_memory_test.exs`: `me.memory` with every
  document's entries read off a plane that sent none, an empty team level, `me.memory.put`
  with entries, `memory.in_effect` and `admin.memory.*` forwarded with exactly their
  arguments, the plane's `forbidden` and `not_found` kept; `remember` with a topic landing
  under it. `local_only_test.exs`: all four refused under Local only.
- `apps/troupe_worker/test/troupe/worker/user_memory_test.exs`: a pod's entry under `Notes`
  and under a named topic, over a real control link.
- `clients/gui/apps/desktop/test/own-memory.test.tsx`: in effect asked of the daemon for the
  team chosen, "Everyone at", who wrote each entry and how many sessions used it, saves sent
  as entries. `artifacts-gallery.test.tsx`: the tabs off the rows' `scope`.
  `apps/console/test/memory.test.tsx`: *Its entries*, read only.
- `clients/tui/test/troupe/memory_screen_test.exs`: `/memory` as before, now off the plane's
  entries and `memory.in_effect`.

The plane, core, gateway and worker tests above failed on the chunk's tip (`f4b7606e`) with
the parser alone in place: no `entries`, no `memory.in_effect`, no topic, no replaced section.
