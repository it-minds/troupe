---
number: 880
title: "An organisation's enforced max_tokens holds every model call, the room a reasoning effort gives the thinking included: Anthropic's thinking is shortened to fit, is off below 1,024 tokens, and the session is told once on a config_note"
date: 2026-10-12
status: accepted
issue: 644
supersedes: [658]
paths:
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/config/org.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - protocol/schema/v1/events/config_note.json
  - PROTOCOL.md
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/gui/packages/client/src/transcript.ts
  - apps/troupe_core/test/troupe/agent/thinking_ceiling_test.exs
  - apps/troupe_core/test/troupe/llm/thinking_test.exs
  - docs/user/configuration.md
  - docs/admin/configuration.md
symbols:
  - Troupe.LLM.Request.output_cap/1
  - Troupe.LLM.Provider.thinking_held/2
  - Troupe.LLM.Providers.Anthropic.thinking_held/1
gist: "No call asks past an enforced max_tokens; Anthropic thinking shrinks to fit (answer keeps min(4096, half)), off below 1024; told once, config_note"
---

Issue #644, which #622 left (Decision 869's ceilings). An organisation can enforce
`max_tokens`, and the config ladder holds every layer to it, but the Anthropic adapter
raised a request's `max_tokens` to hold the thinking a reasoning effort asks for (Decision
658: the budget plus 4,096 tokens for the answer), and nothing held that raise. On the
chunk's tip, with `max_tokens: 1000` in a managed file's `enforced:` and a model at
`reasoning_effort: high`, the request went out with `max_tokens: 20480`. The summariser's
own call asked for 2,000 under the same ceiling, whatever the effort. The maintainer decided
the shape on 2026-10-12 (#644's comment): the thinking shrinks so the whole request stays
under the ceiling, it is off where what is left is below Anthropic's 1,024-token minimum,
and the person is told once, naming the organisation. This records how, and what the
decision left open.

## No call asks past the ceiling

The enforced value is carried as `config.ceilings.max_tokens` (with its source, beside the
budget's `max_turns` and `wall_clock`) and goes on every request as `Request.ceiling`.
Where the agent aims a request, its `max_tokens` is the lowest of what it asked, the named
model's `max_output` and the ceiling, so the summariser's 2,000 is held too. Both HTTP
adapters send `Request.output_cap/1`, the cap held to the ceiling, so a request built
anywhere else is held the same way.

## How the thinking fits (Anthropic)

The raise stops at the ceiling, and the thinking gets what is left after the answer's
share, never more than its effort asks for:

- **The answer's share** is 4,096 tokens, what the raise has always given it beside the
  thinking, or half the ceiling where that is less. Chosen over a fixed 4,096, which would
  turn thinking off under any ceiling below 5,120 (a 4,096 ceiling would think nothing),
  and over always half, which would cut `xhigh` to 16,384 under a 32,768 ceiling where
  28,672 fits with the usual room for the answer. So a ceiling of 8,192 at `high` is a
  budget of 4,096; of 6,000, 3,000; of 2,048, 1,024.
- **Below 1,024 tokens of thinking** (any ceiling under 2,047), thinking is off for the
  request: no `thinking` field and no `output_config`, which is what an effort of `none`
  sends. A model that thinks unasked (Opus and Sonnet 5 and later, Fable, Mythos) still
  thinks at its own default inside the ceiling, since most of them refuse to be told not
  to (Decision 805), and its blocks still go back to it.
- **Adaptive thinking** has no budget field, so it is sent the level the room left holds,
  by the same thresholds a number of tokens maps to: `high` under 8,192 goes as `low`,
  `max` under 20,000 as `high`.
- **A ceiling the thinking fits under** changes nothing: the request is the one Decision
  658 and 780 describe. A ceiling that holds only the answer's room (`minimal` under
  2,048: a budget of 1,024 in a cap of 2,048) shortens the answer, which is what the
  organisation asked for, not the thinking, and is not said.

A refusal names the thinking that was sent, the shortened budget or level.

## An OpenAI-compatible provider

Its reasoning model counts reasoning against `max_completion_tokens`, and Troupe raises
nothing for it, so the cap is the ceiling and the effort goes as it is: the model decides
how much of the cap to reason with. Nothing Troupe sends is shortened, so the person is
not told. The 400 that asks for the other field name sends the same held number.

## Told once, on a new event

None of the events the clients show fits: `budget_warning` is a budget dimension near its
end, drawn as "… used" and "nearly out"; `watch_notice` is ephemeral and the desktop app
does not show it; `onboarding_suggested` is onboarding's own; and the warnings a config
load gives go to the daemon's log only. So a new durable event, `config_note`: `key` (the
setting), `message` (the sentence, shown as it is), and here `limit`, `source` (the
plane's URL or the managed file's path), `model`, `effort` and `thinking` (the tokens
given, 0 for off). Named for what it is so that the next thing the configuration does to
a session that a person should hear about can use it. The terminal UI draws it as a line
of the root's transcript, the desktop app as a note in the session's stream.

