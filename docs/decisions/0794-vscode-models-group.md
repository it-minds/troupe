---
number: 794
title: The VS Code extension's Settings view has a Models group, what `troupe models --json` lists for the folder, each model with its window, its price and where they came from, the three roles marked, and one its provider does not serve said so and given no window; `--refresh` only from the group's own button.
date: 2026-10-05
status: accepted
issue: 387
paths:
  - clients/vscode/src/models.ts
  - clients/vscode/src/settingsView.ts
symbols:
  - parseModels
  - modelsGroup
  - SettingsView.refreshModels
gist: Models rows are troupe models --json's; a served:false model's context is no window; --refresh only from the group's button; no key, even in errors.
---

Issue #387's last item: the first two (`troupe models --json`, its line in `troupe --help`)
shipped in Decision 783, and the Settings view (Decision 765) said the models to choose
from waited on it.

- **Troupe's answer, not the extension's reading.** The group is the rows `models.ts` makes
  of what `troupe models --json --workspace <folder>` prints, run where the terminal runs
  as `config --explain --json` is (765). The extension reads neither the config nor the
  catalog's cache and asks no provider, so the group cannot disagree with `troupe models`
  or a session. The words follow the text report's: a window in whole thousands (`131k`),
  millions past a million, prices to the places `troupe models` prints them (`$0.10/$0.50`,
  dollars a million tokens in/out), `(models.prices)` after a price the config gives.
- **Where.** In the Settings view, under the Model group (the model in use, then the
  models to choose from), before what else is changed. More than 20 models start the group
  folded, so a gateway's list does not push the files and problems out of sight.
- **A row a model.** The id; then its roles, its window, its price and where they came
  from: `from <provider>'s list` (`source: catalog`), `from your config` (`config` or
  `yaml`) or `from opencode`; `no key` when `key` is false. The default, cheap and expensive
  models are starred and named. A role left unset resolves to the default's id (783), so the
  default model then says all three, which is what a session would use. Hover shows the
  whole of it: the window in tokens, the price in and out, who said so.
- **Not served is said, and has no window.** A model with `served: false` has a warning,
  `not served by <provider>`, and on hover what the provider does serve (`nearest`). Its
  `context` is `Config.models/1`'s fallback, not a window anyone said (defects D70), so it
  is not shown, rather than waiting on troupe_core to send `null`. A price the config gives
  it is still shown: someone wrote it down. `served: null` (the provider has not answered)
  shows the model as it is, with that said on hover.
- **The providers' lists.** One row each, before the models, as the text's `catalog:`
  lines come first: how many models and when, or that it did not answer, when and why, and
  how much of it the cache still has.
- **When it asks, and `--refresh`.** With the settings, on the same occasions (the view
  shown, the folder worked in changing, a file the answer named saved, Refresh), and
  without `--refresh`: `troupe models` asks the providers itself when its cache is stale
  (778). `--refresh` asks every provider now, with the person's keys, up to 30 seconds
  each, so only an explicit act passes it: the button on the group's own row,
  `troupe.refreshModels`, "Ask the Providers for Their Models", also in the palette. The
  settings are asked first and shown while the models are asked for, one `troupe` at a
  time; the models' call may take 120 seconds, the settings' 30.
- **When it cannot.** No `troupe`: the one sentence of 765 is the whole view. `troupe
  models` failing (a config that does not load, a `troupe` before 0.8.3, which has no
  `--json`, a timeout): the group is one line, the first line of its standard error, the
  rest and the version on hover, and the settings stay. When the settings could not be
  read either, the models are asked all the same, since `troupe models` says on its
  standard error why a config does not load.
- **No key, even in an error.** The JSON has none (783). A failure's text is shown only
  after anything a key could be is taken out (the value after `api_key`, `token`, `secret`
  or `password`, a bearer token, an `sk-…`); the settings' own failure line goes through
  the same, as one helper makes both.
- **Not in this:** choosing a model from the list, which writes the person's file (765
  left changing a setting from the view out); D70's change in troupe_core; cache prices
  and `max_output`, which the JSON does not carry; the `errors` that `config --explain
  --json` prints on standard output when a config does not load, which the settings'
  failure line does not read yet.
- **Proof:** the unit test of the view's groups (the Model group, then Models, then the
  rest) failed on the chunk's tip, where there was no Models group. `models.test.ts`: each
  model's window, price and where they came from; the roles; a model not served, priced and
  not, with no window and what is served; no key and no answer; each provider's list,
  fetched and failed; long lists folded; output that is not models; a failure as one line
  with no key though the reason quotes three. 47 unit tests (2 skipped: sh and fish on
  Windows), and on Linux in WSL 43 with 4 skipped. The suite inside VS Code 1.140 on
  Windows, 19 of 19, against the fake `troupe` now answering `models --json`: the group
  beside the model, its rows, no `--refresh` in any call from the view; the button's call
  with `--refresh`; a failing `troupe models` as one line with the settings still there; a
  config that does not load; a missing `troupe` as the sentence. The fake's POSIX script
  under sh, dash and bash in WSL. And the `.vsix` in a scratch VS Code profile, against the
  installed `troupe.exe` 0.8.3 with scratch homes and the core suite's stand-in gateway on
  a loopback port: six models, the default and cheap starred, the expensive one and a
  priced `house-model` not served, neither with the 200k `troupe models` prints for them;
  the button refreshed the cache (its `fetched_at` moved, the group said "listed just
  now"), the view's own asks had not; a project file of broken YAML gave the group the
  reason `troupe models` printed.
