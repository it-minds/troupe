---
number: 51
title: "Models are detected rather than typed: `Config.models/1` enumerates every addressable model and `/models` picks one from that menu"
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
gist: "Models are detected rather than typed: `Config.models/1` enumerates every addressable model and `/models` picks one from that menu"
---

The models are already in the configuration — each named provider's `models` block in `config.yaml` and in opencode's config carries model ids and context windows — but the only way to select one was to type `<provider>/<model>` from memory into a free-text setting. Detection folds those sources together with whatever `models.default` and `models.cheap` currently name, so the value in use is always in the list, and a provider that declares no models is still offered by name (`portal/`) to be completed by hand. The menu is a setting type (`:model`) rather than a special page, so the settings page renders it where the help text goes and `troupe config` prints the same list with context windows, source and whether a key was found. A model no config mentions is still reachable: the entry past the last choice falls back to typing, and a typed value appears in the menu next time.
