---
number: 805
title: Anthropic's newest models think whether or not they are asked to, so their thinking goes back to them within a turn as it does when an effort turns it on; and a provider error the retries outlast, or one inside a stream, is said in the provider's words, trimmed and without the key
date: 2026-10-06
status: accepted
issue: 427
paths:
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
  - apps/troupe_core/test/troupe/llm/thinking_test.exs
  - apps/troupe_core/test/troupe/llm/error_body_test.exs
  - apps/troupe_core/test/troupe/agent/thinking_kept_test.exs
  - apps/troupe_core/test/support/error_stand_in.ex
symbols:
  - Troupe.LLM.Catalog.thinks_unasked?/1
  - Troupe.LLM.Provider.with_retries/2
gist: A model that thinks unasked (Opus and Sonnet 5+, Fable, Mythos) gets its thinking blocks back with no effort set, not thinking turned off
---

Issue #427 and the first two items of D74. With no `reasoning_effort` the Anthropic
adapter sends no `thinking` field (780), and it handed a thinking block back only when the
request turned thinking on (658). Anthropic's newest models think with no `thinking` field
at all, so for them every thinking block was dropped: on the chunk's tip, the second call
of a tool-use turn to `claude-opus-5-5` went out with the first call's `tool_use` and none
of the thinking that led to it.

- **What Anthropic does**, as its API documentation had it when read on 2026-10-06 (the
  Claude API reference and model migration guide, model tables of 2026-09-25):
  - With no `thinking` field, Opus 5 and 5.5, Sonnet 5 and 5.5, Fable 5 and 5.1 and
    Mythos 5 and 5.1 think, adaptively. Opus 4.7 and 4.8 take adaptive thinking but think
    only when asked; Opus and Sonnet 4.6, Haiku 4.5 and older do not think unasked.
  - Turning it off: Opus 5.5, Fable and Mythos refuse `thinking: {type: "disabled"}` with
    a 400 at every effort. Sonnet 5.5 refuses it too and turns thinking off only with a
    form of its own, `{type: "between_tools"}`, at effort `high` or below and with no
    other field beside it. Opus 5 takes `disabled` at `high` or below, and with it
    sometimes writes a tool call into its text, where it never runs and no error says
    so, or lets internal tags into its reply; the guide's advice is to keep thinking on
    and lower the effort instead. Sonnet 5 takes `disabled`.
  - What comes back: a `thinking` block whose text is empty unless the request asked for
    `display: "summarized"` (`"omitted"` is the default on all of these), with a
    signature. `display` changes what is shown, not what is thought or billed. Sending
    the blocks back unchanged, empty text and all, is how a conversation continues on
    the same model; taking one out of the middle invalidates those after it, and taking
    them all out is the documented way to have the model answer without that reasoning.
    A model that cannot read another model's block drops it, unbilled.
  - On Fable 5.1, Opus 5.5 and Sonnet 5.5 a block's signature also binds it to the
    conversation that made it (the system prompt, the tools, the messages before it),
    and for accounts created on or after 2026-08-31 a block whose conversation was
    edited since is refused with a 400 whose message begins ``Invalid `signature` in
    `thinking` block`` and says the block is bound to a different conversation. Without a
    beta header, the documented recovery is the same request with every thinking block
    taken out, once.
  - Cost: a block sent back is input on every later call. It sits before the
    conversation's cache marks (770), so after the call that writes it, it is read at
    the cache rate; and these models keep earlier turns' thinking in context by default,
    so sending it is what keeps their messages cache as it was.
- **Which: keep the blocks, never turn thinking off.** Turning it off is not on offer for
  most of these models (a 400 on Opus 5.5, Fable and Mythos, a form of its own on
  Sonnet 5.5), and where it is, on Opus 5, the guide names what it costs: tool calls that
  never run. Keeping the blocks is what keeps the model's quality: within a tool-use turn
  each call goes on from the reasoning the last one ended with rather than starting
  over. That is what the maintainer leaned to, and what an effort already got (658, 780).
