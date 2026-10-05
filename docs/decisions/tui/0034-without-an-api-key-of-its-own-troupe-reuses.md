---
number: 34
title: Without an API key of its own, Troupe reuses opencode's providers from `~/.config/opencode/opencode.jsonc` (keys also from its `auth.json`)
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: Without an API key of its own, Troupe reuses opencode's providers from `~/.config/opencode/opencode.jsonc` (keys also from its `auth.json`)
---

The user already maintains those endpoints; only `baseURL`, `apiKey`, `npm` and `models.*.limit.context` are read, at session start, and nothing is copied into Troupe's state. Providers become addressable as `<name>/<model>` so `default` and `cheap` can live on different gateways; `troupe config` prints the resolution with keys masked. A YAML `providers:` section gives the same shape natively.
