---
number: 778
title: The model catalog refreshes itself in the background, says what it fetched from where and when, and a model the configured provider does not serve fails `doctor` and is marked in `troupe models`, with the ones it does serve
date: 2026-10-04
status: accepted
issue: 410
paths:
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/application.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/doctor.ex
  - apps/troupe_core/lib/troupe/llm/catalog/refresher.ex
  - apps/troupe_core/lib/troupe/llm/catalog/store.ex
  - apps/troupe_core/test/support/fake_gateway.exs
  - apps/troupe_core/test/troupe/config/prices_test.exs
  - apps/troupe_core/test/troupe/llm/catalog_store_test.exs
  - apps/troupe_daemon/README.md
  - apps/troupe_daemon/lib/troupe/daemon/cli.ex
  - clients/tui/README.md
  - clients/tui/config/test.exs
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/test/troupe/models_cli_test.exs
  - config/config.exs
  - scripts/verify-local.ps1
gist: The model catalog refreshes itself in the background, says what it fetched from where and when, and a model the configured provider does not serve…
---

Issue #410. A
setup whose `models.default` named a model the gateway did not serve passed
`doctor` with two green lines, `key` among them having fetched the gateway's four
models and never looked for the configured one; `troupe models` listed it with the
default window and `no price`, a served model the gateway prices read `no price`
too until someone ran `--refresh` (the cache on the machine was twelve days old),
`source` said which file named a model rather than where its facts came from, and
`named providers: (none ...)` two lines under a working provider read as no provider.
- **The record.** `models.json` keeps, beside the models, one record for each
  provider a refresh asked (`Store.sources/0`): who it is (`provider`, `nil` for the
  session-wide one), its `type` and `base_url`, the `url` of the listing that
  answered (LiteLLM's `/model_group/info`, else `/v1/models`), the `ids` it listed and
  `fetched_at`; or `error` and `failed_at` when it did not answer. A provider that
  does not answer keeps the models it listed before at the same URL, so a refresh
  offline forgets nothing, and one at another URL is not that provider's. The file
  is written beside and renamed over, since the daemon now writes it while a client
  may read it. A cache from before the record still loads.
- **When it is stale** (`Store.stale/2`): no cache (the first run); a provider worth
  asking, one with a key, with no record at its type and base URL (a changed
  provider or URL, or an old cache); a list a day old; a provider that did not
  answer, again after an hour; and a model `default`, `cheap` or `expensive` names
  that its provider's list lacks, after ten minutes, since it may be new. A day,
  not two: a gateway's list changes when its operator adds or retires a model, on
  the scale of days, and a day keeps a person who starts a session a day at most a
  working day behind for one request a day per provider. The hour keeps an offline
  laptop from asking at every session start, and the ten minutes keep a model nobody
  serves to six requests an hour. A key that changes is not noticed by itself; the
  next failure, miss or day is, and `--refresh` at once.
- **In the background.** A local session that starts hands its config to
  `Troupe.LLM.Catalog.Refresher`, which decides and asks in a process of its own, one
  refresh at a time, the last config that arrived meanwhile looked at after. The
  session started with the cache as it was and never waits; the next one reads what
  was written. A pod's session (`kind: :team`) does not: its model is its profile's
  business, as before. `config :troupe_core, catalog_refresh: false` turns it off,
  which both test suites set, since many of their sessions carry a key and no base
  URL, which is a real provider's own endpoint. This amends TUI Decision 60's
  "fetching is explicit": `Config.load/2` still only reads the cache.
- **`troupe models`** (and `troupe-daemon models`) asks first when the cache is
  stale, whenever a provider last failed, since the person is waiting for this answer
  and may just have fixed the key (`Store.ensure/2`), and always with `--refresh`.
  One `catalog:` line for each provider says what came of it: `4 models from openai
  at <url>, fetched just now`, `..., from the cache, fetched 12 days ago`, `openai at
  <base_url> did not answer: 401 unauthorized: the key was refused; 4 of its models
  from the cache, ...`, or `not asked yet`. A model's `source` is where its facts came
  from: `:catalog` when the provider's list has it, whoever else names it; the report
  words it `from the provider` (asked by this run), `from the cache`, `from your
  config` or `from opencode`, and a catalog price no longer carries `(catalog)`; a
  `models.prices` price still says `(models.prices)` (689). A model a role names that
  its provider has answered without is `NOT SERVED by openai; it serves qwen3.6-35b,
  qwen3-235b, ...`, the five nearest by name first (`Catalog.nearest/3`, Jaro), in
  place of a window and a price it does not have. The named providers are `other
  named providers`, and when there are none the section is left out unless the
  session-wide provider cannot be asked either (`other named providers: none
  configured (...)`). The cache's path is `catalog cache:` at the end.
- **`doctor`** adds `model default`, and `model cheap` and `model expensive` when they
  are set: each among what its provider listed (the `key` line's request, or one more
  for a role on another provider), failing with `qwen3.5 is not served by openai; it
  serves qwen3.6-35b, qwen3-235b, gpt-oss-120b, mistral-small-3.2; set models.default
  to one`. A provider that lists nothing or does not answer keeps the lines it had.
  An alias matches the dated snapshot Anthropic lists (`claude-haiku-4-5` and
  `claude-haiku-4-5-20251001`, `Catalog.serves?/2`). A check's name longer than its
  column (a plane's URL) now has a space before its detail.
- **Not in this:** `troupe models --set`, onboarding picking from the list (#76), the
  plane's profile picker (#56); a running session does not reload the catalog it
  started with; a lookup that misses in the middle of a session (a delegated model,
  a price at call time) does not start a refresh, only the next session's start does.
- **Proof:** a stand-in gateway (`test/support/fake_gateway.exs`: `/model_group/info`
  with four models, windows and prices, `/v1/models`, a 401 for a key it does not
  know). `Troupe.DoctorTest`: a model it does not serve fails with the four, a served
  one and a dated snapshot pass, a refused key and an empty list add no line, the
  plane's space. `Troupe.LLM.CatalogStoreTest`: the record, each reason to be stale
  and its interval, a provider that does not answer keeping its models and being
  asked again, a named provider, a vanilla `/v1/models`, the report's lines, and a
  local session's start refreshing a stale catalog in the background and leaving a
  fresh one alone. TUI `ModelsCLITest`: `troupe models` on its first run, from the
  cache, with `--refresh`, with a refused key, and with no provider to ask.
