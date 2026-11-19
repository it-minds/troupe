---
number: 1065
title: "A gateway's cost reaches the ledger from the stream's `usage.cost`, which the OpenAI adapter asks a gateway for on every call, or from the cost header; where both say, the stream's counts. A LiteLLM gateway's streamed calls need no `llm.prices`"
date: 2026-11-19
status: accepted
issue: 1133
paths:
  - apps/troupe_core/lib/troupe/llm/message.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/identify.ex
symbols:
  - Troupe.LLM.Gateway.with_reported_cost
  - Troupe.LLM.Gateway.to_micros
  - Troupe.LLM.Identify.gateway?
gist: "OpenAI adapter reads usage.cost (stream's last chunk, or a whole body) into Gateway.cost_micros through to_micros; sends x-litellm-include-cost-in-streaming-usage to a gateway, identify or not; stream beats header, a difference said at debug"
---

Narrows Decision 689's first source, "the gateway's figure", which was the
`x-litellm-response-cost` header alone. LiteLLM sends its headers before the first token, so
a streamed call, which is every call a pod makes, never carried one; behind a gateway that
addresses models by alias the catalog has no price either, and the plane's ledger read 0
for every team unless each profile copied the gateway's price list into `llm.prices`.

- **Where the cost is read.** The OpenAI adapter reads `cost`, dollars, from any `usage` a
  chunk carries (LiteLLM's last chunk) and from the `usage` of a whole JSON body a server
  sent instead of a stream, which is now read as the completion it is. It lands on
  `Troupe.LLM.Gateway.cost_micros`, where the header's did; `Troupe.LLM.Usage` stays four
  token figures (Decision 657).
- **One conversion.** `Gateway.to_micros/1` takes the header's text and the JSON number
  alike: a float is written out as its shortest decimal, the digits the gateway's JSON
  encoder wrote, and read by the same digit arithmetic, so neither goes through a float
  multiplication. A whole number is whole dollars.
- **The stream wins.** Where the header and the stream both name a cost and differ, the
  stream's is counted and the difference is logged once at debug level. The stream's is
  what LiteLLM wrote to its own spend log for this call, the ledger
  `mix troupe.ledger.reconcile` compares against; the header is written before the call
  finished.
- **Asked for, per request.** To a gateway, the condition under which `Identify` sends
  `x-litellm-tags` (`Identify.gateway?/2`: a type that may sit behind one, neither the
  vendor's API nor OpenRouter), the adapter sends
  `x-litellm-include-cost-in-streaming-usage: true`, so no administrator has to change the
  gateway's settings. A gateway that is not LiteLLM ignores an unknown header. It goes
  whether or not the request identifies: it says nothing about who calls, and narrows
  Decision 787's "`identify: false` sends none of it" to what identifies.

Not chosen: a provider type of its own for LiteLLM (Decision 887 folded every gateway into
`openai`, and a second type would split one wire into two); asking only when the profile or
the config says so (a setting nobody knows to set is the bug as it was); summing the header
and the stream, or preferring the header (two figures for one call, or the earlier one);
reading `/model_group/info` on a pod (Troupe would multiply tokens itself and could differ
from the bill; not this decision's). The Anthropic adapter is unchanged: a pod's profile
behind LiteLLM speaks `openai`, and what LiteLLM's `/v1/messages` stream says of cost was
not looked into.

Undone, a pod's calls behind LiteLLM cost 0 again unless every profile carries a copy of
the gateway's prices, which goes stale the day an alias points at another model.
