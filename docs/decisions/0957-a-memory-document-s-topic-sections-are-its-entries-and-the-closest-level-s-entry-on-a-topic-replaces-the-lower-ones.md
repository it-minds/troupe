---
number: 957
title: "A memory document's ## Topic sections are its entries, read by the plane off the text it keeps, each with who last changed it and in how many sessions it was used; on a topic two levels both have, the closest level's entry replaces the lower ones in the prompt and says so in one line, and what is in effect for a person in a team is one list, memory.in_effect; remember with level me writes under a topic, Notes by default; and the daemon sends memory.in_effect and admin.memory.get, preview and put on to the plane as its person"
date: 2026-10-27
status: accepted
issue: 55
paths:
  - apps/troupe_protocol/lib/troupe/protocol/memory/entries.ex
  - apps/troupe_protocol/lib/troupe/protocol/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory.ex
  - apps/troupe_plane/lib/troupe/plane/memory/in_effect.ex
  - apps/troupe_core/lib/troupe/instructions.ex
symbols:
  - Troupe.Protocol.Memory.Entries
  - Troupe.Plane.Memory.InEffect
  - Troupe.Plane.Memory.append_own/3
  - Troupe.Gateway.Memory.in_effect/1
  - Troupe.Gateway.Memory.admin/2
gist: "## Topic sections are entries, parsed from the kept text; closest level's entry per topic wins in prompt and memory.in_effect; remember takes topic"
---

#55, to the maintainer's design and decision of 2026-10-26 on #765 ("memory as entries"):
a level's memory is notes on topics, and where two levels have a note on one topic the
closer one is the note a session follows.

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

`remember` with `level: "me"` takes a `topic`, `Notes` where none is named, and the plane
adds `- <entry>` at the end of that topic's section (found as topics compare), making `##
<topic>` at the end of the document where there is none, never in place of a word
(`append_own/3`, `me.memory.put {append, topic}`, `session.memory.put {..., topic}`).
Sections under a date, which agents wrote before this, stay as they are. The host function
`Troupe.UserMemory` installs takes the topic as a third argument; one from before takes
the entry alone. The tool's schema gains `topic` as a bare string and its description
names it only where a host is installed, as `level`'s does.

## Every level the person may change, through the daemon

The daemon sends `memory.in_effect` and `admin.memory.get`, `admin.memory.preview` and
`admin.memory.put` on to the plane as its person, with the arguments the plane takes and
nothing else (`Troupe.Gateway.Memory.in_effect/1`, `admin/2`), all `control` as the
person's own memory's are: the text is theirs to read, and a put is a save. **The plane
decides who may**: a team admin their team's, a platform admin the organisation's and a
profile's, and anybody else is told the plane's own refusal with its code. A put asks for
the copy again, so the sessions running there read it from their next turn. All four are
refused to a client in Local only, as the rest of memory is (Decision 951).

**The organisation's name** is the plane's (`plane_name`, what the console's header shows),
answered as `organisation: {name}` in `me` (so in `initialize`'s `principal`), in `me.memory`
and in `memory.in_effect`, so a client says "Everyone at <name>". **Every team of the
person's** is a level, a team with no document among them: `me.memory {entries: true}` names
them (`teams`), and the daemon answers a team with none as an empty document.
