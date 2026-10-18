# Models and providers

Which models a machine can address, what a call costs, what the provider caches, how
hard a model thinks, and what each call tells the provider. Setting a provider up is in
the [provider recipes](configuration/providers.md), and what each provider type does
about keys, model lists, thinking and caching is the
[table of provider types](configuration.md#provider-types).

## The models Troupe can address

Troupe knows every model it can address: the ones each provider declares in
`config.yaml`, and whatever `models.default`, `models.cheap` and `models.expensive` name.
`troupe config` prints the list with each model's context window, where it came from, and
whether a key was found.

`troupe models` (`troupe-daemon models` too) asks the providers what they serve and keeps
the answer in `<config>/models.json`, so windows and prices are theirs rather than typed
by hand. It says what it fetched, from where and when. A model the config names that its
provider does not serve is said loudly, and any other model it does not serve says so
where its window would be (`--json` gives it a `context` of `null`):

```
catalog: 4 models from openai at https://gateway.example.com/model_group/info, fetched just now
models Troupe can address (use one as models.default; prices are $ per million tokens in/out):
  gpt-oss-120b                                 131k ctx, $0.10/$0.50, from the provider
  house-model                                  not served by openai, $0.50/$1.50 (models.prices), from your config
  qwen3-235b                                   131k ctx, $0.22/$0.88, from the provider  <- cheap
  qwen3.5                                      NOT SERVED by openai; it serves qwen3.6-35b, qwen3-235b, gpt-oss-120b  <- default
  qwen3.6-35b                                  262k ctx, $0.20/$0.80, from the provider
```

A LiteLLM gateway reports windows and prices; Anthropic reports windows only (it has no
pricing endpoint, and an unpriced model reads as unpriced, not free); a plain
OpenAI-compatible server reports what it likes. A window written in `config.yaml` still
wins. Each model says where its facts came from: the provider, asked just now; the cache
of what it said before; or your config.

The cache refreshes itself. `troupe models` asks first when it is stale, and `--refresh`
always. A session that starts never waits for it: the daemon refreshes it in the
background on the first run, when the provider or its base URL changed, when it is a day
old, when a provider that did not answer is due another try (after an hour), and when a
model the config names is not in it (after ten minutes). A provider that does not answer
keeps what it listed before. `troupe doctor` checks `models.default`, `cheap` and
`expensive` against what the provider lists, and fails on one it does not serve.

`/models` in the TUI opens the list as a menu, the model in use first: `↑`/`↓` move,
Enter picks one and writes it to the config file that owns the setting, Esc goes back, and
the last entry types a model by hand. The cheap model has the same menu on the settings
page.

## What a call costs

What the gateway says a call cost wins; then the catalog's price (the provider's own
list); then `models.prices`, in dollars per million tokens by the name the model is
addressed with, for a model the catalog does not price, such as one a LiteLLM gateway
serves and streams ([a gateway's file](configuration/providers.md#a-gateway-such-as-litellm)
has one). A call none of the three prices counts as free, and the daemon's log says so
once a session. A call priced from the catalog or `models.prices` is priced at its
`cache_read` and `cache_write` rates (a LiteLLM gateway's catalog quotes both), or at the
input price where those are not set.

`troupe models` shows each model's price and where it came from, or `no price`, and
`troupe config --explain models.prices` which file set it. A turn's cost in the TUI, in
its side panel or the line under the turn, is priced the same way.
`TROUPE_MODEL_PRICES` takes the same map as JSON, which is how a profile's `llm.prices`
reaches its pods.

## What each provider caches

One thing you type can take an agent many model calls, and each sends the whole
conversation again. A provider that caches the prompt bills what it has seen before at a
fraction of the input price, which on a long turn is most of what was sent. There is
nothing to set; what happens depends on the provider.

- **Anthropic** (`provider: anthropic`, or a provider of `type: anthropic`) caches only
  what a request asks it to, and every call an agent makes asks: the tool definitions, the
  system prompt and the conversation so far are marked, and the next call reads them back.
  The cache lasts five minutes from its last use, so the calls of a turn keep it warm and a
  reply after a long pause starts it again. A prompt shorter than the model's minimum (512
  to 4096 tokens, by model) is not cached. A gateway that speaks Anthropic's API passes the
  marks on or drops them.
- **OpenAI** caches a long enough prompt by itself, and so does Azure OpenAI.
- **An OpenAI-compatible gateway or server** (`provider: openai` with a `base_url`, such
  as LiteLLM or vLLM) caches whatever it and the model behind it do, which may be nothing.
  Troupe sends no marks this way; a LiteLLM deployment can be configured to add them for
  the Anthropic models it serves, and then reports what Anthropic wrote to the cache as
  well as what it read.
- **OpenRouter, the Gemini API and Ollama**: OpenRouter what the model's own provider
  caches by itself, Gemini a repeated prefix on the models that do, and Ollama a loaded
  model's last prompt, in memory and unreported.

The provider's own figures say whether it happened: each model call's `cache_read` and
`cache_write` in the session's log, and the TUI's token detail, which says how much of the
prompt came from the cache.

The agent's task list goes with the turn, as it stood when the turn began, and again only
when it changed. A rewrite within the turn reaches the model in the `todo_write` call's
result and leaves the cached prompt as it was. With `system_prompt: per_turn` the list
ends the system prompt instead: a list the turn before changed is new at the next turn's
first call, which writes the conversation to the cache again, and Anthropic still reads
the tools and the system prompt in front of the list.

## How hard a model thinks

`reasoning_effort` on a model's `models:` entry asks a model that reasons to think before
it answers: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or a number of
tokens. An OpenAI-compatible provider is sent the word as it is, and the model decides
what it means; OpenRouter is sent it in its own `reasoning` field, a number as a budget.
On every one but Anthropic the reasoning spends from the output cap, so an enforced
`max_tokens` holds it as it holds the answer.

Anthropic's models take it in one of two forms, and refuse the other:

- **Claude Opus 4.7 and later, Sonnet 5 and later, Fable and Mythos** take adaptive
  thinking with an effort level, and refuse a budget. A word is the level of that name
  (`minimal` is `low`); a number is the level whose budget below would hold it, and more
  than 32768 is `max`.
- **The models before them** (Opus 4.6, Sonnet 4.6, Haiku 4.5 and older) are sent a
  thinking budget: 1024 tokens for `minimal`, 4096 for `low`, 8192 for `medium`, 16384 for
  `high`, 32768 for `xhigh` and `max`, or the number given.

Which form a model takes is what Anthropic's model list says of it (`troupe models`
fetches it), else what its name says, found inside a gateway's renaming such as
`eu.anthropic.claude-opus-5`. A model neither describes is sent adaptive thinking for a
word and a budget for a number. A model that refuses what it was sent fails the call with
a message that names `reasoning_effort` and what to set it to.

