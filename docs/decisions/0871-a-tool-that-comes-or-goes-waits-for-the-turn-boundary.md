---
number: 871
title: "An MCP server's or a person's client's tools that come or go change the tools at the next turn, never in the middle of one, on every model; on a model that binds its thinking `goal_complete` is offered on every call of the root agent and refused outside a loop; and `binds_thinking` says a model binds when its name hides it"
date: 2026-10-11
status: accepted
issue: 606
supersedes: [679, 861]
paths:
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
symbols:
  - Troupe.Tools.mcp/1
  - Troupe.Config.binds_thinking?/2
  - Troupe.Tool.Ctx
gist: "MCP/client tools taken at a turn's first call, held to its end (a gone one errors); binding models always get goal_complete; binds_thinking for aliases"
---

Issue #606, the tools-block changes Decision 867 left, decided by the maintainer on
2026-10-11: an MCP tool that comes or goes waits for the turn boundary, on every model; a
call to a tool that went in the meantime gets a plain error result; and `goal_complete` is
offered on every turn of a binding model's session and refused, with a sentence, outside a
loop. On a model that binds its thinking (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5,
Decision 867), any change to the tools makes every earlier thinking block stale, and an
account that enforces the binding refuses each later call once and gets it sent again
without its thinking (Decision 805).

**What changed.**

- **MCP tools are held for the turn.** The agent takes them as a turn's first model call
  begins (`State.turn_tools`, emptied when the turn ends or an input is taken) and offers
  those for the rest of the turn (`Ctx.turn_tools`), as Decision 798 holds the instruction
  files. A tool that came in the meantime is offered from the next turn's first call. One
  that went stays in the tools until the turn ends, and a call to it is an error result
  saying it went during the turn and did not run (`{:tool_gone, name}`); the turn goes on.
  This is so on every model: what is offered never changes under a turn's reasoning, and
  on a model that caches by prefix the change costs its cache write at a boundary rather
  than in the middle of a turn.
- **`goal_complete` on a binding model.** Its root agent, the one a loop runs on, is offered
  it on every call, loop or not. Called on a turn that is not the loop's, it is refused
  with a sentence (`{:no_loop, name}`: no loop is running, so there is nothing for it to
  end; carry on with what was asked), and the turn goes on. The loop reads only a call that
  completed without error, so a refused one is no verdict. Its description says only a
  turn of a loop may call it. A subagent is not offered it: no loop runs on one, so its
  tools never change by it. On any other model Decision 679 stands: offered on the loop's
  turns alone. Its reason was that a verdict outside a loop means nothing, and on a model
  that does not bind, the change costs a cache write as a loop begins and another at the
  turn after it, as 793's change at the eleventh call costs one; 867 kept 793's gate there
  for the same reason.
- **`binds_thinking`** on a provider's `models:` entry, or on the provider for every model
  it serves, says a model binds (or with `false`, does not) where its name does not say.
  The agent decides once per call and hands the answer to the tools (`Ctx.binds_thinking`,
  which replaces 867's `Ctx.model`): 793's gate, `goal_complete` and the compaction's tail
  (867) all read it. It does not change whether an alias's thinking goes back (Decision
  805: with an effort set, or by name), which is when the binding matters at all.

**What this changes of earlier decisions.** Decision 679's "offered on the loop's turns and
no others" now holds on a model that does not bind. Decision 861's "the tool is off the
list before the next lookup, so the next model request does not offer it" now holds at the
next turn: the registration still goes before the next lookup, the tools the model is sent
keep it until the turn ends, and a call to it gets `tool_gone` rather than "There is no
tool named". The rest of both stands.

**What the change at the boundary costs on an enforced account.** The hold moves a tool
that comes or goes to the next turn's first call; it does not make it free. Every call
after it carries thinking made under the tools before, so each is refused once and sent
again without that thinking, for the rest of the session or until a compaction (805; D92
names what would end it: not sending the leading run of stale blocks). The hold saves the
refusals of the rest of the turn the tool came in, and none after.

**Not chosen.**

- **Hold the MCP tools for the session**, offering a new one only after a restart or a
  compaction. That would remove the cost above, but a person who signs in or offers their
  tools expects them in the next turn, and one whose tools left would have calls fail for
  the rest of the session. The maintainer chose the turn.
- **Hold every tool for the turn.** The task list's tools at the eleventh call (793) are a
  change within a turn on purpose, on a model that does not bind. Only the tools that come
  and go from outside the session are held. The `skill` tool, which names the skills read
  from disk on every call, still changes at the call after a skill file is added or
  removed; `prompt-prefix.md` lists it among what is left.
- **`goal_complete` on every model.** It would end the change at a loop's turns everywhere,
  for its definition (about 670 bytes as Anthropic's wire sends it) on every call of every
  session that never loops, to save the two cache writes a model which does not bind pays
  for a loop: at its first turn, and at the turn after its last.
- **Offering `goal_complete` to every agent on a binding model.** A subagent never runs a
  loop turn, so its tools do not change by it; offering it there would be a tool no call
  of it may use.
