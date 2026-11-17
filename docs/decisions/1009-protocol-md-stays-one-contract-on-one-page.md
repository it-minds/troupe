---
number: 1009
title: PROTOCOL.md stays one contract on one page, the one hand-written file past 400 lines, until the schema can say what a field means
date: 2026-11-16
status: accepted
issue: 422
paths:
  - PROTOCOL.md
  - scripts/doc-size.exs
  - mkdocs.yml
gist: PROTOCOL.md is kept whole and exempt from the line; split or generate it only from a schema that carries the meaning, not field names
---

**What reading the file found.** That split needs the reference to be a copy of the
schema, and it is not.

- **The schema knows names and types, not meaning.** `protocol/schema/v1/` is 203
  documents and not one `description`: `user_shell` is ten properties, five required, each
  a type. Its row in the event table says what `ended`'s four values mean, that `output` is
  capped at `tool_output_limit` with the `read_output` marker, and what `agent: false` is.
  Of the 68 rows in the durable event table, 16 are only field names; the other 52 are the
  contract for that event, and a generated page would carry none of it.
- **Moving the prose by hand would cost what the rule is there to save.** The file says
  of itself that it is complete on its own, and a client author reads it end to end and
  searches it as one thing; the site publishes it as one page (`mkdocs.yml`, through the
  hook that serves root files at their paths). The code and the tests cite it 76 times in
  42 files, by section (`PROTOCOL.md §6` 21 times, `§10` ten, `§8` nine) and by anchor;
  `people_named_test.exs` reads the event table from the file; the Python conformance
  client is written against it. Split along its headings as Decision 940 splits other
  pages, every `§N` citation would point at a stub, and a reader would follow links
  across a dozen pages for what one search finds now.

**The decision.**

- **`PROTOCOL.md` stays one file and one page**, and it is the one hand-written Markdown
  file `scripts/doc-size.exs` does not hold to 400 lines, with the reason written beside
  the exemption. No other page gets an exemption of this kind; a generated file and
  `docs/history/` stay exempt as Decision 940 has them.
- **What may come out of it is what a schema can generate.** When
  `Troupe.Protocol.Schema` carries a description for a field (as JSON Schema's
  `description`, written into `protocol/schema/v1/` by `mix troupe.schema.gen`), the table
  row for that event or command can be generated from it, on a page under `docs/protocol/`
  with a check in CI beside `mix troupe.schema.diff`, and `PROTOCOL.md` links to it. That
  is a move of the meaning into the code, one event at a time, not a move of text between
  files; until it is done for a whole table, the table stays here.
- **It does not grow without care.** A new event is a row, a new command a heading and its
  paragraphs, as `docs/developer/conventions.md` says; history (when a field arrived, what
  a log written before a release lacks) stays where a client needs it to read an old log,
  and nowhere else.

**Not chosen.** A generated reference of field names and types under `docs/protocol/`
beside the whole file: it would add a page that says less than the JSON Schema already
committed, and shrink nothing. Splitting the file into a page per section: the cost above,
for a line count. Raising the limit for everyone: the rule holds for every other page.
