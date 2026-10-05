---
number: 783
title: "`troupe models --json` prints what `troupe models` says as one JSON object for a program: the models with their prices as numbers, the roles, what the catalog fetched from where and when, and the named providers; never a key"
date: 2026-10-05
status: accepted
issue: 387
paths:
  - apps/troupe_core/lib/troupe/config/models.ex
  - apps/troupe_core/test/troupe/config/models_test.exs
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/test/troupe/models_cli_test.exs
gist: "`troupe models --json` prints what `troupe models` says as one JSON object for a program: the models with their prices as numbers, the roles, what…"
---

Issue #387, in part: the
VS Code extension's Models group that reads it is a follow-up in `clients/vscode`.
The report was words only, so a program that wanted the models, their windows and
prices (the extension's Settings view first, Decision 765) had to scrape what was
written for a person.
- **Built beside the text.** `Troupe.Config.Models.json/2`, reached as
  `Config.models_json/2` beside `explain/3`, takes the config and `asked` as
  `describe/2` does and is built from the calls the text is: `Config.models/1`,
  `resolve_model/2`, `price/2`, and the catalog's record (`Store.sources/0`,
  `providers/1`, `source/2`, `served/3`). The wording stays `describe/2`'s; the JSON
  says the same facts as values. A test holds the two together: every model the JSON
  lists is a line of the text, each of its sources a `catalog:` line, and a role's
  model it says is not served is NOT SERVED there.
- **The shape.** `models`, one object for each of `Config.models/1`: `id`, `provider`
  (the named one, `null` for the session-wide), `model`, `context`, `input` and
  `output` in dollars per million tokens (to four places, as the desktop app's list)
  or `null`, `price_source` (`catalog`, `config` or `null`), `source` (where its
  facts came from, 778: `catalog`, `config`, `yaml` or `opencode`), `key`, and
  `served`: `true`, `false` with the five `nearest` ids the provider does list, or
  `null` when that provider never answered. `served` is said of every model, where
  the text marks only a role's: the text is loud about what would fail a turn, and a
  program decides for itself what to mark. `roles`: `default`, `cheap` and
  `expensive`, each the id `resolve_model/2` resolves it to, so an unset role is the
  default's. `catalog`: the cache's `path` and `fetched_at`, and `sources`, one for
  each provider a refresh asks, as the `catalog:` lines are: `provider`, `type`,
  `base_url`, the listing's `url`, how many `models` it listed, `fetched_at`, and
  `status`, `fetched` by this run, `cached`, `failed` (with `error` and `failed_at`)
  or `not_asked`; `null` when there is no cache. `providers`: the named ones as
  `troupe config` lists them, `name`, `type`, `base_url`, `auth`, `source`, `key`
  and the `models` each declares.
- **No key.** `key` is `true` or `false`, never the key, masked or not, as the
  extension's view shows it (765). It is what `Config.models/1` decided for each
  model; a named provider's is its models', so it is decided in one place.
- **The command.** `troupe models --json [--workspace DIR] [--refresh]` refreshes as
  `troupe models` does (778), prints the object and exits 0. A config that does not
  load exits 1 with the reason on standard error, as `troupe models` does, rather
  than as an `errors` object on standard output as `config --explain --json` does: a
  program that asks for the models has nothing to show of a config that does not
  load but the reason. It has its own line in `troupe --help` and the reference.
- **Not in this:** the extension's Models group; `troupe-daemon models --json`; cache
  prices and `max_output`, which `Config.models/1` does not carry.
- **Proof:** `Troupe.Config.ModelsTest`, against the stand-in gateway: the shape
  before anything was fetched (no catalog, `served` null, a `models.prices` price as
  the config's), after a refresh (each source's status, the prices, a role's model
  not served with what is nearest), a key the gateway refuses (`failed`, the error,
  the cached count), the JSON and the text agreeing, and neither key, raw or masked,
  anywhere in it. TUI `ModelsCLITest`: `troupe models --json` decoded, a second run
  from the cache, a refused key, and a config that does not load said on standard
  error with nothing on standard output.
