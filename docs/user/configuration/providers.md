# Recipes: providers

One complete `config.yaml` for each way to reach a model. Each goes in `<config>/config.yaml`
([where that is](files.md)), and each is loaded by a test, so what is here is what Troupe
reads. `troupe setup` writes the same file from its questions, and `troupe config` shows
what is in effect once it is there.

Every key is in [the key reference](../configuration.md#every-key), and what each provider
type does about keys, model lists, thinking and caching is in
[the provider-type table](../configuration.md#provider-types).

A key is best kept out of the file: `{env:VAR}` reads it from a variable, which must be
set where the daemon starts. For `anthropic`, `openai`, `openrouter` and `gemini` you may
leave `api_key` out altogether: the vendor's own variable (`ANTHROPIC_API_KEY` and so on)
is read, and sent only to that vendor.

## Anthropic

The smallest useful file.

<!-- recipe: anthropic -->
```yaml title="config.yaml"
version: 1
provider: anthropic
# The key, read from the environment; it never sits in this file.
api_key: "{env:ANTHROPIC_API_KEY}"
models:
  default: claude-sonnet-5     # does the editing
  cheap: claude-haiku-4-5      # explores, summarises, answers quick questions
```

## OpenAI

<!-- recipe: openai -->
```yaml title="config.yaml"
version: 1
provider: openai
api_key: "{env:OPENAI_API_KEY}"
models:
  default: gpt-5
  cheap: gpt-5-mini
```

## A gateway, such as LiteLLM

A gateway is the type of the API it speaks: a LiteLLM proxy, vLLM or a company gateway
that serves OpenAI's Chat Completions is `openai` at its `base_url`. LiteLLM is the one
that says what each model costs; for a gateway that does not, `models.prices` does.

<!-- recipe: gateway -->
```yaml title="config.yaml"
version: 1
provider: openai
# The gateway's address, ending in /v1 as its own documentation writes it.
base_url: https://llm-gw.example.com/v1
# The gateway's key, not a vendor's; one on your own network may want none.
api_key: "{env:LLM_GATEWAY_KEY}"
models:
  default: glm-5.2             # as the gateway names its models
  cheap: qwen3.6-35b
  windows:
    qwen3.6-35b: 32768         # a model the gateway does not say the window of
  prices:
    glm-5.2: {input: 0.6, output: 2.2}   # dollars per million tokens; an example
```

A gateway in front of Anthropic that speaks Anthropic's Messages API is `provider:
anthropic` with its `base_url`, and `auth: bearer` when it takes its key as a bearer
token.

## Ollama, on your own machine

No key, and nothing leaves the server. Pull a model there first (`ollama pull qwen3:8b`);
`troupe models` lists what it has.

<!-- recipe: ollama -->
```yaml title="config.yaml"
version: 1
provider: ollama
# Unset, the server on this computer: http://localhost:11434. A server elsewhere:
# base_url: http://gpu-box.example.test:11434
models:
  default: qwen3:8b
  windows:
    qwen3:8b: 40960            # Ollama's list says no window; this one is the model's
```

## Azure OpenAI

Your own Azure resource, which has no address Troupe could know: `base_url` is required.
A model's name is the deployment's, and Azure lists its deployments to no key, so they
are named under `models:`. No variable stands in for the key.

<!-- recipe: azure -->
```yaml title="config.yaml"
version: 1
providers:
  azure:
    type: azure_openai
    base_url: https://my-resource.openai.azure.com   # your resource
    api_key: "{env:AZURE_OPENAI_API_KEY}"
    # auth: bearer                 # a Microsoft Entra token rather than the resource's key
    api_version: "2024-10-21"      # the default; a reasoning model may want a later one
    models:
      gpt-5:                       # a deployment named gpt-5
        context: 400000
        max_output: 128000
      small:                       # a deployment named otherwise than Troupe calls it
        id: gpt-5-mini-eu
        context: 400000
models:
  default: azure/gpt-5
  cheap: azure/small
```

## OpenRouter

Many vendors' models behind one key. A model is OpenRouter's id after the provider's
name, and `troupe models` prices each as OpenRouter lists it.

<!-- recipe: openrouter -->
```yaml title="config.yaml"
version: 1
providers:
  openrouter:
    type: openrouter
    api_key: "{env:OPENROUTER_API_KEY}"
models:
  default: openrouter/anthropic/claude-sonnet-4.5
  cheap: openrouter/deepseek/deepseek-chat-v3.1
# OpenRouter is told the calls are Troupe's (HTTP-Referer, X-Title); this turns that off.
identify: false
```

## Gemini

Through the Gemini API's OpenAI-compatible endpoint, with a key from Google AI Studio. Its
model list gives ids without windows, so a window is worth naming.

<!-- recipe: gemini -->
```yaml title="config.yaml"
version: 1
provider: gemini
api_key: "{env:GEMINI_API_KEY}"
models:
  default: gemini-2.5-pro
  cheap: gemini-2.5-flash
  windows:
    gemini-2.5-pro: 1048576
    gemini-2.5-flash: 1048576
```

## More than one

Named providers sit side by side, and a model spelled `<provider>/<model>` goes to that
one: the gateway for the work and Ollama for the small jobs is the
[Azure](#azure-openai) shape twice, or the example under
[How the layers merge](../configuration.md#how-the-layers-merge).

## From opencode

Troupe does not read opencode's settings. `troupe-daemon config import-opencode` copies
its providers and default model into `config.yaml` once, and `troupe config` and `troupe
setup` offer the same on a machine with no settings yet. The copy reads
`~/.config/opencode/opencode.jsonc` (keys also from its `auth.json`) and takes
`options.baseURL`, `options.apiKey`, `options.authToken`, per model `id`,
`limit.context`, `limit.output` and `options.reasoningEffort`, and opencode's `model` as
the default when you have none; an `{env:VAR}` stays a reference. `variants`, `agent` and
`permission` are not copied: agents are files, and `troupe onboard` brings opencode's in.

A provider is copied only where its key would go to the host it was set up for: its SDK
package is one Troupe has a type for (`@ai-sdk/anthropic`, `@ai-sdk/openai`,
`@ai-sdk/google`, `@ai-sdk/azure`, OpenRouter's, Ollama's), or opencode's file names its
`baseURL`, which is then where it goes, as `openai`. Any other, `@ai-sdk/mistral` with no
`baseURL` for one, is left out, and the copy names it and says why; add it to
`providers:` yourself with its `type` and `base_url`. `troupe config` then prints what was
resolved, keys masked.
