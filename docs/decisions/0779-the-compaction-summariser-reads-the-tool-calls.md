---
number: 779
title: The compaction summariser reads the tool calls it summarises as text, and a summary that does not come within `llm_timeout_ms` is given up on
date: 2026-10-05
status: accepted
issue: 404
paths:
  - ARCHITECTURE.md
  - apps/troupe_core/lib/troupe/agent/server.ex
gist: The compaction summariser reads the tool calls it summarises as text, and a summary that does not come within `llm_timeout_ms` is given up on
---

Issue #404 and the first
item of D66. The summariser's request defines no tools, while the stretch it
summarises holds tool calls and results, and Anthropic's Messages API refuses a
request with tool blocks and no tool definitions. So every summary of a stretch with
a tool call in it failed there, which since 774 changes nothing: a session on that
API, or on a gateway in front of it, never compacted and grew until it overflowed.
OpenAI's API takes such a request, which is how it went unnoticed. And `:compacting`
had no clause for `{:llm_timeout, ref}`, so a summariser call that hung kept the agent
there past `llm_timeout_ms`, where `:thinking` gives the same call up.
- **Written out, not defined.** Each call in what is summarised goes to the summariser
  as `[called read_file {"path":"notes.txt"}]` and each result as `[read_file
  returned]` or `[read_file failed]` with its output, whole (771: the summariser
  condenses results rather than sending them again). Carrying the definitions of the
  tools the calls used was the other way, and loses on each count: their bytes on
  every summary (the build profile's are about 12 kB) with no cache to read them from,
  since the summariser runs on the small model with a system prompt of its own and the
  agent's prompt cache does not carry over; a definition wanted for a tool the session
  no longer has (an MCP server gone, another profile's tool); and a summariser offered
  tools may answer with a call rather than a summary, which `tool_choice` would have
  to forbid on every provider. Text is valid on every provider, and `tools` stays
  empty, which is how the bench tells the summariser's call apart (772).
- **The summariser is told how a call reads**, and asked for what the calls that
  matter did (the tool, the arguments that matter, the gist of the result) rather
  than their output, where its prompt said to drop "tool mechanics".
- **A result's tool is named by the calls in the message before it**, as 771's stub
  names it: a gateway that numbers its calls repeats ids across responses.
- **Only the summariser's request changes.** The conversation, the log, the split
  (774) and the counting (769) are as they were. `compact_prompt` measures the request
  as sent, so the summariser's `tool_results` bytes read 0 now: its results are text
  in `conversation`. Against the chunk's tip, the bench's summary call is 22 bytes
  shorter (206 more of system prompt, 228 fewer of conversation), and no budgeted
  measure moves.
- **A summary that does not come** is given up on after `llm_timeout_ms`, as any model
  call is: `:compacting` turns the timeout into the `llm_error` `:thinking` makes of
  it, and that fails as a refused summary does, leaving the conversation as it was
  (774) and going on to the interrupted turn or to rest.
- **A stand-in that refuses what Anthropic's API refuses.** The fake model takes
  `strict_tools`: a request whose messages hold a tool call or result and that defines
  no tools gets the `400`, in Anthropic's words, and takes no step from the script.
  Opt-in, beside `strict_pairs`, since OpenAI's API takes such a request; the whole
  core suite passed with it on for every session, so nothing else in core sends one.
  A step
  `{:delay, ms, step}` answers late, as the bench's model's does, which is how a test
  outlasts `llm_timeout_ms`.
- **Proof:** `CompactionTest`, against the stand-in with both checks on: a turn of a
  `read_file` and three `todo_read`s that overflows compacts once and finishes, and
  the summariser's request holds no tool block and carries `read_file
  {"path":"notes.txt"}` and the file's text, which failed on the chunk's tip (no
  `compacted`: the summary request was refused); and with `llm_timeout_ms` at a second,
  a summariser that would answer after a minute ends the compaction, the turn finishes
  and the conversation is whole, which on the tip was still in `:compacting` ten
  seconds on. `FakeScriptTest`: the stand-in refuses tool blocks without tools, takes
  text alone and the same blocks with tools, and answers a delayed step late.
