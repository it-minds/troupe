---
number: 791
title: A provider's error reaches the adapter whatever the transport does with its body, so a context overflow over a real connection is compacted, and a person reads what the provider said, trimmed and without the key.
date: 2026-10-05
status: accepted
issue: 436
paths:
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/test/support/fake_transport.ex
symbols:
  - Troupe.LLM.Provider.collect_error/2
  - Troupe.LLM.Provider.error_text/2
gist: Req hands into every response's body; an adapter keeps a non-200's for its error clauses and reads it itself. FakeTransport sends errors the same way.
---

Issue #436, found while fixing D69 (788). Both HTTP adapters stream with Req's `into: fn
...`, and Req hands that function the body of every response, whatever its status: its
Finch step (`finch_stream_into_fun`) puts the status and the headers on the response and
passes each `{:data, chunk}` on. So on a 4xx the adapter's `%Req.Response{status: 400,
body: body}` read `""`, and the provider's error had gone to the event-stream parser, which
found no event in it. A context overflow read as a bare 400, so 659's compact-and-retry
never fired and the turn ended with "the provider answered 400"; the OpenAI adapter's
`max_completion_tokens` retry (658) and 780's wording for refused thinking, which read the
same body, never applied; and every 4xx a person saw said only its status. The adapters'
tests missed it because `FakeTransport` returned an error response with its body already
in it, without going through `into`.

- **The status, checked in `into`.** Each adapter's `handle_chunk` feeds the parser only
  for a 200; any other status's chunks are kept on the response's body
  (`Provider.collect_error/2`, up to 64 KiB, more than any provider's error and a bound on
  a proxy's page), where the error clauses of `post` read it. Req is not asked to decode it
  (`decode_body: false`) and the adapter decodes it itself, so a body that is not the JSON
  its content type says, or one cut at the bound, is still read as text rather than turned
  into a decoding exception the adapter would hand on as the failure. Req has no option
  that hands `into` only a 2xx's body, and the status read after the request is too late:
  the body has gone by then.
- **What a person reads.** The message comes out of the JSON as before (`error.message`
  for both, and now a top-level `message` too, which is vLLM's), else the text, at most 400
  characters; it is trimmed, and the key the request was sent with is masked wherever it
  appears, as `troupe config` shows a key (`Config.mask/1`, in `Provider.error_text/2`). A
  provider, or a gateway in front of one, may say a key it refused back in its message,
  and the sentence goes into `llm_error.reason`, into the log and into the conversation as
  the note (693), and so to the provider again. A key shorter than eight characters is a
  placeholder a local server takes (vLLM's `EMPTY`) and is left alone, since masking it
  would only garble the message. `Provider.classify/1` and `describe_error/1` are as they
  were: they have the provider's words to go on now.
- **The fake transport sends an error as the socket does.** `FakeTransport`'s error
  responses go through `into` with the status set, as Finch's do, so the adapters' own
  tests read an error the way a real connection delivers it.
- **Not in this:** a 5xx or a 429 that outlasts its retries is still said by its status
  alone (`gave up after retrying`), since `with_retries` carries no body; an error inside
  an Anthropic stream (`{:api_error, ...}`) is not masked, since none says a key back.
- **Proof:** core's `ErrorBodyTest`, against a loopback stand-in
  (`test/support/error_stand_in.ex`) that sends an error as JSON in two chunks of a chunked
  body. After four reads, Anthropic's 400 `prompt is too long` and an OpenAI-compatible
  server's 400 `context_length_exceeded` are compacted (`compacted`, `reason:
  context_overflow`), the summary is asked for and the turn is sent again, shorter, and
  answered, with no `llm_error`; a 400 from each says the provider's message (`the provider
  answered 400 (tools.0.input_schema: JSON schema is invalid)`); and a 401 whose message
  says the key back says it masked and trimmed. All five fail on the chunk's tip, the two
  overflows with an `llm_error` reading `the provider answered 400` and no compaction. With
  `FakeTransport` sending as the socket does, `ProvidersTest`'s `max_completion_tokens`
  retry and three of `ThinkingTest`'s refusals fail on the tip as well, and pass with the
  change.
