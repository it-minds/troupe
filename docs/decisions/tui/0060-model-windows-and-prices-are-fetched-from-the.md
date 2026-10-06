---
number: 60
title: Model windows and prices are fetched from the providers themselves into a `models.json` cache, never from a maintained price table, and config still outranks what comes back
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/llm/catalog.ex
gist: Model windows and prices are fetched from the providers themselves into a `models.json` cache, never from a maintained price table, and config…
---

Every window was typed by hand into `config.yaml` and went stale silently — the portal's `glm-5.2` was declared at 100k while the gateway had been serving 256k, so compaction fired at 40% of the real window — and there was no price anywhere, which made "what did that branch cost" unanswerable. Each provider gives a different amount: Anthropic's `GET /v1/models` has windows and no prices (there is no pricing endpoint, and Troupe is not going to maintain a table that goes wrong quietly), a LiteLLM proxy's `GET /model_group/info` has both, and a plain OpenAI-compatible `GET /v1/models` has ids and little else — so the catalog is three parsers into one entry shape, and an unpriced model reads as unpriced rather than free. Fetching is explicit (`troupe models --refresh`) and `Config.load/2` only reads the cache file, because a session must start offline and must not wait on two round trips; a refresh that loses one gateway keeps the others. Config wins over the catalog rather than the other way round — a declared window is the user's statement about a model, and a proxy that misreports one should not silently move it — but `troupe models` prints what the provider says next to it, which is how the stale 100k surfaced. `Catalog.cost/2` prices the four token classes of Decision 59 separately, since pricing a long session off the input rate alone would be wrong by roughly the cache ratio.
