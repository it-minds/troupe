---
number: 774
title: A compaction never cuts between a tool call and its results, a summary that fails leaves the conversation as it was, and `compacted` keeps a large tool result as a blob
date: 2026-10-04
status: accepted
issue: 399
paths:
  - apps/troupe_core/lib/troupe/agent/server.ex
gist: A compaction never cuts between a tool call and its results, a summary that fails leaves the conversation as it was, and `compacted` keeps a large…
---

`split_for_compaction` moved its cut back to the nearest user message, and a tool-results
message is a user message, so in a turn of many calls the part it kept could start with
results whose call had gone into the summary, while the summariser's own request ended on
that call with no results after it. Anthropic's and OpenAI's APIs refuse both with a `400`
that is not a context overflow: the summary failed, and every later request carried the
same results without their call and failed too, so a session on those endpoints stalled
until a person started another. A gateway that does not check passed it, which is how it
went unnoticed.
- **The cut still moves back to the person's message a reply answers, but never onto
  tool results; results at the head of what would be kept go into the summary with
  their call.** That is the old rule without its fault: an input stays with the
  replies to it, a compaction with nothing older to summarise does not happen, and a
  turn of nothing but calls can still be compacted. Cutting back past the results to
  their call keeps the pair too, but can leave nothing to summarise but the input or
  the last summary, a call that saves nothing. Cutting only at a person's input means
  a turn of nothing but calls, the turn #389 is about, could never be compacted, and
  an overflow in it would end the turn.
- **The conversation is replaced when the summary arrives, not when it is asked
  for.** Nothing is added to the conversation while an agent compacts (input waits),
  so `apply_compaction` takes the same split the summariser was sent. A summary that
  fails, or a cancel while it is asked for, leaves the conversation whole, which is
  what a replay rebuilds, since nothing was logged; before, memory held only the
  kept part and a restart had everything. The next request may not fit, and the
  provider says so (659).
- **`compacted` logs what it keeps as `tool_results` logs results**: a tool result
  over 16 KiB is a blob reference, resolved on replay, as PROTOCOL.md's rule for
  large payloads says. A log written before has its results inline, and they resolve
  to themselves.
