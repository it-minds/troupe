---
number: 689
title: A model the catalog does not price is priced from `models.prices`, which a profile sets for its pods as `llm.prices`; the gateway's figure still wins, then the catalog's, and a model with no price anywhere is said once a session rather than counted as free in silence
date: 2026-09-25
status: accepted
issue: 160
paths:
  - apps/troupe_core/lib/troupe/bench/live.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - clients/gui/apps/console/src/views/Profiles.tsx
  - apps/troupe_protocol/lib/troupe/worker_profile.ex
  - scripts/live-check
gist: A model the catalog does not price is priced from `models.prices`, which a profile sets for its pods as `llm.prices`
---

A streamed response carries no cost header: LiteLLM sends its headers before the first
token, so `x-litellm-response-cost` is absent. The harness then prices the call from the
catalog (`priced_locally`), and a pod has no catalog, nor does the catalog list every
model a gateway serves (`qwen3-235b`). Such a call had no `cost_micros`, the plane's
ledger summed it as 0, and no team or person budget ever counted it.
- **The key.** `models.prices.<model>: {input, output, cache_read, cache_write}`,
  dollars per million tokens as a price list quotes them and opencode's `cost`
  writes them, by the name a model is addressed with: the bare id for the
  session-wide provider, `<provider>/<model>` for a named one, as `models.windows`
  and the catalog are keyed. The cache rates default to the input rate, as the
  catalog's do. A price missing either half prices nothing and warns; `0` is free,
  a price. `TROUPE_MODEL_PRICES` takes the same map as JSON, checked entry by entry
  as a file's value is. Scope `:any`: a price moves no request and runs nothing, and
  on a pod the environment, where the profile's prices arrive, outranks a project's
  file for every model it names.
- **Precedence.** The gateway's `cost_micros`, then the catalog's price, then the
  configured one. Unlike a window (clients/tui Decision 60), a configured price does
  not overrule the catalog: a window is a choice a person makes about a model, a
  price is a fact about the bill, and the provider's own list is nearer the bill
  than a copy of it in a file, which also goes stale without saying so.
- **Names.** A call is priced under the id the agent addressed, then the wire id,
  then the id the provider answered as. The lookup was by the last two alone, so a
  catalog keyed `portal/glm-5.2` never priced a call to `portal/glm-5.2`.
  Micros are rounded rather than truncated.
- **Said once.** A call nobody prices is logged as a warning, naming the model and the key
  that would price it, and emitted as `[:troupe, :llm, :unpriced]`, once a session: the
  first agent to call the model claims it in the session's registry, and the claim goes
  with that agent. Nothing new in the protocol: the call's `llm_response` already has no
  `cost_micros`, which a reader treats as not known.
- **The plane.** `WorkerProfile.spec.llm.prices`, in the resource's camelCase
  (`cacheRead`, `cacheWrite`), declared in the CRD and set through `admin.profile.put`;
  the operator hands it to the pods as `TROUPE_MODEL_PRICES`, sorted so a reconcile rolls
  nothing. A pod's usage batch carries the cost and not where it came from, and the plane
  charges it like any other.
- **The live check** takes the gateway's rates from `TROUPE_NIGHTLY_MODEL_PRICES` and
  marks a cost it worked out itself *priced here*; unset, the column still says
  *not reported*. A fake-provider script may say `"cost_micros": null`, a gateway
  that names no price, which is how both are tried offline.