- **The sentence:** "Your organisation caps a model call's output at 1,000 tokens (source),
  so reasoning is off for this session: reasoning_effort high asks for 16,384 tokens of
  thinking, and less than 1,024 is left beside the answer.", or "... so reasoning is
  shortened for this session: 4,096 tokens of thinking where reasoning_effort high asks
  for 16,384."
- **When:** before the first call whose thinking the ceiling shortened or turned off, so
  it reads ahead of the answer it explains. The agent asks the adapter what the ceiling
  left of the thinking (`Provider.thinking_held/2`, which calls the optional callback
  `thinking_held/1`; only Anthropic's adapter has it).
- **Once a session, not once an agent:** the first agent whose call is held claims it for
  the session (`Log.first?`, as an unpriced model is said), and the note goes under the
  root. A session stopped and resumed, or a daemon restarted, starts a new log process;
  the root's replay finds its own `config_note` and claims it again, so it is not said
  twice. The claim is the session's, not part of the agent's state, so the fold the
  fixtures hash is unchanged.

## Not in this

A ceiling set per model (an organisation enforcing a lower cap on one model only); a note
for a model that thinks unasked under a ceiling with no effort set (Troupe asked for
nothing, so nothing of its asking was shortened); and the desktop app's settings view,
which shows no setting's source yet (Decision 869's follow-up).

## Proof

- `apps/troupe_core/test/troupe/agent/thinking_ceiling_test.exs`, through a loopback
  stand-in that records each body and a managed file the test writes: the reproduction
  (`max_tokens: 1000` enforced, `claude-opus-5-5` at `high`: 1,000 and no thinking, and
  the note under the root naming the file; on the tip, 20,480 and no note); Haiku 4.5's
  budget shrunk to 4,096 under 8,192 and the note saying so; Opus 5.5's level `low` under
  8,192; a ceiling of 32,768 changing nothing; two held calls and one note; a session
  stopped and resumed not told again (with the replay's claim taken out, it was told
  twice); an OpenAI-compatible model at `high` sent `max_completion_tokens: 1000`;
  the summariser's call held to 1,000 (on the tip, 2,000).
- `apps/troupe_core/test/troupe/llm/thinking_test.exs`: three models (adaptive, budget,
  unknown) at nine efforts under nine ceilings from 1 to 100,000, none asking past its
  ceiling and every budget at least 1,024 and under the cap; the budgets and levels above;
  off below 1,024 with the unasked thinker's blocks still sent back; `thinking_held/1`;
  a refusal naming the shortened budget.
- `apps/troupe_core/test/troupe/llm/providers_test.exs`: the OpenAI-compatible adapter
  under a ceiling, and its retry with the other field name.
- `clients/tui/test/troupe/remote_translate_test.exs` and
  `clients/gui/packages/client/test/transcript.test.ts`: the note drawn as the harness's
  sentence.
- The installed daemon and terminal client, on scratch homes with a plane's cached
  document enforcing `max_tokens`, a named Anthropic provider at a loopback stand-in that
  printed each body, and `troupe run --headless`: under 1,000, `claude-opus-5-5` at `high`
  went out with `max_tokens: 1000` and no thinking, twice, and the run printed the note
  once, naming the plane; under 8,192, `claude-haiku-4-5` at `high` went out with
  `max_tokens: 8192` and a budget of 4,096, and the new session printed the shortened
  note. One `config_note` in each session's log.
