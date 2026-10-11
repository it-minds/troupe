---
number: 876
title: "The skills a turn's first call finds are held to the turn's end as its MCP tools are, a call to one that went is told so, and what that call held is written on its `llm_request` and folded, so an agent restarted in the middle of a turn offers what the turn began with"
date: 2026-10-12
status: accepted
issue: 617
supersedes: [871]
paths:
  - apps/troupe_core/lib/troupe/agent/hold.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/skills.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - protocol/schema/v1/events/llm_request.json
  - apps/troupe_core/test/troupe/agent/stable_tools_test.exs
  - apps/troupe_core/test/support/fake_openai.exs
  - docs/developer/prompt-prefix.md
  - PROTOCOL.md
symbols:
  - Troupe.Agent.Hold
  - Troupe.Skills.found/3
  - Troupe.Skills.offered/2
  - Troupe.Tool.Ctx
gist: "Skills taken with the MCP tools at a turn's first call, held to its end (a gone one errors); llm_request.turn_hold folded so a mid-turn restart keeps both"
---

Issue #617, the two changes to the tools Decision 871 left. On a model that binds its
thinking (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5, Decision 867), any change to the tools
or the system prompt makes every earlier thinking block stale, and an account that
enforces the binding refuses each later call once and gets it sent again without its
thinking (Decision 805).

- **A skill file added, removed or renamed.** The `skill` tool names every skill in its
  description and schema, and the system prompt lists them (Decision 863 keeps the skills
  there); both were read from disk on every model call. On the chunk's tip, a skill file
  written while a turn's first call ran was in the turn's second call, tool and prompt;
  one removed was gone from it, and a call to it was "There is no tool named skill".
- **An agent restarted in the middle of a turn.** `State.turn_tools` (871) was not folded,
  so a restarted agent took the MCP servers' and the person's clients' tools afresh: a
  person's tool offered while the turn ran was in the call after the restart.

Against the stand-in as Claude Sonnet 5.5 with `thinking_binding: error`, a three-call
turn in which a skill file was added, a person's tool offered and the agent killed during
its first call made five requests on the tip, two of them refused.

**What changed.**

- **The skills are held for the turn.** `Skills.found/3` is what the bundle and the disk
  hold before a profile picks: the bundle's skills the team is entitled to, and the
  person's own and the repository's that are read. The agent takes it with
  `Tools.mcp/1` as a turn's first model call begins (`State.turn_skills`, `Ctx.turn_skills`)
  and lets both go when the turn ends, is cancelled, or an input is taken. For the rest of
  the turn the `skill` tool and the system prompt's lines are made from it,
  `Skills.offered/2` picking for the profile in force at each call, so a profile switched
  in the middle of a turn still takes effect at the next call (Decision 841), as the MCP
  tools are held whole and filtered by the profile at each call. A skill that went in the
  meantime is still listed, and a call to it is an error result saying it went during the
  turn and was not read (`{:skill_gone, name}`); one that came is not listed until the next
  turn, and a call to it by name is `unknown_skill`, as one never listed is.
- **What a turn's first call held is in the log.** That call's `llm_request` carries
  `turn_hold` (`Troupe.Agent.Hold`): the tools as `name`, `description`, `schema` and
  `default_permission`, the skills as `bundle` and `local` lists of `name`, `description`,
  `layer` and `dir`, and the canonical JSON's `sha256:` digest of the two. When the hold is
  the one the agent last wrote whole (`State.hold_written`, folded), only the digest is
  written: a session whose tools stay put writes them once. The replay folds it back, and
  lets it go where the live agent did (`turn_ended` other than `waiting`, `cancelled`, a
  `user_input` that starts a turn), so an agent restarted in the middle of a turn offers
  the tools and skills the turn began with, and one restarted between turns takes them
  afresh. A tool comes back as a `Hold.Tool`, which is all an offer reads; a call goes to
  the tool as it is now, or is `tool_gone`, as when nothing restarted. A digest that names
  no hold written before it (a log cut short) leaves the next call to take them afresh.
- **The fold's witness** has `turn_hold`, the last hold's digest, present only once one
  was written, so every recorded fixture's hash stands.
- **The stand-in** records each `/v1/messages` request's tool definitions, without their
  cache marks, so a test compares the tools block itself.

**What this changes of Decision 871.** Its "not chosen" said the `skill` tool still
changed at the call after a skill file was added or removed, and `State.turn_tools` was
"not folded: a restart takes them afresh". Both now wait for the turn boundary. The rest of
871 stands: what comes or goes from outside the session is held for the turn, not the
session, and the task list's tools on a model that does not bind still come at the
eleventh call (793).

**What it costs.** On an account that enforces the binding, a skill added costs what an
MCP tool that comes costs (871): nothing in the turn it came in, and a refusal on every
later call until a compaction. A turn's first `llm_request` gains the hold's digest, 84
bytes as `{"digest":"sha256:..."}`, and the whole hold when it changed: with no MCP server
and no skill, 129 bytes; with a person's MCP servers, their tools' definitions, which the
request already sends the provider on every call. A pod reads its bundle's skills once a
turn whichever profile runs, where it read them on every call of a profile that lists
some.

**Not chosen.**

- **Writing the held tools by name and taking them from the servers again on a restart.**
  A tool that went during the turn has nothing to be offered from, and a server that came
  back with another description of the same name would send another tools block.
- **Writing the hold whole on every turn.** A person's MCP servers may list many tools of
  some kilobytes each; `llm_request` carries counts rather than the messages so that the
  log grows with the turns and not their square (Decision 769), and the digest keeps it so.
- **Keeping the hold in a process outside the agent**, the session's. It would outlive an
  agent's crash but not a daemon's, and an agent's state is a fold over its own events
  (`Troupe.Agent.State`).
- **Holding the skills for the session.** For 871's reason: a person who adds a skill
  expects it in the next turn.
- **Holding the skills a profile is offered** (`Skills.available/4`) rather than what was
  found. A profile switched in the middle of a turn would keep the old profile's skills to
  the turn's end, where its tools change at the next call (Decision 841).
- **`unknown_skill` for a skill that went.** "There is no skill named" contradicts the
  list the same tool's description gives.

**Proof.** `Troupe.Agent.StableToolsTest`: a skill file added during a turn's first call is
in neither the tools nor the system prompt of the turn's second call, and in both at the
next turn; one removed stays offered to the turn's end, a call to it is the error saying it
went, the turn ends normally, and the next turn has no skill tool; an agent killed during a
turn's first call, after a skill file was added and a person's tool offered, sends the
tools and system prompt the turn began with on the call after the restart, and both new at
the next turn; the same when the turn's hold was written by its digest, the first turn's
written whole, the second's by its digest and the third's whole again; an agent restarted
between turns takes both afresh; and the fold's witness has the hold's digest only where
one was written. Against the stand-in as Claude Sonnet 5.5 with `thinking_binding: error`:
that turn with a skill added, a tool offered and the agent restarted makes three requests,
none refused, with one tools block and one system prompt, and the next turn's first call is
refused once over the change. On the chunk's tip the first four and the stand-in's case
failed (the stand-in's turn made five requests); the case between turns passed. And the
installed daemon on scratch homes, against the stand-in served as Claude Sonnet 5.5 with
`error`: see the pull request.
