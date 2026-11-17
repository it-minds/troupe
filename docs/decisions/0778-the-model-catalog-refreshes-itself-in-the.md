---
number: 778
title: The model catalog refreshes itself in the background, says what it fetched from where and when, and a model the configured provider does not serve fails `doctor` and is marked in `troupe models`, with the ones it does serve
date: 2026-10-04
status: accepted
issue: 410
paths:
  - apps/troupe_core/lib/troupe/llm/catalog/refresher.ex
  - apps/troupe_core/lib/troupe/llm/catalog/store.ex
gist: The model catalog refreshes itself in the background, says what it fetched from where and when, and a model the configured provider does not serve…
---

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
- **`doctor`** adds `model default`, and `model cheap` and `model expensive` when they
  are set: each among what its provider listed (the `key` line's request, or one more
  for a role on another provider), failing with `qwen3.5 is not served by openai; it
  serves qwen3.6-35b, qwen3-235b, gpt-oss-120b, mistral-small-3.2; set models.default
  to one`. A provider that lists nothing or does not answer keeps the lines it had.
  An alias matches the dated snapshot Anthropic lists (`claude-haiku-4-5` and
  `claude-haiku-4-5-20251001`, `Catalog.serves?/2`). A check's name longer than its
  column (a plane's URL) now has a space before its detail.
