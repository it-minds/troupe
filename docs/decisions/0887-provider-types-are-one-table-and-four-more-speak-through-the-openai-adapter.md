---
number: 887
title: Provider types are one table that every reader takes them from; ollama, openrouter, azure_openai and gemini go through the OpenAI adapter with their differences in one module, Gemini through its OpenAI-compatible endpoint; a name that is no type is refused, and migrate rewrites the ones people mean another type by
date: 2026-10-12
status: accepted
issue: 658
paths:
  - apps/troupe_core/lib/troupe/llm/provider_type.ex
  - apps/troupe_core/lib/troupe/llm/providers/compatible.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/provider.ex
  - apps/troupe_core/lib/troupe/llm/endpoint.ex
  - apps/troupe_core/lib/troupe/llm/identify.ex
  - apps/troupe_core/lib/troupe/llm/message.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
  - apps/troupe_core/lib/troupe/llm/catalog/store.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/config/migrate.ex
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/lib/troupe/config/open_code.ex
  - apps/troupe_core/lib/mix/tasks/troupe.config.schema.ex
  - apps/troupe_protocol/lib/troupe/protocol/organisation.ex
  - apps/troupe_core/test/troupe/llm/provider_types_test.exs
  - apps/troupe_core/test/support/fake_providers.exs
  - docs/user/configuration.md
symbols:
  - Troupe.LLM.ProviderType.all/0
  - Troupe.LLM.Providers.Compatible.url/1
gist: "Provider types live in ProviderType alone; the four new ones use the OpenAI adapter, differences in Compatible; Gemini via its OpenAI endpoint"
---

Issue #658, slice 1: what #122's proposal section 6 left of the providers. A documented
table of provider types, `ollama`, `openrouter`, `azure_openai` and `gemini` beside
`anthropic` and `openai`, and a `type:` that names none of them an error rather than a
silent `openai`.

