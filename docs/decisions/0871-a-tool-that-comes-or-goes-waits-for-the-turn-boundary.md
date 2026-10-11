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
  - apps/troupe_core/lib/troupe/tools/goal_complete.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
  - apps/troupe_core/lib/troupe/bench/scenario.ex
  - apps/troupe_core/test/troupe/agent/stable_tools_test.exs
  - docs/developer/prompt-prefix.md
  - PROTOCOL.md
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
loop. On a model that binds its thinking (Claude Fable 5.1, Opus 5.5 and Sonnet 5.5, Decision
867), any change to the tools makes every earlier thinking block stale, and an account that
enforces the binding refuses each later call once and gets it sent again without its
thinking (Decision 805). Three changes were left:

- **`goal_complete`** was offered on a loop's turns and no others (Decision 679), so on the
  chunk's tip, against the stand-in, a `/loop` turn and a person's turn after it sent two
  sets of tools.
- **An MCP tool that comes or goes**: a server that comes back with another list, a sign-in
  that completes, a person's offered tools leaving (Decision 861). The tools were looked up
  on every model call, so the change reached the next call, in the middle of a turn: on
  the tip an MCP server started and a person's tool offered during a turn were in the
  turn's next call, and one that left was gone from it.
- **A gateway's alias that hides the model's name**: Decision 867 tells a binding model by
  name, so `gw/smart` for Sonnet 5.5, on Anthropic's wire with an effort set, kept 793's
  task-list gate. On the tip, against the stand-in, a twelve-call turn on it made 14
  requests, its eleventh and twelfth calls each refused once.

**What changed.**

- **MCP tools are held for the turn.** `Tools.mcp/1` is the tools that come and go: the
  pod's MCP servers', the session's own and those a person's client offers. The agent takes
  them as a turn's first model call begins (`State.turn_tools`, emptied when the turn ends
  or an input is taken) and offers those for the rest of the turn (`Ctx.turn_tools`), as
  Decision 798 holds the instruction files. A tool that came in the meantime is offered
  from the next turn's first call. One that went stays in the tools until the turn ends,
  and a call to it is an error result saying it went during the turn and did not run
  (`{:tool_gone, name}`); the turn goes on. This is so on every model: what is offered never changes under a turn's
  reasoning, and on a model that caches by prefix the change costs its cache write at a
  boundary rather than in the middle of a turn.
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
  The catalogue carries it too (`Catalog.binds_thinking`, from a listing entry's
  `binds_thinking`, kept in the cache file), for a gateway that says it in its own list;
  neither Anthropic's model list nor LiteLLM's says it today, so the setting is what works.
  `Config.binds_thinking?/2` reads the model's entry, then the provider's, then the
  listing, then the name (`Catalog.binds_thinking?/1`, Decision 867). The agent decides once
  per call and hands the answer to the tools (`Ctx.binds_thinking`, which replaces 867's
  `Ctx.model`): 793's gate, `goal_complete` and the compaction's tail (867) all read it. It
  does not change whether an alias's thinking goes back (Decision 805: with an effort set,
  or by name), which is when the binding matters at all.
- **`loop_turn`**, a live scenario run by name beside `long_turn`: a `/loop` turn of one
  iteration, which works a number out without a tool and writes it, then a person's turn
  that reads it back and writes the next. A scenario may now say a `loop` goal, which the
  live runner sets and loops towards once before it types the prompt.

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
names what would end it: not sending the leading run of stale blocks). Against the stand-in
as Claude Sonnet 5.5 with `thinking_binding: error`, three turns of three, two and one
calls with a person's tool offered while the first call ran (`StableToolsTest`): with the
tools taken on every call, as on the tip, one tools change at the first turn's second call
and 5 of the 6 calls refused (11 requests); held, one change at the second turn's first
call and 3 refused (9 requests). The hold saves the refusals of the rest of the turn the
tool came in, and none after.

**Live**, on Claude Sonnet 5.5 with `thinking_binding: error`, `loop_turn` three times each
on the installed build (the numbers are in `prompt-prefix.md`): with `goal_complete` on
the loop's turn alone (the same model through an entry saying `binds_thinking: false`),
every call of each person's turn was refused once, 9 in 22 calls, each with the API's
`kind=tools_changed; pattern=tool_set_changed`; offered on every call, none in 21, no tools
change, and the three runs cost $0.0849 against $0.1032.

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

**Proof.** `Troupe.Agent.StableToolsTest`: on a fake `claude-sonnet-5-5`, a loop's turn and
a person's turn after it send the same tools, `goal_complete` among them; called outside a
loop it is refused with the sentence and the turn ends normally; a subagent is not offered
it. On a model that does not bind: a person's tool offered in the middle of a turn joins the
tools at the next turn, not the next call; one that leaves stays offered to the turn's end
and a call to it is the `tool_gone` error; an MCP server started in the middle of a turn
(`Session.MCP.reload`) offers its tools from the next turn. And the cost above, against the
stand-in. `BoundThinkingTest`: a gateway's alias with `binds_thinking: true` and an effort
makes twelve requests over a twelve-call turn, none refused, no tools change.
`ThinkingTest`: the order the setting is read in, a file's provider and model entries, and
a listing's flag through the cache file. `BenchLiveTest`: `loop_turn` against the stand-in
as Claude Opus 5.5 with `error` makes six calls, nothing refused, no tools change; as
Claude Opus 5, which keeps 679's offering (the stand-in binds every model), the person's
turn changed the tools and each of its three calls was refused once. On the chunk's tip the
six cases of `StableToolsTest` before the cost case, and the alias case, failed; the cost
case's "before" is the same test with the tools taken on every call. And the installed
daemon on scratch homes, against the stand-in served as Claude Sonnet 5.5 with `error`: a
loop turn and a person's turn with no refusal, and an MCP stub whose tools changed while a
turn's first call was in flight changed the tools at the next turn only, a call to its
gone tool answered as gone.
