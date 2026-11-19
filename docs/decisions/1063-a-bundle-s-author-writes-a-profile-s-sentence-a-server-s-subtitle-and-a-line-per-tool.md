---
number: 1063
title: "A bundle's author writes a profile's sentence, each server's subtitle and a line per tool (`about`, schema 1 still), checked at publish against the server's allowlist and passed through by profile.get for the desktop page"
date: 2026-11-19
status: accepted
issue: 1122
paths:
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/bundles/effective.ex
  - clients/gui/packages/client/src/profile.ts
  - clients/gui/apps/desktop/src/views/Profiles.tsx
symbols:
  - Troupe.Protocol.Bundle.validate/2
gist: "Bundle key about: top {summary} <=200 chars, per server {summary, tools: {name: line}} <=120 each, tool names in the allowlist (any for all); unknown keys refused; profile.get passes about through; page's sentence is about.summary else the primary's description"
---

Issue #1122. The profile page's sentence was its primary agent's description and its
tools were bare names (Decision 1060): nothing in a bundle let its author say what a
profile is for or what a tool does in a reader's words.

**The key.** A schema 1 document may carry `about: {summary}` at its top and
`about: {summary, tools: {<tool>: <line>}}` on an MCP server. Optional and additive, so the
schema stays 1. Checked wherever a document is validated: the sentence at most 200
characters, a subtitle and each line at most 120, none blank; a key inside `about` other
than those is refused, as an unknown top-level key is; and a tool `about.tools` names must
be on the server's `tools`, or any where it is `all`, refused naming the server and the
tool, since a line for a tool a session never has describes something absent.

**For readers only.** `profile.get` passes it through from the channel's current bundle,
`about` on the answer and on each `tools.mcp[]`, `null` where unsaid (extending Decision
969: still the plane's reading of the bundle in effect). No session, worker config or
prompt gets it. The desktop page leads with `about.summary`, else the primary's
description, and a server card shows its subtitle and each tool's line with the tool's name
in a small tail and as its title; a profile without `about` reads as it did. A composed
bundle (Decision 910) takes the nearest layer's top-level `about`; a server's rides with
its entry. The preview diffs it as any other field: a server's under its entry, the top
one whole.

## Not chosen

- **A description on the agent or the server's own MCP metadata.** An agent's description
  is what a model is told; a server's tool descriptions are written for a model and change
  with the server. Neither is the author's sentence for a person.
- **A schema 2.** Every reader of schema 1 would have to learn a second schema for an
  optional key no worker acts on.
- **Accepting lines for tools off the allowlist.** They would describe tools a session
  never has, which is the page saying something that is not there.

## What breaks if undone

The page falls back to the agents' descriptions and bare names. A worker from before this
refuses a document with a top-level `about` (unknown key), so an author says it once the
pods run this release; a server's `about` an older worker ignores.