**What the tip did.** A file naming `type: gemini` was already refused, by Decision 686's
strict reading: `providers.g.type must be one of openai, anthropic, not "gemini"`, with a
hint that called OpenRouter `openai`. So the reproduction the slot was handed ("`type:
gemini` loads silently as `openai`") did not hold for a file. The silent `openai` left was
the one-time copy of opencode's providers, which wrote every SDK package but Anthropic's
as `type: openai`: `@ai-sdk/google` became an OpenAI provider with no base URL. The tests
for this slice start from what the tip refused: a gemini provider that loads as one.

**One table.** The list of types was written out in seven places: the schema's two enums,
the organisation's enforceable `provider`, `Troupe.LLM.Provider.known/0` and `adapter/1`,
the model settings a screen saves through, the config's atoms, the catalogue's targets and
the endpoint module's vendor keys. `Troupe.LLM.ProviderType` is now the only one in the
core: each type's adapter, its default URL (none for `azure_openai`), the variable that
stands in for a key and the one host it may go to, where its model list comes from, what a
call says about Troupe there, whether it needs a key or a URL, and the six columns a
person reads. Everything else asks it, and `mix troupe.config.schema` writes the table
into `docs/user/configuration.md` between generated markers, which `--check` keeps
current, as it keeps the key reference. `Troupe.Protocol.Organisation` keeps its own copy
of the names, since the protocol app does not depend on the core; the test that holds its
keys to the schema's holds the two lists equal.

**Four types through the OpenAI adapter.** Each of the four speaks OpenAI's Chat
Completions shape, so streaming, tool calls, usage, error bodies and retries are the
adapter's for all of them; a request carries its `type`, set where the agent aims it,
and `Troupe.LLM.Providers.Compatible` is where every difference is, one function each:

- the URL: `Troupe.LLM.Endpoint.url/3` joins the type's root (Gemini's
  `.../v1beta/openai` has no `/v1` to join), and Azure's carries the deployment, which is
  the model, and `api-version`;
- the key's header: `api-key` for Azure, or a bearer token for Microsoft Entra with
  `auth: bearer`; `Authorization: Bearer` for the rest, and none for Ollama without one;
- the output cap and the effort: `max_completion_tokens` with `reasoning_effort` stays
  OpenAI's and Azure's; Ollama, Gemini and OpenRouter take `max_tokens`, and OpenRouter
  takes the effort as its own `reasoning` object (`effort`, or `max_tokens` for a number).
  Nothing is raised to hold the reasoning on any of them, so an enforced `max_tokens`
  holds it as Decision 880 holds Anthropic's thinking;
- who the call is for: `metadata`, which is LiteLLM's, only to `openai`; `user` to
  OpenAI, OpenRouter and Azure, which document it; neither to Gemini or Ollama, since a
  vendor API that refuses a field it does not know would refuse the call.

What a call says about Troupe (Decision 787) is the type's row: LiteLLM's headers to a
gateway in front of `anthropic`, `openai` or `gemini`, OpenRouter's app headers to
`openrouter` wherever it is reached, and the User-Agent alone to an Ollama server or an
Azure resource, which are nobody's gateway. The vendor variables extend as they were:
`OPENROUTER_API_KEY` to openrouter.ai and `GEMINI_API_KEY` to Google's endpoint, each over
HTTPS on the vendor's own host. Ollama has none, and Azure has none: its endpoint is each
person's own resource, and a host-suffix rule for who may be sent `AZURE_OPENAI_API_KEY`
would be a guess about Microsoft's domains.

**Gemini: the OpenAI-compatible endpoint, not the native API.** The agent loop needs a
stream, tool calls with arguments, usage and an effort. Google's OpenAI-compatible endpoint
gives all four, and the adapter already reads them; the native `streamGenerateContent`
would be a third adapter the size of Anthropic's, for what this slice does not need:
explicit context caching, thought summaries, and windows in the model list (the
compatible `/models` gives ids only, so a Gemini model is planned against
`context_window` unless its `models:` entry says). The one thing the compatible endpoint
asks that no other type did is the thought signature Gemini puts on a tool call in
`extra_content`, which a later turn must hand back on that call or be refused. So a
`ToolUse` keeps what a provider attached, keyed by the type that attached it, and sends it
back to that type alone, as Decision 658 keeps reasoning with the provider that made it;
the session's log carries it, so a restart keeps it. A native adapter can come in a later
slice if caching or thinking text is wanted.

**Reasoning is bound to the type.** The OpenAI adapter tagged every reasoning block
`:openai`, which would hand a Gemini or OpenRouter turn's reasoning to whatever other
OpenAI-shaped provider the session asked next. It now tags it with the request's type;
`openai`'s stays `:openai`, so a log written before reads the same.

**Azure.** The deployment-based URL with an `api-version` (`2024-10-21`, the newest
generally available one, unless a named provider's `api_version` says; a preview version
is retired on a schedule, a GA one is not). A session-wide `provider: azure_openai` takes
the default: `api_version` is a key of a named provider only, so the flat key list does
not grow for one type. Azure lists deployments only through its management API, which a
key cannot reach, so it lists nothing and its deployments are the ones under `models:`. A
provider of the type without a `base_url` is refused, as an unset `{env:VAR}` refuses one,
rather than sent to no host. Azure's newer `/openai/v1/` path, which needs no
`api-version`, is not used: the slice asked for the deployment form, and the GA version
works with every deployment.

**Ollama and OpenRouter.** Ollama is local: no key, `http://localhost:11434` by default,
its model list from the server's `/v1/models` asked without one, and nothing priced.
OpenRouter is a type of its own rather than `openai` with a base URL, because four things
differ: the `reasoning` field, its app headers, its key variable, and a model list with
windows, output caps and prices (strings of dollars per token, cache rates included),
which the catalogue now reads, so `troupe models` prices its models.

**The catalogue.** A provider is asked for its list when its type has one and it has a
key, or takes none. A refused provider is asked nothing: before, one refused because the
variable its `base_url` reads was unset was asked at its vendor's default URL with its
key.

**A name that is no type.** The loader's refusal names the file, the line, the key and
every type. For a name people mean another type by (`litellm`, `vllm`, `lmstudio` and
`openai-compatible` are `openai`, `google` is `gemini`, `azure` is `azure_openai`) it says
so and that `troupe config migrate` rewrites it, and migrate does; for any other it says
what to write and rewrites nothing. Only migrate rewrites a type: a writer that sets
another key leaves the file's type as it is. The opencode copy maps the SDK packages that
are a type's (`@ai-sdk/google`, `@ai-sdk/azure`, `@openrouter/ai-sdk-provider`,
`ollama-ai-provider`) to it, and the rest to `openai` as before.

**Out of scope.** Bedrock and Vertex: each signs its requests with its cloud's own
credentials (SigV4, a Google service account) rather than taking a key, which is an auth
subsystem rather than a row; a gateway in front of either is the type of the API the
gateway speaks. The onboarding flows in both clients, which offer `anthropic`, `openai`
and a gateway, and the desktop app's Models panel, which shows a type it has no name for
as it is, are not changed.

**Proof:** `Troupe.LLM.ProviderTypesTest`: the table against the schema's enums, the
organisation's list, the adapters and the documentation; each new type loading, the
session-wide provider and the environment included; a name that is no type refused with
the file, line, key and types; an Azure provider without a URL refused and asked nothing;
migrate's rewrites, and its refusal for a name it cannot rewrite; each type's URL, key
header, cap, effort and identity headers against `Troupe.Test.FakeTransport`; a vendor
variable going only to its own endpoint; what a provider attached to a call going back to
its type alone, and through the log; and, end to end against each type's stand-in
(`fake_providers.exs`), Ollama with no key, OpenRouter's headers, Azure's deployment and
`api-version`, Gemini's signature handed back and the turn refused without it in Gemini's
own words, and the catalogue listing Ollama keyless, pricing OpenRouter, naming Gemini's
models as a request does and asking Azure nothing. `Troupe.Config.OrgTest`: an enforced
`ollama` and its URL held as `openai`'s are, a named provider of another type or URL
refused, and an organisation's default `openrouter` provider. `Troupe.ConfigProvidersTest`:
the opencode copy's types.

**Not tested:** any real provider. The stand-ins are written from each provider's
documentation; whether Azure's `2024-10-21` takes `stream_options`, and whether Gemini's
compatible endpoint reports cached tokens, is said by the documentation and not measured.