- **Which model thinks unasked** is read from its name, as 780 reads the form:
  `Catalog.thinks_unasked?/1` says yes to Opus and Sonnet from 5 on, Fable and Mythos,
  inside a gateway's renaming too (`eu.anthropic.claude-opus-5`). The model list has no
  field for it: `capabilities.thinking.types` says which forms a model takes, and Opus
  4.8 takes adaptive thinking without using it unasked. The adapter hands Anthropic's
  blocks back when the request turns thinking on, as before, or when the model thinks
  unasked; the request is otherwise as it was: no `thinking` field, no `output_config`,
  the model's own default effort. An effort of `none` or `off` sends nothing either, so
  a model that thinks anyway gets its thinking back the same way.
- **A block the conversation no longer vouches for.** Troupe's prompt changes between
  turns (the task list as each turn begins, 792; the instruction files and brief read as
  it begins, 798; the goal) and compaction rewrites the history, so on an account the
  check is enforced for, a block from before such a change is refused. That 400 is
  answered by sending the call once more with no thinking in it, the API's own way on and
  what every one of these requests was before this decision; a second refusal is the
  turn's error, in the provider's words. With an effort configured it is the same. The
  cost is one refused call and the earlier reasoning, where without it the turn failed.
- **A failure the retries outlast says what the provider said.** `with_retries` carried
  only the status, so a 5xx or a 429 past its retries read `gave up after retrying:
  {:http_status, 503}`. Both adapters now give the retry the status with the provider's
  message, read and cleaned as an error response's is (791), `{:http_status, status,
  detail}`; `describe_error` says the last one as it would have been said unretried
  (`gave up after retrying: the provider answered 529 (Overloaded)`), and a rate limit
  the backoff outlasted names what the provider said about it. A transport failure is
  said as before.
- **An error inside an Anthropic stream** (`{:api_error, message}`, an `error` event after
  a 200) is trimmed and has the key masked, as an error response's message is since 791.
- **Not in this:** a summary of the thinking with no effort set (the newest models'
  thinking still streams as empty blocks; asking for `display: "summarized"` would put a
  `thinking` field on a request the person asked nothing of); a gateway's own alias for
  one of these models, which Troupe cannot tell thinks unasked, so its blocks still go
  unless an effort is set; Troupe's own edits that invalidate a block on the newest
  models, which this makes cost a call rather than the turn but does not remove;
  Anthropic's beta for dropping only the invalidated blocks; D74's third item.
- **Proof:** core's `ThinkingTest`, against bodies written out in full: a tool-use turn's
  second request to Claude Opus 5.5 with no effort, after a first answer streamed as the
  newest models stream one (a thinking block with only its signature, then the call),
  carries that block back unchanged and asks for no thinking; nine of the models that
  think unasked, two of them in a gateway's spelling, keep their blocks and seven that do
  not (Opus 4.8 and 4.7 among them, and a name nothing describes) drop them; `none` and
  `off` keep them; a 400 naming a block bound to another conversation is sent once more
  without the thinking, with and without an effort, a second one is the error, and any
  other 400 is not sent again. `Troupe.Agent.ThinkingKeptTest`: an agent's tool-use turn
  on Opus 5.5 through a loopback stand-in that records each body sends the second call
  the first call's block. `ErrorBodyTest`: Anthropic's 529 `Overloaded` and an
  OpenAI-compatible server's 503 past their four retries say the provider's message,
  trimmed, the second with the key masked; an `error` event inside an Anthropic stream
  is said trimmed and masked. `ProviderErrorsTest`: a 429, a 503 and a 502 the retries
  outlast. On the chunk's tip all of these failed: the blocks were dropped, the retried
  failures said `{:http_status, 529}`, and the stream's error carried the key and its
  whitespace. And the installed daemon, with scratch homes, over the protocol against
  loopback stand-ins that record each body: a tool-use turn on `claude-opus-5-5` with no
  effort sent its second call the first call's thinking block, empty and signed, and no
  `thinking` field, where `claude-opus-4-8` dropped it; on `claude-sonnet-5-5` a second
  call refused as bound to another conversation went once more without the block and
  the turn finished; five `529 Overloaded` ended `gave up after retrying: the provider
  answered 529 (Overloaded)`; an `error` event read `the provider reported an error
  (upstream refused key sk-i...ef)`. The build installed before dropped the block on
  every model, ended the 529s `gave up after retrying: {:http_status, 529}`, and said the
  stream's error with its whitespace and the key in full.
