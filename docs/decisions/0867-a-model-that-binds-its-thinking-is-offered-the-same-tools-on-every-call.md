---
number: 867
title: "On a model that binds its thinking to the conversation, an agent is offered the same tools on every call, the task list's from the first; a compaction keeps its tail without that thinking, and the summariser reads none"
date: 2026-10-11
status: accepted
issue: 590
supersedes: [793]
paths:
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/tools/todo.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
  - apps/troupe_core/lib/troupe/bench/live_scenarios.ex
symbols:
  - Troupe.LLM.Catalog.binds_thinking?/1
  - Troupe.Tool.Ctx
gist: "Fable 5.1+, Opus and Sonnet 5.5+ get the task list's tools from call 1 (793's gate stays for others); a compaction's kept tail and the summariser get no thinking there"
---

Claude Fable 5.1, Opus 5.5 and Sonnet 5.5 bind each thinking block to the conversation it
was made in: the model, the tools, the system prompt and every message before it (Decision
805). Troupe hands every block back, so on an account the check is enforced for, any
change in front of one makes every later call that carries it refused once and sent again
without its thinking. A stable system prompt (Decision 863) took the system prompt's
changes away.

**What changed.**

- **The tools.** `Catalog.binds_thinking?/1` says, by the model's name as `thinks_unasked?`
  reads it (a gateway's renaming too), which models bind: Fable from 5.1, Opus and Sonnet
  from 5.5, and later versions of the three. The agent tells `Tools.available/2` which
  model a call goes to (`Tool.Ctx.model`), and an agent with every tool on one of those is
  offered the list's tools from its first call, so its tools are the same on every call of
  the session. Elsewhere Decision 793's gate stands, as it was.
- **The compaction.** On a model that binds its thinking, the tail a compaction keeps goes
  without its Anthropic thinking blocks: the `compacted` event logs it so, and a replay
  rebuilds the same. That is what Anthropic's documentation asks of a compaction's tail,
  and the stand-in, which binds as the documentation says, accepts it; blocks made after
  the compaction are bound to the new conversation and go back as before. On any other
  model a block still holds and keeps its reasoning, and an Anthropic model thinking with
  an effort set may need its last one in a tool-use turn. A message that was nothing but
  thinking is left as it was rather than sent empty.
- **The summariser** reads the stretch it replaces with Anthropic's thinking taken out, on
  every model: it was never text a summary can use, and on a model that binds it, the
  summariser's conversation is not the one it was made in. Another provider's reasoning is
  left alone (DeepSeek refuses a thinking-mode turn that drops it).
- **The words.** The tool's description is unchanged and the same on every model: it is
  part of the tools, and a description that depended on the model or the call would be a
  change of its own.

**Why this way.**

- **Not the list's tools from the first call everywhere.** 793's reason was not the tool
  definitions' tokens but calls: `qwen3-235b`, which answers with one tool call a
  response, wrote a list for every task of two to four steps when it had the tool, and
  updated it in a call of its own after each step, whatever the prompt said; the gate took
  `follow_steps` from twelve calls, cut off by the cap, to nine (`TaskListCallsTest`). On
  a model that does not bind its thinking, the change at the eleventh call costs one cache
  write a long turn, which 793 measured and accepted; on one that binds, it costs a
  refused request and the reasoning on every later call of the session on an enforced
  account, which is what a fresh Anthropic account is.
- **Not "append-only".** The tools are rendered before the system prompt and the messages,
  so a tool added later is never after what was sent. Anthropic's tool search, whose
  deferred tools are added in the conversation, is one provider's beta, and it leaves the
  choice to load a tool to the model.
- **Not decided as each turn begins.** Earlier turns' thinking goes back too (805), so a
  change at a turn's first call makes those blocks stale as surely as one at its eleventh.
  Only a tool set that stays put for the session keeps every block valid.
- **By name, as 805 reads whether a model thinks unasked.** The model list has no field
  for the binding. A gateway's alias that hides the name is read as a model that does not
  bind; through the OpenAI-compatible wire no Anthropic thinking goes back at all, so
  nothing is bound there, and on Anthropic's wire an alias's blocks go only with an effort
  set (805). A model that binds offered the list early through either costs its tokens and
  nothing else.
- **Strip the tail, not keep it.** Keeping it is what the API refuses on an enforced
  account (the stand-in's diagnosis names the messages; Anthropic's header has
  `pattern=tail_kept` for it). Taking out every block of the tail is a leading run of the
  new conversation's blocks, which the API accepts, and is what 805's resend sent anyway,
  once a call, for the rest of the session.

**What it costs.** On a model that binds its thinking, every call before a turn's
eleventh carries the list's two tool definitions. On Anthropic's API
the tools are the front of the first cache mark, so after the first call of a session they are
read from the cache.
