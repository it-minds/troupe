---
number: 876
title: "The skills a turn's first call finds are held to the turn's end as its MCP tools are, a call to one that went is told so, and what that call held is written on its `llm_request` and folded, so an agent restarted in the middle of a turn offers what the turn began with"
date: 2026-10-12
status: accepted
issue: 617
supersedes: [871]
paths:
  - apps/troupe_core/lib/troupe/agent/hold.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/skills.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
symbols:
  - Troupe.Agent.Hold
  - Troupe.Skills.found/3
  - Troupe.Skills.offered/2
  - Troupe.Tool.Ctx
gist: "Skills taken with the MCP tools at a turn's first call, held to its end (a gone one errors); llm_request.turn_hold folded so a mid-turn restart keeps both"
---

On a model that binds its thinking (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5, Decision
867), any change to the tools or the system prompt makes every earlier thinking block
stale, and an account that enforces the binding refuses each later call once and gets it
sent again without its thinking (Decision 805).

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
- **What a turn's first call held is in the log.** When the hold is the one the agent last
  wrote whole (`State.hold_written`, folded), only the digest is written: a session whose
  tools stay put writes them once. The replay folds it back, and lets it go where the live
  agent did (`turn_ended` other than `waiting`, `cancelled`, a `user_input` that starts a
  turn), so an agent restarted in the middle of a turn offers the tools and skills the
  turn began with, and one restarted between turns takes them afresh.

**What this changes of Decision 871.** Its "not chosen" said the `skill` tool still
changed at the call after a skill file was added or removed, and `State.turn_tools` was
"not folded: a restart takes them afresh". Both now wait for the turn boundary. The rest of
871 stands: what comes or goes from outside the session is held for the turn, not the
session, and the task list's tools on a model that does not bind still come at the
eleventh call (793).

**What it costs.** On an account that enforces the binding, a skill added costs what an
MCP tool that comes costs (871): nothing in the turn it came in, and a refusal on every
later call until a compaction. A pod reads its bundle's skills once a turn whichever
profile runs, where it read them on every call of a profile that lists some.

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