Either way the output cap is raised to hold the thinking, no further than a `max_tokens`
your organisation enforces ([its limits](configuration.md#your-organisations-defaults-and-limits)),
which bounds the whole call, a compaction's summary included. Under it, an Anthropic
model's thinking is shortened so that the answer keeps 4,096 tokens, or half the limit
where that is less; where that leaves less than 1,024 tokens of thinking, the least
Anthropic takes, the call asks for no thinking at all. An OpenAI-compatible model's
reasoning already spends from the same limit. The first time a session's thinking is
shortened or turned off, it says so once, naming the limit and where it came from: "Your
organisation caps a model call's output at 1,000 tokens (https://plane.example.com), so
reasoning is off for this session: …".

Claude Opus 5 and later, Sonnet 5 and later, Fable and Mythos think whether or not
`reasoning_effort` is set. With none (or `none`) they are sent no thinking settings and
think at their own default effort, and what they thought is handed back to them on the
next call, as it is when an effort is set, so a turn of tool calls goes on from the
reasoning it started with.

Claude Fable 5.1, Opus 5.5 and Sonnet 5.5, and later versions, bind what they thought to
the conversation it was made in, its tools included: an account that enforces the check
refuses a call whose earlier thinking was made under other tools, and Troupe sends it
again without that thinking. For those, an agent's tools stay the same all session: the
task list's tools are offered from the first call, and `/loop`'s `goal_complete` on every
call of the session's main agent, refused outside a loop. Troupe tells these models by
name. A gateway's alias that hides the name, such as `smart` for Sonnet 5.5, is said to
bind with `binds_thinking`, on the model's entry or for every model of the provider;
`false` says a model does not. `thinking_binding` in [the key table](configuration.md#model-and-provider)
is the fallback for an account that refuses such a call.

```yaml
providers:
  gateway:
    type: anthropic
    base_url: https://llm.example.com
    models:
      smart: {reasoning_effort: medium, binds_thinking: true}
```

The tools of an MCP server, and those a person's client offers a session, may still come
or go while a session runs: a server that comes back with another list, a sign-in that
completes, a person who closes the window, a skill added, an agent restarting. Whatever
the model, those changes reach it at its next turn, never in the middle of one. A tool
that went in the meantime stays in the list until the turn ends, and a call to it is told
it is gone.

## What Troupe tells the provider

Every model call names the software that made it, so whoever runs the gateway can see
which of their spend is Troupe's, from which client and on which version:

- **Everywhere**, a User-Agent such as `troupe/0.8.4-beta (tui; windows/x86_64)`. The
  client is `tui`, `headless` (`troupe run --headless`), `desktop`, `acp` (an editor over
  ACP), `worker` (a session on a plane's pod) or `other`.
- **To a gateway** (the `base_url` of an `anthropic`, `openai` or `gemini` provider that
  is not the vendor's own API, nor OpenRouter), LiteLLM's `x-litellm-tags` (`troupe`,
  `troupe-<client>`, `troupe-<version>`) and `x-litellm-spend-logs-metadata` with the
  session's id. An `openai` request's `metadata` carries the session's id, the client and
  the version too. A server that is not LiteLLM ignores them. An `ollama` server and an
  `azure_openai` resource get the User-Agent alone.
- **To OpenRouter** (an `openrouter` provider, or any at openrouter.ai), `HTTP-Referer`
  (the project's page) and `X-Title: Troupe`.

A session on your machine names nobody: no person, no path, no repository, no host name.
A session on a plane's pod also carries what the plane attributes it with (its owner, its
team, its worker profile and the agent). `identify: false` turns all of it off, and the
User-Agent is the HTTP client's own. `troupe doctor` prints, on its `identify` line,
exactly the headers the default model's provider is sent, or `off`.
