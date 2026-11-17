---
number: 967
title: "A model request that sends nothing for a minute is given up on with a sentence naming the host, the daemon's log says where a turn is, and `troupe doctor` asks the model for one token"
date: 2026-10-29
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/state.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/doctor.ex
symbols:
  - Troupe.LLM.Provider.first_byte/3
  - Troupe.LLM.Request.host/1
gist: llm_first_byte_ms (60 s) ends a call nothing came from with a sentence naming the host; llm_timeout_ms stays the whole call's; four info lines per turn; doctor's answer line
---

The harness gives a model call `llm_timeout_ms`, five minutes, as Req's `receive_timeout`
and as the agent's own timer, and nothing between the prompt and the answer is said at a
level the daemon's log keeps. A request whose first byte never comes, because the address
is wrong, the key is refused by something that does not say so, or a proxy holds the
connection, looked exactly like a model thinking, for five minutes, and then said only
that the model did not answer in time.

- **A first-byte limit, beside the whole call's.** `llm_first_byte_ms`, 60 s by default,
  is a second timer the agent sets as the request goes out, in a turn and in a compaction
  alike. The HTTP adapters say `{:llm_first_byte, ref}` as the first chunk of any response
  arrives, an error's as much as the stream's, before they read it; a delta or a usage
  report counts too, for an adapter that sends no such message. The first of these cancels
  the timer. Where it fires, the call is stopped and counted as one that outlasts
  `llm_timeout_ms` is, and the turn ends `llm_error` with a sentence that names the host
  and the wait, blames the address, the key or a proxy rather than the model, and names
  `troupe doctor` as the next step. A 429 being retried is a host that answered, and is
  not given up on here.
- **Not a lower `llm_timeout_ms`.** The other way was one shorter limit. A reply that has
  begun may pause for long thinking, and a reasoning model's first visible delta can come
  minutes after its first byte; Req's `receive_timeout` bounds the gap between packets and
  the agent's timer the whole call, and both have to stay long. What is short is the wait
  for the first byte, which no model spends thinking: a host that has said nothing in a
  minute is not going to.
- **Four lines in the daemon's log.** `troupe: <session> <agent> turn <n> preparing`
  when the turn begins, `... asking <model> at <host>` as the request goes out, `... first
  byte after <ms> ms`, and `... answered after <ms> ms: <stop reason>` or `... failed
  after <ms> ms: <sentence>`. At `info`, the daemon's default level, so a `daemon.log` from
  a machine that shows nothing says where the turn stuck; `debug` would have been
  dropped. The summariser's are `turn <n> summary ...`. Never the key.
- **`troupe doctor` asks the model.** The `key` line asks the host to list its models;
  the new `answer` line asks the default model for one token, as a turn asks it, through
  the adapter a turn uses, with the key as a turn resolves it, once, within 20 s: `ok` with
  the round trip, `fail` with the sentence a turn would have ended with (the credentials
  refused, the connection failed, nothing sent in 20 s). The `fake` provider and a
  provider with no key are asked nothing, as the `key` line asks them nothing.
