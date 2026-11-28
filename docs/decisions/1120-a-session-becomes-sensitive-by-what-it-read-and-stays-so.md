---
number: 1120
title: "A session becomes sensitive by a tool call its worker profile names, marked at the gate before the call runs and never cleared; from then on the profile's deny rules refuse at the same gate with a sentence, the offered tools unchanged; the plane stores, audits and refuses on its own side what it owns; sharing a sensitive session beyond its present readers is the profile's sharing rule"
date: 2026-11-28
status: accepted
issue: 1239
paths:
  - apps/troupe_protocol/lib/troupe/protocol/sensitive.ex
  - apps/troupe_core/lib/troupe/session/sensitive.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/config/permissions.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_plane/lib/troupe/plane/sessions/sensitive.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/extends.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
gist: "spec.sensitive {markedBy, deny, sharing}; mark in Tools.authorize before {:run}, one holder per tree, session_marked_sensitive, never cleared; deny = layer :sensitive above :profile; plane column + audit + activation; sharing allow|ask|deny"
---
Issue #1239, slice 1 (plane and harness). Per-tool rules (Decisions 907, 913) are the same
before a session reads medical records and after; this makes them differ, out of the prompt's reach.
**The profile says it.** `spec.sensitive.markedBy` and `.deny` are rules in the permission
grammar, no new syntax (`web_fetch` and `remember` are named whole, so `deny: [remember]`
refuses every level); `sharing` is `allow` < `ask` < `deny`. `markedBy` without `deny` is
refused. Along `extends` a child adds rules to both lists and may only tighten `sharing`.
**The mark is made at the gate, before the call runs.** `Tools.authorize/4` matches a call it
lets through against `markedBy` and, on a match, appends `session_marked_sensitive` through
`Troupe.Session.Sensitive` before answering `{:run, ...}`: one holder under the log, read by the
root and every subagent, folded back from the log, given the plane's mark at a wake. A call
a rule refuses read nothing and marks nothing. A task tool marked and then denied by a person
leaves the mark: the gate cannot know what a running call returns, so it marks early.
**Nothing clears it**: no function, event or method; `session.sensitive.set false` is refused.
A session spawned or forked from a sensitive one is marked as its parent at its creation.
**The refusal is the same gate's.** Once marked, `deny` joins the rules as the layer
`:sensitive` above `:profile`, read from the holder at the call in `authorize` and in
`run_task`, so a call issued before the mark is refused when it reaches its task. The tool
stays offered (Decision 871); the sentence says since when, by what and whose rule, and
`tool_call_completed` gains `refused: "sensitive"`. A person's `!` command obeys a sensitive
shell deny, as Decision 913's profile deny. The root is told in `<configuration>`.
**The plane, belt and braces.** `session.status` carries the mark; `sessions.sensitive_at`
and `sensitive_by` are written once and audited (`system:harness` with tool and rule, or the
person); every row says `sensitive` and every activation carries it. The plane refuses a
sensitive session's memory proposals (as a throwaway's, Decision 1110), its publication where
`deny` names `publish_artifact`, and the core proposes no trigger from one (Decision 1111).
`sharing` holds giving it to the team, invitations, grants, links, and moving or sharing its
artifacts: `deny` refuses naming the team that reads it; `ask` keeps a `session_share_requests`
row for a team administrator, whose yes applies it as the owner asked; a link cannot wait.
## Not chosen
- Taking tools off the list once marked: the list changes only at a turn's boundary (871).
- Marking after the call returns: the call's result reaches the model in the same step.
- A rule grammar of hosts or levels (`web_fetch(host)`, `remember(level)`): another syntax for
  every reader, the console's included, for one case each.
- Reusing the review rows: a review is of a run's outcome, not a share waiting to apply.
## If undone
A session that read what must not leave it can publish, fetch, push or propose it in the
same turn, and a mark the owner could clear is a mark the prompt can ask them to clear.
